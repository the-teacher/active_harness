# 020 — Memory: SQLite Adapter

## Topic

How to persist conversation history in SQLite using `ActiveHarness::Memory::Sqlite`.

## Why This Is Needed

SQLite sits between `JsonFile` and `Postgresql`: it gives you a real SQL table and structured
queries without requiring a separate database server. Good fit for development, testing,
single-process production apps, and embedded use cases.

## Dependency

`ActiveHarness` does **not** depend on `sqlite3`. Install it yourself:

```ruby
# Gemfile
gem "sqlite3"
```

The adapter raises a helpful `LoadError` with instructions if `sqlite3` is missing at runtime.

---

## Database schema

### Rails — generator

```bash
rails generate active_harness:memory_sqlite
rails db:migrate
```

The generator creates a timestamped migration in `db/migrate/` and picks the current
`ActiveRecord::Migration` version automatically.

### Plain Ruby — `create_schema!`

No migration system needed. Call the class method once before first use:

```ruby
ActiveHarness::Memory::Sqlite.create_schema!("storage/ai/memory.sqlite3")
```

It uses `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` — safe to call
multiple times. You can pass a file path or an existing `SQLite3::Database` instance.

### Plain Ruby — raw SQL

If you manage schema yourself:

```sql
CREATE TABLE IF NOT EXISTS active_harness_memory_turns (
  id         INTEGER  PRIMARY KEY AUTOINCREMENT,
  session_id TEXT     NOT NULL,
  namespace  TEXT,
  request    TEXT     NOT NULL,
  response   TEXT     NOT NULL,
  meta       TEXT     NOT NULL DEFAULT '{}',
  created_at TEXT     NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ah_memory_turns_session
  ON active_harness_memory_turns (session_id, namespace, id);
```

Column overview:

| Column       | Purpose                                                      |
| ------------ | ------------------------------------------------------------ |
| `session_id` | Identifies the conversation; maps to `session_id:` in Ruby  |
| `namespace`  | Optional per-agent isolation within a session                |
| `request`    | User input text                                              |
| `response`   | Agent output text                                            |
| `meta`       | Extra fields recorded with the turn (agent name, model…) as JSON text |
| `created_at` | Insertion timestamp (UTC, stored as text)                    |

---

## Step 1 — Define the memory class

### Rails (borrowing the AR connection)

`app/ai/memory/app_memory.rb`

```ruby
class AppMemory < ActiveHarness::Memory::Sqlite
  def initialize(session_id:, **opts)
    super(
      session_id: session_id,
      connection: ActiveRecord::Base.connection.raw_connection,
      depth:      10,
      storage_size: 500,
      **opts
    )
  end
end
```

`raw_connection` returns the underlying `SQLite3::Database` from the current AR connection.
The adapter borrows it — it does not open or close it.

> **Thread safety**: each request thread has its own AR connection from the pool, so
> `raw_connection` is safe when called per-request. Do not store a single `AppMemory` instance
> across requests.

### Plain Ruby (dedicated file)

```ruby
class AppMemory < ActiveHarness::Memory::Sqlite
  DB_PATH = ENV.fetch("MEMORY_DB_PATH", "storage/ai/memory.sqlite3")

  def initialize(session_id:, **opts)
    super(
      session_id:   session_id,
      database:     DB_PATH,
      depth:        10,
      storage_size: 500,
      **opts
    )
  end
end

# Run once at app boot (idempotent):
ActiveHarness::Memory::Sqlite.create_schema!(AppMemory::DB_PATH)
```

When `database:` is used, the adapter **opens a dedicated connection** and **owns it**.
Call `memory.close` when done to release the file handle.

WAL journal mode is enabled automatically on owned connections for better concurrent reads.

---

## Step 2 — Define the concern

Same `AgentMemory` concern from example 011 works unchanged:

`app/ai/concerns/agent_memory.rb`

```ruby
module AgentMemory
  def self.included(base)
    base.before(:call) do
      @memory&.load
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

---

## Step 3 — Include in an agent

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

### Rails (per-request)

```ruby
# app/controllers/chat_controller.rb
def create
  memory = AppMemory.new(session_id: "users/#{current_user.id}")
  result = ChatAgent.call(input: params[:message], memory: memory)
  render json: { reply: result.output }
