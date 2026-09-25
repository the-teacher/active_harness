# Tribunal Error Processing

A tribunal runs requests in parallel. Some requests may fail while others succeed.
ActiveHarness handles partial failures gracefully — the verdict is still computed
from the requests that succeeded.

---

## Partial Failures

When one or more requests fail (or time out), their errors are collected in `tribunal.errors`.
Successful results are still available in `tribunal.results` and the verdict is computed normally.

```ruby
tribunal = PolitenessTribunal.new(input: "Hello!")
tribunal.call

# Successful results only
tribunal.results.each do |result|
  puts "#{result.model.name}: #{result.processed["result"]}"
end

# Failed requests
tribunal.errors.each do |e|
  puts "#{e[:request]}: #{e[:error].message}"
end

puts tribunal.verdict  # computed from successful results only
```

---

## Error Hash Structure

Each entry in `tribunal.errors` is a plain hash:

```ruby
{
  request: "PolitenessRequest",         # class name of the request that failed
  error: #<ActiveHarness::Errors::ProviderError: "Provider returned error">
}
```

Access the exception directly:

```ruby
tribunal.errors.first[:error].class    # => ActiveHarness::Errors::ProviderError
tribunal.errors.first[:error].message  # => "Provider returned error"
tribunal.errors.first[:error].error_code  # => "model_error" or nil
```

---

## AllRequestsFailed

If **every** request fails or times out, `tribunal.call` raises `AllRequestsFailed`
(not `AllModelsFailed` — that's request-level):

```ruby
begin
  tribunal.call
rescue ActiveHarness::Errors::AllRequestsFailed => e
  puts "All requests failed: #{e.message}"
  # e.message contains a summary of every request's error
end
```

---

## Timeouts

Each request runs in a `Concurrent::Future` with a configurable timeout (default: 7 seconds).
If the future hasn't completed within the timeout window, it is treated as a `TimeoutError`:

```ruby
tribunal = MyTribunal.new(input: "...", timeout: 5)  # 5 seconds per request
```

Timed-out requests appear in `tribunal.errors` with a `TimeoutError`:

```ruby
{ request: "PolitenessRequest",
  error: #<ActiveHarness::Errors::TimeoutError: "Request PolitenessRequest timed out after 5s"> }
```

---

## Reacting to Errors with Hooks

Use the `:request_error` hook to react per-request, and `:after_call` to inspect the full picture:

```ruby
class MyTribunal < ActiveHarness::Tribunal
  on(:request_error) do |request_name, error, index|
    Rails.logger.warn "[Request #{index + 1}] #{request_name}: #{error.message}"
  end

  on(:after_call) do |results, errors|
    if errors.any?
      Rails.logger.warn "#{errors.size} request(s) failed, #{results.size} succeeded"
    end
  end
end
```

---

## Verdict with Partial Results

The `process` block receives only the **successful** results (after `:before_verdict`
transform, if any). Design your process block defensively:

```ruby
process do |results|
  # Require unanimous agreement — a missing request counts as "not polite"
  results.size == 3 && results.all? { |r| r.processed["result"] == true }
end

# Or: majority vote regardless of how many requests responded
process do |results|
  positive = results.count { |r| r.processed["result"] == true }
  positive > results.size / 2
end
```

---

## Inspecting Errors in Rails

In a controller, `tribunal.errors` is available after `tribunal.call`:

```ruby
tribunal = PolitenessTribunal.new(input: input)
tribunal.call

render json: {
  verdict: tribunal.verdict,
  time:    tribunal.execution_time,
  results: tribunal.results.map { |r| { model: r.model, result: r.processed } },
  errors:  tribunal.errors.map  { |e| { request: e[:request], error: e[:error].message } }
}
```
