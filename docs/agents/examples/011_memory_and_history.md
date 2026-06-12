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
    base.before(:call) do
      @memory&.load
    end

    base.after(:call) do |result|
      next unless @memory
      @memory.record(
        request:  @input,
        response: result.output,
        agent:    self.class.name,
        model:    result.model.name
      )
    end
  end
end
```

What this concern does:

| Hook           | Action                                                     |
| -------------- | ---------------------------------------------------------- |
| `:before_call` | Calls `@memory.load` — reads history from storage into RAM |
| `:after_call`  | Calls `@memory.record` — persists the turn to storage      |

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

ChatAgent.call(input: "Hello! My name is Alice.", memory: memory)
ChatAgent.call(input: "What is my name?",         memory: memory)
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

## Context window and history budgeting

Every agent automatically looks up the context window size for its primary model from `ActiveHarness::Pricing` at initialization time. The value is stored as `@context_window` (an integer, or `nil` if the model is not in the registry) and is:

- available in all hook blocks (`on :before_call`, etc.)
- injected into prompt class instances alongside `@input`, `@memory`, etc.
- stored on `result.model.context_window` after a successful call (reflects the model that actually ran, including fallbacks)

### Trimming history to fit the context window

Pass `token_budget:` to `to_messages`. The budget is measured in *tokens* using a rough estimate of `characters / 4`. Turns are dropped oldest-first until the budget is satisfied.

```ruby
class ChatPrompt
  def call
    budget   = @context_window ? (@context_window * 0.25).to_i : nil
    messages = @memory&.to_messages(token_budget: budget) || []
    history  = messages.map { |m| m[:content] }.join("\n")

    return BASE_INSTRUCTION if history.empty?

    <<~PROMPT
      #{BASE_INSTRUCTION}

      Conversation so far:
      #{history}
    PROMPT
  end
end
```

`0.25` reserves 25% of the context window for conversation history. Adjust the fraction to leave headroom for the system prompt, current input, and the model's output.

The fraction can be overridden per-call via `params:` without changing the prompt class:

```ruby
# default — 25%
ChatAgent.call(input: "Hello", memory: mem)

# more history — 40%
ChatAgent.call(input: "Hello", memory: mem, params: { history_fraction: 0.4 })

# minimal — only the very last turn fits
ChatAgent.call(input: "Hello", memory: mem, params: { history_fraction: 0.05 })
```

See [006 — System Prompts](006_system_prompts.md) for the full list of variables available in prompt classes (`@input`, `@context`, `@params`, `@memory`, `@context_window`).

### Checking the context window in a hook

```ruby
class ChatAgent < ActiveHarness::Agent
  include AgentMemory

  on :before_call do
    Rails.logger.info "Context window: #{@context_window || 'unknown'}"
  end
end
```

### Checking after the call

```ruby
result = ChatAgent.call(input: "Hello", memory: mem)
puts result.model.context_window   # => 131072 (or nil)
puts result.model.name            # => "mistralai/mistral-nemo"
```

If the primary model failed and a fallback took over, `result.model.context_window` reflects the fallback model's window — not the primary one.

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
