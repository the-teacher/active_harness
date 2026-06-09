# 010 — Streaming (Multiple Streams and Error Handling)

## Topic

How to stream both tokens and agent events simultaneously, and how to handle errors during streaming.

## Why This Is Needed

In addition to tokens, you can stream agent lifecycle events (like model retries) to the client. This gives full visibility into what's happening during generation.

## Multiple Streams

```ruby
class StreamingPrompt
  def call
    "You are a helpful assistant. Answer questions clearly and in detail."
  end
end
```

```ruby
class StreamingAgent < ActiveHarness::Agent
  system_prompt StreamingPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  on :retry do |entry, error|
    @streams[:agent]&.call({ type: "retry", model: entry[:model], error: error.message })
  end
end

tokens = []
events = []

token_stream = ->(token) do
  tokens << token
  print token
end

event_stream = ->(event) do
  events << event
  puts "\n[EVENT] #{event[:type]}: #{event[:model]}"
end

agent = StreamingAgent.new(
  input: "Question",
  streams: { token: token_stream, agent: event_stream }
)

agent.call
```

## Error Handling

```ruby
begin
  token_stream = ->(token) do
    print token
  end

  agent = StreamingAgent.new(
    input: "Question",
    streams: { token: token_stream }
  )

  agent.call
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "\nError: all models exhausted"
rescue => e
  puts "\nError: #{e.message}"
end
```

## Best Practices

1. **Handle client disconnection** — use `rescue ActionController::Live::ClientDisconnected`
2. **Disable caching** — set appropriate headers
3. **Disable buffering** — use `X-Accel-Buffering: no`
4. **Log events** — add logging for debugging
5. **Test thoroughly** — check behavior in various scenarios