end
```

### Plain Ruby (long-lived connection)

```ruby
memory = AppMemory.new(session_id: "user_42")

ChatAgent.call(input: "Hello! I'm Alice.", memory: memory)
ChatAgent.call(input: "What's my name?",  memory: memory)
# => "Your name is Alice."

memory.close  # release the SQLite file handle
```

### In-memory database (tests / ephemeral)

```ruby
require "sqlite3"
conn = SQLite3::Database.new(":memory:")
ActiveHarness::Memory::Sqlite.create_schema!(conn)

memory = ActiveHarness::Memory::Sqlite.new(
  session_id: "test_session",
  connection: conn
)
```

Each `:memory:` connection is an independent empty database — no cleanup needed between tests.

---

## Constructor options

```ruby
ActiveHarness::Memory::Sqlite.new(
  session_id:       "user_42",              # required

  # Connection — choose one:
  database:         "storage/ai/mem.sqlite3",  # adapter opens + owns the connection
  connection:       sqlite3_db_instance,       # borrow an existing SQLite3::Database

  # Storage:
  table_name:       "active_harness_memory_turns",  # default
  storage_size:     1000,   # max turns kept per session (default 1000)
  eviction_percent: 10,     # % of oldest turns to drop on trim (default 10)

  # Memory base options:
  depth:            10,     # turns visible to to_messages (nil = all)
  namespace:        "chat", # per-agent isolation within a session
  read_only:        false,
  enabled:          true,
  async:            false,
  on_trim:          ->(turns) { puts "Trimmed #{turns.size} turns" }
)
```

---

## API reference

```ruby
memory = AppMemory.new(session_id: "user_42")

memory.load                       # load turns from DB into RAM (idempotent)
memory.size                       # number of turns in RAM
memory.turns                      # raw array: [{ request:, response:, agent:, model:, at: }]
memory.to_messages                # LLM-ready: [{ role: "user", … }, { role: "assistant", … }]
memory.to_messages(filter: ->(t) { t[:agent] == "ChatAgent" })
memory.to_messages(since: 1.hour.ago)
memory.record(request:, response:)  # insert turn + trim if needed
memory.delete                     # DELETE all rows for this session
memory.close                      # close connection (only if adapter opened it)

# Class method — schema setup for plain Ruby:
ActiveHarness::Memory::Sqlite.create_schema!("path/to/db.sqlite3")
ActiveHarness::Memory::Sqlite.create_schema!(existing_conn)
```

---

## Inspecting history with SQL

Meta is stored as JSON text — use SQLite's `json_extract` function:

```sql
-- Last 10 turns for a session
SELECT request, response,
       json_extract(meta, '$.agent') AS agent,
       created_at
FROM   active_harness_memory_turns
WHERE  session_id = 'user_42'
ORDER  BY id DESC
LIMIT  10;

-- Count turns per session
SELECT session_id, COUNT(*) AS turns
FROM   active_harness_memory_turns
GROUP  BY session_id
ORDER  BY turns DESC;

-- All turns from a specific agent
SELECT *
FROM   active_harness_memory_turns
WHERE  json_extract(meta, '$.agent') = 'SupportAgent'
ORDER  BY id;
```

---

## Choosing between JsonFile, SQLite, and PostgreSQL

| Concern              | `JsonFile`               | `Sqlite`                        | `Postgresql`                     |
| -------------------- | ------------------------ | ------------------------------- | -------------------------------- |
| Dependencies         | none                     | `sqlite3` gem                   | `pg` gem                         |
| Server required      | no                       | no (embedded)                   | yes                              |
| Setup                | zero config              | `create_schema!` or migration   | migration required               |
| Plain Ruby schema    | automatic                | `create_schema!(path)`          | manual SQL                       |
| Multiple processes   | race conditions on write | WAL mode, same-host only        | safe, any host                   |
| Querying history     | parse JSON files         | SQL + `json_extract`            | SQL + JSONB operators            |
| In-memory / tests    | tmp files                | `:memory:` connection           | not practical                    |
| Horizontal scaling   | shared filesystem needed | single host only                | any process, any host            |
| Best for             | dev, zero-config prod    | dev, test, single-process prod  | multi-process, distributed prod  |
