# Tribunal Hooks

All hooks are registered with `on`, `before`, `after`, or `callback` at the class or instance level.

```ruby
class MyTribunal < ActiveHarness::Tribunal
  on :after_agent do |result|
    puts "#{result.model.name}: #{result.processed["result"]}"
  end
end
```

Instance-level registration overrides class-level:

```ruby
tribunal = MyTribunal.new(input: "...")
tribunal.on(:agent_error) { |name, err, index| puts "[#{index}] #{name}: #{err.message}" }
```

---

## Events

| Event             | Alias                   | Block arguments            | When it fires                                                                                                                                                        |
| ----------------- | ----------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:before_call`    | `before :call`          | —                          | Before any agents are dispatched.                                                                                                                                    |
| `:before_agent`   | `before :agent`         | `agent, index`             | Just before each agent's `Concurrent::Future` is launched. `agent` is the agent instance, `index` is its 0-based position in the array.                              |
| `:after_agent`    | `after :agent`          | `result, index`            | After each agent completes successfully. `result` is a `Result` object, `index` is the agent's 0-based position.                                                     |
| `:agent_error`    | `callback :agent_error` | `agent_name, error, index` | When an agent fails or times out. `agent_name` is a String, `error` is the exception, `index` is the 0-based position.                                               |
| `:after_call`     | `after :call`           | `results, errors`          | After all agents finish (success or failure). `results` is an array of `Result`, `errors` is an array of `{agent:, error:}` hashes.                                  |
| `:before_verdict` | `before :verdict`       | `results`                  | Before the `process` block is called. **Transform hook** — the block's return value replaces the `results` array passed to `process`. Use to filter or sort results. |
| `:after_verdict`  | `after :verdict`        | `verdict`                  | After the `process` block returns. `verdict` is whatever `process` returned.                                                                                         |

---

## Transform hook

`:before_verdict` is a **transform hook**: the block's return value replaces the results array passed to `process`.

```ruby
# Only pass results from agents that responded within 2 seconds:
before :verdict do |results|
  results.select { |r| r.execution_time < 2.0 }
end
```

---

## Execution order

```
:before_call
  → agents dispatched in parallel
    → :before_agent              [once per agent, before launch]
    → (on success) :after_agent  [once per agent, with index]
    → (on failure) :agent_error  [once per failed agent, with index]
  → :after_call
  → :before_verdict  (transform)
  → process { |results| ... }
  → :after_verdict
```

---

## Notes

- If **all** agents fail, `Errors::AllAgentsFailed` is raised before `:before_verdict` fires.
- `:before_verdict` receives only **successful** results — failed agents are already in `#errors`.
- `timeout:` defaults to `7` seconds per agent. Override in the constructor: `new(input: ..., timeout: 15)`.
