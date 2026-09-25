# 008 — Streaming (Basic)

## Topic

How to get responses from a request token-by-token in real time instead of waiting for the complete response.

## Why This Is Needed

Streaming improves UX — users see the response as it's being generated instead of waiting for completion. Critical for web applications and chat interfaces.

## Example

```ruby
class StreamingPrompt
  def call
    "You are a helpful assistant. Answer questions clearly and in detail."
  end
end

class StreamingRequest < ActiveHarness::Request
  system_prompt StreamingPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

# Create a stream to receive tokens
tokens = []
token_stream = ->(token) do
  tokens << token
  print token  # Output token immediately
end

# Call the request with streaming
request = StreamingRequest.new(
  input: "Tell me about the history of computers",
  token: token_stream
)

request.call
result = request.result

puts "\n\n=== STATISTICS ==="
puts "Total tokens: #{tokens.length}"
puts "Full response: #{tokens.join}"
puts "Execution time: #{result.execution_time}s"
```
