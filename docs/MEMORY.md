# Memory

## How Memory Works

**Memory management is entirely your responsibility.** ActiveHarness provides the storage primitives — it does not load history, inject it into prompts, or record turns on its own. This is intentional: automatic memory would hide what goes into the model and make agents harder to reason about.

You decide:

- **when** to load history from storage
- **what** to inject into the prompt and how
- **when** to record a new turn
- **when** to clear or delete a session

The recommended place for all of this is in **agent lifecycle hooks** (`before_call`, `after_system_prompt`, `after_call`) or in the prompt class itself. The sections below show each pattern in detail.

There are three adapter-backed classes to choose from:

| Class                             | Storage         |
| --------------------------------- | --------------- |
| `ActiveHarness::Memory::JsonFile` | JSON file       |
| `ActiveHarness::Memory::Sqlite`   | SQLite database |
| `ActiveHarness::Memory::Postgresql` | PostgreSQL    |

Pick the one that fits your setup and instantiate it directly — there is no generic `Memory.new` with an adapter selector.

---

## JsonFile Memory

`Memory::JsonFile` stores each session as a JSON file on disk. It is the default choice for development and single-process deployments.

```ruby
memory = ActiveHarness::Memory::JsonFile.new(
  file_name:    "user_42",              # required — becomes the filename
  storage_path: "storage/ai/memory",    # base directory (default)
  depth:        10,                     # max turns passed to to_messages; nil = all
  pretty:       true,                   # human-readable JSON formatting
  compact:      false,                  # when true — stores only q/a keys, no metadata
  storage_size: 200,                    # max turns kept in the file
  encoding:     "UTF-8"
)
```

`file_name:` may contain slashes to create subdirectories:

```ruby
memory = ActiveHarness::Memory::JsonFile.new(
  file_name: "users/42/chat"
  # stored as: storage/ai/memory/users/42/chat.json
)
```

File layout without and with `namespace:`:

```
storage/ai/memory/
├── user_42.json                      # no namespace
└── user_42/
    ├── SupportAgent.json             # namespace: "SupportAgent"
    └── TranslationAgent.json         # namespace: "TranslationAgent"
```

Pass the memory object to an agent:

```ruby
agent = SupportAgent.new(input: "Hello!", memory: memory)
agent.call
```

`@memory` is then available inside all agent hooks and the prompt class.

---

## Custom Memory Class

Extract configuration into a subclass so every call site only needs a session identifier:

```ruby
class AppMemory < ActiveHarness::Memory::JsonFile
  def initialize(user_id:)
    super(
      file_name:    "users/#{user_id}/chat",
      storage_path: Rails.root.join("storage", "ai", "memory").to_s,
      depth:        10,
      pretty:       true,
      storage_size: 200
    )
  end
end
```

```ruby
memory = AppMemory.new(user_id: current_user.id)
agent  = SupportAgent.call(input: params[:input], memory: memory)
```

---

## Managing Memory via Agent Callbacks

All memory management happens in lifecycle hooks. The standard practice is to extract those hooks into a **concern** and include it in any agent that needs memory. This keeps agent classes clean and makes the memory behaviour reusable.

### 1. Define a concern

```ruby
# app/ai/concerns/agent_memory.rb
module AgentMemory
  def self.included(base)
    # 1. Load history before the call
    base.on :before_call do
      @memory&.load
    end

    # 2. Inject history into the system prompt
    base.on :after_system_prompt do |prompt|
      next prompt unless @memory&.size&.positive?

      "#{prompt}\n\n" \
      "Conversation so far:\n" \
      "#{history}"
    end

    # 3. Record the turn after a successful call
    base.on :after_call do |result|
      @memory&.record(request: @input, response: result.output)
    end
  end

  private

  def history
    @memory
      .to_messages
      .map { |message| message[:content] }
      .join("\n")
  end
end
```

### 2. Include in any agent

```ruby
class SupportAgent < ActiveHarness::Agent
  include AgentMemory

  system_prompt SupportPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

Nothing fires unless `memory:` is passed when creating the agent. The `@memory&.` guards make the agent safe to call without memory too.

---

## Injection Patterns

### Option A — prepend history to input

Use when history should appear in the user message rather than the system context:

```ruby
on :before_call do
  @memory&.load
  next unless @memory&.size&.positive?

  @input =
    "Previous conversation:\n" \
    "#{history}\n\n" \
    "User: #{@input}"
end

on :after_call do |result|
  @memory&.record(request: @input, response: result.output)
end

private

def history
  @memory
    .to_messages
    .map { |message| message[:content] }
    .join("\n")
end
```

### Option B — inject via system prompt hook

History becomes part of the agent instructions:

```ruby
on :before_call { @memory&.load }

