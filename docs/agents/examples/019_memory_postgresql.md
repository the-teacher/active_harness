# 019 — Memory: PostgreSQL Adapter

## Topic

How to persist conversation history in PostgreSQL using `ActiveHarness::Memory::Postgresql`.

## Why This Is Needed

The default `JsonFile` adapter stores history in files on disk — fine for a single server but problematic when processes restart, multiple dynos run, or you need SQL queries over history. PostgreSQL solves all three.

## Dependency

`ActiveHarness` does **not** depend on `pg`. Install it yourself:

```ruby
# Gemfile
gem "pg"
```

The adapter raises a helpful `LoadError` with instructions if `pg` is missing at runtime.

---

## Database schema

### Rails — generator

```bash
rails generate active_harness:memory_postgresql
rails db:migrate
```

The generator creates a timestamped migration in `db/migrate/` and picks the current
`ActiveRecord::Migration` version automatically.

### Plain Ruby — run raw SQL

```sql
CREATE TABLE active_harness_memory_turns (
  id          BIGSERIAL    PRIMARY KEY,
  session_id  TEXT         NOT NULL,
  namespace   TEXT,
  request     TEXT         NOT NULL,
  response    TEXT         NOT NULL,
  meta        JSONB        NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ah_memory_turns_session
  ON active_harness_memory_turns (session_id, namespace, id);
```

Column overview:

| Column       | Purpose                                                       |
| ------------ | ------------------------------------------------------------- |
| `session_id` | Identifies the conversation; maps to `session_id:` in Ruby   |
| `namespace`  | Optional per-agent isolation within a session                 |
| `request`    | User input text                                               |
| `response`   | Agent output text                                             |
| `meta`       | Any extra fields recorded with the turn (agent name, model…)  |
| `created_at` | Insertion timestamp                                           |

---

## Step 1 — Define the memory class

### Rails

`app/ai/memory/app_memory.rb`

```ruby
class AppMemory < ActiveHarness::Memory::Postgresql
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

`ActiveRecord::Base.connection.raw_connection` returns the underlying `PG::Connection` from
the current AR connection. The adapter borrows it — it does not open or close the connection.

> **Thread safety**: each request thread has its own AR connection from the pool, so
> `raw_connection` is safe when called per-request. Do not store a single `AppMemory` instance
> across requests.

### Plain Ruby

```ruby
class AppMemory < ActiveHarness::Memory::Postgresql
  DB_URL = ENV.fetch("DATABASE_URL")

  def initialize(session_id:, **opts)
    super(
      session_id:   session_id,
      url:          DB_URL,
      depth:        10,
      storage_size: 500,
      **opts
    )
  end
end
```

When `url:` (or `host:`/`dbname:`/…) is used instead of `connection:`, the adapter
**opens a dedicated connection** and **owns it**. Call `memory.close` when done to release it.

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

The AR connection is returned to the pool automatically when the request finishes.

### Plain Ruby (long-lived connection)

```ruby
memory = AppMemory.new(session_id: "user_42")

ChatAgent.call(input: "Hello! I'm Alice.", memory: memory)
ChatAgent.call(input: "What's my name?",  memory: memory)
# => "Your name is Alice."

memory.close  # release the dedicated PG connection
```

---

## Constructor options

```ruby
ActiveHarness::Memory::Postgresql.new(
  session_id:       "user_42",    # required

  # Connection — choose one:
  connection:       pg_conn,      # borrow an existing PG::Connection
  url:              "postgres://…",  # adapter opens + owns the connection
  host:             "localhost",  # adapter opens + owns the connection
  port:             5432,
  dbname:           "myapp",
  user:             "myuser",
  password:         "secret",

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
  on_trim:          ->(turns) { Rails.logger.info("Trimmed #{turns.size} turns") }
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
```

---

## Inspecting history with SQL

Because turns are in a real table you can query them directly:

```sql
-- Last 10 turns for a session
SELECT request, response, meta->>'agent' AS agent, created_at
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
WHERE  meta->>'agent' = 'SupportAgent'
ORDER  BY id;
```

---

## Choosing between JsonFile and Postgresql

| Concern             | `JsonFile`                     | `Postgresql`                      |
| ------------------- | ------------------------------ | --------------------------------- |
| Dependencies        | none                           | `pg` gem                          |
| Setup               | zero config                    | table migration required          |
| Multiple processes  | race conditions on write       | safe (row-level inserts)          |
| Querying history    | parse JSON files manually      | full SQL                          |
| Horizontal scaling  | needs shared filesystem        | any process connecting to the DB  |
| Dev / CI speed      | fast, no DB needed             | requires running PostgreSQL       |
