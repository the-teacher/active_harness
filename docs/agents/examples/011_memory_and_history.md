# 011 — Memory and Conversation History

## Topic

How to persist conversation history across requests using `ActiveHarness::Memory` and a reusable concern.

## Why This Is Needed

Without memory each agent call is stateless. Storing turns lets an agent answer contextually — critical for chat and dialogue flows.

## How Memory Works

`ActiveHarness::Memory` is a standalone object. The agent **does not** load or save memory automatically — that is always the caller's responsibility:

1. Define a project-level memory class with your defaults.
2. Write a concern that wires load/record into agent hooks.
3. Include the concern in any agent that needs memory.
4. Pass a memory object when calling the agent.

---

## Step 1 — Define the memory class

`app/ai/memory/app_memory.rb`

```ruby
class AppMemory < ActiveHarness::Memory::JsonFile
  def initialize(file_name:, **opts)
    super(
      file_name:    file_name,
      storage_path: Rails.root.join("storage", "ai", "memory").to_s,
      depth:        10,
      storage_size: 200,
      pretty:       Rails.env.development?,
      **opts
    )
  end
end
```

One place for all project defaults — callers only pass a `file_name`.

`file_name` may contain slashes to create subdirectories: `"users/42"`, `"sessions/abc123/support"`. The final file is always `<storage_path>/<file_name>.json`. Segments `..` and `.` are rejected to prevent path traversal. Missing directories are created automatically on the first write.

---

## Step 2 — Define the concern

`app/ai/concerns/agent_memory.rb`

```ruby
module AgentMemory
  def self.included(base)
    base.callback(:setup) do
      @memory = @context.delete(:memory)
    end

    base.before(:call) do
      @memory&.load
    end

    base.after(:call) do |result|
      next unless @memory
      @memory.record(
        request:  @input,
        response: result.output,
        agent:    self.class.name,
        model:    result.model
      )
    end
  end
end
```

What this concern does:

| Hook           | Action                                                             |
| -------------- | ------------------------------------------------------------------ |
| `:setup`       | Extracts `memory` from `@context` into `@memory` instance variable |
| `:before_call` | Calls `@memory.load` — reads history from storage into RAM         |
| `:after_call`  | Calls `@memory.record` — persists the turn to storage              |

---

## Step 3 — Include in an agent

`app/ai/agents/chat_agent.rb`

```ruby
class ChatAgent < ActiveHarness::Agent
  include AgentMemory

  system_prompt ChatPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

---

## Step 4 — Use the agent

```ruby
memory = AppMemory.new(file_name: "users/#{user.id}")

ChatAgent.call(input: "Hello! My name is Alice.", context: { memory: memory })
ChatAgent.call(input: "What is my name?",         context: { memory: memory })
# => "Your name is Alice."
```

The same `memory` object is reused across calls. History accumulates in `storage/ai/memory/users/<user.id>.json`.

---

## Injecting history into the prompt

`@memory` is available in hook blocks and in prompt classes after `:setup` runs.

### Option A — inject into `@input` in a `before_call` hook

```ruby
class ChatAgent < ActiveHarness::Agent
  include AgentMemory

  on :before_call do
    history_messages = @memory&.to_messages || []
    next if history_messages.empty?

    history_text = history_messages.map do |message|
      "#{message[:role].upcase}: #{message[:content]}"
    end.join("\n")

    @input = <<~INPUT.strip
      CONVERSATION HISTORY:
      #{history_text}

      USER INPUT:
      #{@input}
    INPUT
  end
end
```

### Option B — read `@memory` directly in the prompt class

```ruby
class ChatPrompt
  def call
    history_messages = @memory&.to_messages || []
    history_text     = history_messages.map do |message|
      "#{message[:role].upcase}: #{message[:content]}"
    end.join("\n")

    <<~PROMPT
      You are a helpful chat assistant.

      #{history_text.present? ? "Conversation so far:\n#{history_text}\n\n" : ""}Current message: #{@input}
    PROMPT
  end
end
```

Prompt classes receive the same instance context as hooks, so `@memory` is accessible.

---

## Pattern — In-memory history without persistence

When history lives in a session or database and you manage it yourself, skip `ActiveHarness::Memory` entirely and pass history through `context:`.

```ruby
class ChatAgent < ActiveHarness::Agent
  system_prompt ChatPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :setup do
    @context[:history] ||= []
  end

  on :after_call do |result|
    @context[:history] << { role: "user",      content: @input        }
    @context[:history] << { role: "assistant", content: result.output }
    @context[:history] = @context[:history].last(20)
  end
end
```

```ruby
history = session[:chat_history] || []

agent = ChatAgent.new(input: params[:message], context: { history: history })
agent.call

session[:chat_history] = agent.context[:history]
```

---

## `ActiveHarness::Memory::JsonFile` API

```ruby
memory = AppMemory.new(file_name: "users/42")

memory.load                      # load turns from storage into RAM (idempotent)
memory.size                      # number of turns currently in RAM
memory.turns                     # raw turns: [{ request:, response:, agent:, model:, at: }]
memory.to_messages               # LLM-ready: [{ role: "user", content: … }, …]
memory.to_messages(filter: ->(turn) { turn[:agent] == "ChatAgent" })
memory.to_messages(since: 1.hour.ago)
memory.record(request:, response:)  # append turn and flush to disk
memory.delete                    # remove session file and clear RAM
memory.close                     # flush and close adapter
```

`depth:` on the constructor limits how many past turns `to_messages` returns.

---

## File storage layout

`file_name` maps directly to the path under `storage_path`. Slashes become subdirectories; `.json` is always appended automatically.

```
storage/ai/memory/
├── users/
│   ├── 42.json              # file_name: "users/42"
│   └── 99.json              # file_name: "users/99"
└── sessions/
    └── abc123/
        └── support.json     # file_name: "sessions/abc123/support"
```

Segments `..` and `.` are rejected — e.g. `file_name: "../etc/passwd"` raises `ArgumentError`.

JSON file format:

```json
{
  "session_id": "users/42",
  "turns": [
    {
      "request":  "Hello! My name is Alice.",
      "response": "Hi Alice! How can I help you?",
      "agent":    "ChatAgent",
      "model":    "mistralai/mistral-nemo",
      "at":       "2026-06-09T12:00:00Z"
    }
  ]
}
```

---

## Limiting history size

```ruby
class ChatAgent < ActiveHarness::Agent
  include AgentMemory

  MAX_TOKENS = 2000

  on :before_call do
    history = @memory&.to_messages || []
    @context[:history_text] = trim_to_token_budget(history, MAX_TOKENS)
                                .map do |message|
                                  "#{message[:role].upcase}: #{message[:content]}"
                                end
                                .join("\n")
  end

  private

  def trim_to_token_budget(messages, budget)
    total = 0
    messages.reverse.take_while do |message|
      total += (message[:content].length / 4).ceil
      total <= budget
    end.reverse
  end
end
```
