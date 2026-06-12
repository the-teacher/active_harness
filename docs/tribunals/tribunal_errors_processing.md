# Tribunal Error Processing

A tribunal runs agents in parallel. Some agents may fail while others succeed.
ActiveHarness handles partial failures gracefully — the verdict is still computed
from the agents that succeeded.

---

## Partial Failures

When one or more agents fail (or time out), their errors are collected in `tribunal.errors`.
Successful results are still available in `tribunal.results` and the verdict is computed normally.

```ruby
tribunal = PolitenessTribunal.new(input: "Hello!")
tribunal.call

# Successful results only
tribunal.results.each do |result|
  puts "#{result.model.name}: #{result.processed["result"]}"
end

# Failed agents
tribunal.errors.each do |e|
  puts "#{e[:agent]}: #{e[:error].message}"
end

puts tribunal.verdict  # computed from successful results only
```

---

## Error Hash Structure

Each entry in `tribunal.errors` is a plain hash:

```ruby
{
  agent: "PolitenessAgent",         # class name of the agent that failed
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

## AllAgentsFailed

If **every** agent fails or times out, `tribunal.call` raises `AllAgentsFailed`
(not `AllModelsFailed` — that's agent-level):

```ruby
begin
  tribunal.call
rescue ActiveHarness::Errors::AllAgentsFailed => e
  puts "All agents failed: #{e.message}"
  # e.message contains a summary of every agent's error
end
```

---

## Timeouts

Each agent runs in a `Concurrent::Future` with a configurable timeout (default: 7 seconds).
If the future hasn't completed within the timeout window, it is treated as a `TimeoutError`:

```ruby
tribunal = MyTribunal.new(input: "...", timeout: 5)  # 5 seconds per agent
```

Timed-out agents appear in `tribunal.errors` with a `TimeoutError`:

```ruby
{ agent: "PolitenessAgent",
  error: #<ActiveHarness::Errors::TimeoutError: "Agent PolitenessAgent timed out after 5s"> }
```

---

## Reacting to Errors with Hooks

Use the `:agent_error` hook to react per-agent, and `:after_call` to inspect the full picture:

```ruby
class MyTribunal < ActiveHarness::Tribunal
  on(:agent_error) do |agent_name, error, index|
    Rails.logger.warn "[Agent #{index + 1}] #{agent_name}: #{error.message}"
  end

  on(:after_call) do |results, errors|
    if errors.any?
      Rails.logger.warn "#{errors.size} agent(s) failed, #{results.size} succeeded"
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
  # Require unanimous agreement — a missing agent counts as "not polite"
  results.size == 3 && results.all? { |r| r.processed["result"] == true }
end

# Or: majority vote regardless of how many agents responded
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
  errors:  tribunal.errors.map  { |e| { agent: e[:agent], error: e[:error].message } }
}
```