on :after_system_prompt do |prompt|
  next prompt unless @memory&.size&.positive?

  "#{prompt}\n\n" \
  "Conversation so far:\n" \
  "#{history}"
end

on :after_call do |result|
  @memory&.record(request: @input, response: result.output)
end

private

def history
  @memory
    .to_messages
    .map { |message| message[:content] }
    .join("\n")
end
```

### Option C — read `@memory` in the prompt class

The prompt class has access to `@memory` when the agent is configured with one:

```ruby
class SupportPrompt
  def call
    base = "You are a concise and helpful assistant. Answer in 1-2 sentences."
    return base unless @memory&.size&.positive?

    "#{base}\n\n" \
    "Conversation so far:\n" \
    "#{history}"
  end

  private

  def history
    @memory
      .to_messages
      .map { |message| message[:content] }
      .join("\n")
  end
end
```

Load and record still happen in agent hooks — the prompt class only reads.

---

## Filtering History with `to_messages`

```ruby
# Apply depth set in the constructor (last N turns)
memory.to_messages

# Only turns from the last hour
memory.to_messages(since: Time.now - 3600)

# Only turns from a specific agent
memory.to_messages(filter: ->(turn) { turn[:agent] == "SupportAgent" })

# Trim to a rough token budget (oldest turns dropped first)
memory.to_messages(token_budget: 4000)
```

---

## Memory API Reference

| Method                              | Description                                          |
| ----------------------------------- | ---------------------------------------------------- |
| `load`                              | Load history from storage into RAM                   |
| `record(request:, response:, **meta)` | Save a turn manually                               |
| `to_messages(**filters)`            | Return `[{role:, content:}, ...]` for LLM injection  |
| `turns`                             | All stored turns as an array of hashes               |
| `size`                              | Number of turns currently in memory                  |
| `clear`                             | Clear in-RAM turns (does not touch storage)          |
| `delete`                            | Delete the session from storage entirely             |
| `close`                             | Flush and close the adapter                          |

---

## Memory with `namespace:`

Isolate history per-agent within a shared session:

```ruby
support_memory     = AppMemory.new(user_id: 42, namespace: "support")
translation_memory = AppMemory.new(user_id: 42, namespace: "translation")
```

```
storage/ai/memory/users/42/
├── support.json
└── translation.json
```

---

## Sharing Memory Across Pipeline Steps

Pass the same memory object to a pipeline — it is available to every agent in the pipeline via `@memory`:

```ruby
memory   = AppMemory.new(user_id: current_user.id)
pipeline = SupportPipeline.new(input: params[:input], memory: memory)
pipeline.call
```

Load and record logic still lives in each agent's hooks.

---

## PostgreSQL Backend

Add the gem:

```ruby
# Gemfile
gem "pg"
```

Create the table (run once):

```
rails generate active_harness:memory_postgresql
rails db:migrate
```

```ruby
# Rails — borrow the ActiveRecord raw connection
memory = ActiveHarness::Memory::Postgresql.new(
  session_id: "user_42",
  connection: ActiveRecord::Base.connection.raw_connection,
  depth:      10
)
```

```ruby
# Plain Ruby — adapter opens and closes the connection itself
memory = ActiveHarness::Memory::Postgresql.new(
  session_id: "user_42",
  url:        ENV["DATABASE_URL"],
  depth:      10
)
memory.load
# ... agent calls ...
memory.close
```

Custom class pattern:

```ruby
class AppMemory < ActiveHarness::Memory::Postgresql
  def initialize(session_id:)
    super(
      session_id: session_id,
      connection: ActiveRecord::Base.connection.raw_connection,
      depth:      10
    )
  end
end
```

---

## SQLite Backend

Add the gem:

```ruby
# Gemfile
gem "sqlite3"
```

Create the table (run once in Rails):

```
rails generate active_harness:memory_sqlite
rails db:migrate
```

Or in plain Ruby:

```ruby
ActiveHarness::Memory::Sqlite.create_schema!("storage/ai/memory.sqlite3")
```

```ruby
# Rails — borrow the ActiveRecord raw connection
memory = ActiveHarness::Memory::Sqlite.new(
  session_id: "user_42",
  connection: ActiveRecord::Base.connection.raw_connection,
  depth:      10
)
```

```ruby
# Plain Ruby — adapter opens and closes the file itself
memory = ActiveHarness::Memory::Sqlite.new(
  session_id: "user_42",
  database:   "storage/ai/memory.sqlite3",
  depth:      10
)
memory.load
# ... agent calls ...
memory.close
```

Custom class pattern:

```ruby
class AppMemory < ActiveHarness::Memory::Sqlite
  def initialize(session_id:)
    super(
      session_id: session_id,
      database:   Rails.root.join("storage", "ai", "memory.sqlite3").to_s,
      depth:      10
    )
  end
end
```
