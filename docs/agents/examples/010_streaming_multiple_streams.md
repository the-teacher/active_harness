# 010 — Streaming (Tokens + Lifecycle Events)

## Topic

How to stream both tokens and agent lifecycle events simultaneously, and how to handle errors during streaming.

## Why This Is Needed

In addition to raw tokens, you can stream agent lifecycle events (before_call, after_call, retry, failure) to the client. This gives full visibility into what's happening during generation — useful for sidebars, progress indicators, and debugging.

## Two Streaming Parameters

| Parameter | Lambda signature           | Fires when                        |
| --------- | -------------------------- | --------------------------------- |
| `token:`  | `->(chunk) {}`             | Each raw token arrives from LLM   |
| `stream:` | `->(source, event, *args)` | Each lifecycle hook fires         |

`source` is always `:agent` when used with a standalone agent. In pipelines it can also be `:tribunal` or `:pipeline`.

## Token Streaming Only

```ruby
class StreamingAgent < ActiveHarness::Agent
  system_prompt StreamingPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

tokens = []

agent = StreamingAgent.new(
  input: "Tell me about the history of computers",
  token: ->(chunk) { tokens << chunk; print chunk }
)
agent.call

puts "\nTotal chunks: #{tokens.length}"
puts "Full response: #{agent.result.output}"
```

## Tokens + Lifecycle Events

```ruby
class StreamingAgent < ActiveHarness::Agent
  system_prompt StreamingPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end
end

tokens = []
events = []

agent = StreamingAgent.new(
  input:  "Question",
  token:  ->(chunk)              { tokens << chunk; print chunk },
  stream: ->(_source, event, *args) {
    events << event
    puts "\n[#{event}]" if event == :retry
  }
)
agent.call

puts "\nLifecycle events: #{events.join(', ')}"
```

## Error Handling During Streaming

```ruby
begin
  agent = StreamingAgent.new(
    input: "Question",
    token: ->(chunk) { print chunk }
  )
  agent.call
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "\nAll models exhausted"
rescue => e
  puts "\nError: #{e.message}"
end
```

## Rails SSE — Tokens and Events to the Browser

```ruby
class Ai::AgentsController < ApplicationController
  include ActionController::Live

  def lifecycle_stream
    prepare_sse_response

    input         = params.require(:input)
    sse_tokens    = ActionController::Live::SSE.new(response.stream, event: "message")
    sse_lifecycle = ActionController::Live::SSE.new(response.stream, event: "lifecycle")

    SupportAgent.call(
      input:  input,
      token:  ->(chunk) { sse_tokens.write({ token: chunk }.to_json) },
      stream: ->(_source, event, *args) {
        payload = lifecycle_event_message(event, args)
        sse_lifecycle.write(payload.to_json) if payload
      rescue IOError, ActionController::Live::ClientDisconnected
      }
    )

    sse_tokens.write({ done: true }.to_json)
  rescue ActionController::Live::ClientDisconnected
  rescue StandardError => e
    sse_tokens.write({ error: e.message }.to_json) rescue nil
    sse_tokens.write({ done: true }.to_json) rescue nil
  ensure
    sse_tokens.close
  end
end
```

## Best Practices

1. **Handle client disconnection** — rescue `ActionController::Live::ClientDisconnected` inside the `stream:` lambda and in the action
2. **Disable caching** — set `Content-Type: text/event-stream`, `Cache-Control: no-cache`
3. **Disable buffering** — add `X-Accel-Buffering: no` so nginx doesn't batch tokens
4. **Use `_source` prefix** — prefix the source param with `_` when you don't need it (agent-only context)
5. **Send a `done` event** — lets the client know generation finished and close the `EventSource`
