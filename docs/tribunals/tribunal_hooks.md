# Tribunal Hooks

All hooks are registered with `on`, `before`, `after`, or `callback` at the class or instance level.

```ruby
class MyTribunal < ActiveHarness::Tribunal
  on :after_request do |result|
    puts "#{result.model.name}: #{result.processed["result"]}"
  end
end
```

Hooks accumulate — instance-level registration adds another handler alongside class-level ones (both fire, in registration order); it does not replace them:

```ruby
tribunal = MyTribunal.new(input: "...")
tribunal.on(:request_error) { |name, err, index| puts "[#{index}] #{name}: #{err.message}" }
```

---

## Events

| Event             | Alias                   | Block arguments            | When it fires                                                                                                                                                        |
| ----------------- | ----------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:before_call`    | `before :call`          | —                          | Before any requests are dispatched.                                                                                                                                    |
| `:before_request`   | `before :request`         | `request, index`             | Just before each request's `Concurrent::Future` is launched. `request` is the request instance, `index` is its 0-based position in the array.                              |
| `:after_request`    | `after :request`          | `result, index`            | After each request completes successfully. `result` is a `Result` object, `index` is the request's 0-based position.                                                     |
| `:request_error`    | `callback :request_error` | `request_name, error, index` | When a request fails or times out. `request_name` is a String, `error` is the exception, `index` is the 0-based position.                                               |
| `:after_call`     | `after :call`           | `results, errors`          | After all requests finish (success or failure). `results` is an array of `Result`, `errors` is an array of `{request:, error:}` hashes.                                  |
| `:before_verdict` | `before :verdict`       | `results`                  | Before the `process` block is called. **Transform hook** — the block's return value replaces the `results` array passed to `process`. Use to filter or sort results. |
| `:after_verdict`  | `after :verdict`        | `verdict`                  | After the `process` block returns. `verdict` is whatever `process` returned.                                                                                         |

---

## Transform hook

`:before_verdict` is a **transform hook**: the block's return value replaces the results array passed to `process`.

```ruby
# Only pass results from requests that responded within 2 seconds:
before :verdict do |results|
  results.select { |r| r.execution_time < 2.0 }
end
```

---

## Execution order

```
:before_call
  → requests dispatched in parallel
    → :before_request              [once per request, before launch]
    → (on success) :after_request  [once per request, with index]
    → (on failure) :request_error  [once per failed request, with index]
  → :after_call
  → :before_verdict  (transform)
  → process { |results| ... }
  → :after_verdict
```

---

## Notes

- If **all** requests fail, `Errors::AllRequestsFailed` is raised before `:before_verdict` fires.
- `:before_verdict` receives only **successful** results — failed requests are already in `#errors`.
- `timeout:` defaults to `7` seconds per request. Override in the constructor: `new(input: ..., timeout: 15)`.
