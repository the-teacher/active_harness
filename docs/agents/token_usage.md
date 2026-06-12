# Token Usage Info

When a provider returns token counts, they are available on the `Result` object under `#usage`.  
Not all providers return usage — the value is `nil` for streaming calls and some free-tier models.

```ruby
agent.call
result = agent.result

if result.usage
  puts result.usage.tokens.input   # => 41
  puts result.usage.tokens.output  # => 78
  puts result.usage.tokens.total   # => 119
end
```

For a tribunal, inspect each agent's result individually:

```ruby
tribunal.call

tribunal.results.each do |result|
  puts "#{result.model.name}: #{result.usage&.tokens&.total} tokens"
end
```
