# Execution Time

Every object that makes an LLM call exposes `#execution_time` (seconds, rounded to 3 decimal places).

```ruby
# Agent — execution_time is on the result
agent.call
puts agent.result.execution_time    # => 1.352

# Tribunal — wall time for all agents running in parallel
tribunal.call
puts tribunal.execution_time        # => 0.94

# Pipeline — total wall time across all steps that ran
pipeline.call
puts pipeline.execution_time        # => 3.12

# Per step
pipeline.steps.each do |step_name, _executor, result|
  puts "#{step_name}: #{result.execution_time}s"
end
```
