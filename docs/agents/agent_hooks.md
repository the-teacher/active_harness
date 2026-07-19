# Agent Hooks

All hooks are registered with `on`, `before`, `after`, or `callback` at the class or instance level.

```ruby
class MyAgent < ActiveHarness::Agent
  on       :setup          do ... end
  before   :call           do ... end
  after    :call           do |result| ... end
  callback :retry          do |entry, error| ... end
end
```

Hooks are only registered at the **class level**. There is no instance-level hook API — `agent.on(...)` does not exist on an `Agent` instance and raises `NoMethodError`. Multiple class-level registrations for the same event **accumulate** (they don't override each other); all fire in the order they were registered, including hooks contributed by included modules.

---

## Events

| Event                   | Alias                   | Block arguments | When it fires                                                                                                                                     |
| ----------------------- | ----------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:setup`                | `callback :setup`       | —               | Before anything else. Runs once per `call`. Use to normalize `@input`.                                                                            |
| `:before_call`          | `before :call`          | —               | After setup, before the first HTTP request is made. Use to modify `@input` or `@context`.                                                         |
| `:after_call`           | `after :call`           | `result`        | After a successful response. `result` is a `Result` object.                                                                                       |
| `:retry`                | `callback :retry`       | `entry, error`  | After each failed model attempt before trying the next fallback. `entry` is the model hash `{provider:, model:, ...}`, `error` is the exception.  |
| `:failure`              | `callback :failure`     | `attempts`      | After all models in the chain have failed. `attempts` is an array of flat hashes `{provider:, model:, error:, error_code:, execution_time:}` (one per attempt). |
| `:before_system_prompt` | `before :system_prompt` | —               | Before the prompt class `call` is invoked. Use to mutate `@context` before the prompt reads it.                                                   |
| `:after_system_prompt`  | `after :system_prompt`  | `prompt`        | After the prompt string is built. Return value is **ignored** — use `before_system_prompt` to mutate context, or a prompt class for full control. |
| `:before_parse`         | `before :parse`         | `raw`           | Before the raw LLM string is parsed (e.g. JSON). **Transform hook** — the block's return value replaces `raw`.                                    |
| `:after_parse`          | `after :parse`          | `parsed`        | After successful parsing. **Transform hook** — the block's return value replaces `parsed`.                                                        |
| `:parse_error`          | `callback :parse_error` | `raw, error`    | When parsing fails. The block's return value is used as the fallback parsed value.                                                                |

---

## Transform hooks

`:before_parse` and `:after_parse` are **transform hooks**: the block's return value replaces the current value.

````ruby
before :parse do |raw|
  raw.strip.sub(/^```json/, "").sub(/```$/, "").strip
end

after :parse do |parsed|
  parsed.merge("processed_at" => Time.now.iso8601)
end
````

---

## Execution order

```
:setup
  → :before_system_prompt
  → :after_system_prompt
  → :before_call
    → HTTP request
    → (on failure) :retry  [repeated for each fallback]
    → (all failed) :failure
  → :before_parse
  → :after_parse  (or :parse_error)
  → :after_call
```
