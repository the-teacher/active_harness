# 002 — Fallback Chain (Basic)

## Topic

How to configure multiple models so that if one fails, the next one is automatically used.

## Why This Is Needed

A fallback chain ensures reliability. If the primary model is unavailable, the system automatically switches to a backup. This is critical for production applications.

## Example

First, define the prompt class:

```ruby
class ResilientPrompt
  def call
    "You are a helpful assistant. Answer questions concisely."
  end
end
```

Then define the agent with a fallback chain:

```ruby
class ResilientAgent < ActiveHarness::Agent
  system_prompt ResilientPrompt

  # Define the model chain
  model do
    # Primary model
    use provider: :openrouter, model: "mistralai/mistral-nemo", temperature: 0.5

    # Backup models (fallback)
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
    fallback provider: :openrouter, model: "google/gemma-4-31b-it:free"
    fallback provider: :openrouter, model: "qwen/qwen3-coder:free"
  end
end

# Use the agent
agent = ResilientAgent.new(input: "What is the meaning of life?")
agent.call
result = agent.result

puts "✓ Successfully used model: #{result.model}"
puts "Response: #{result.output}"
```

## Error Handling

```ruby
begin
  agent = ResilientAgent.new(input: "Question")
  agent.call
  result = agent.result
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "All models exhausted: #{e.message}"
rescue ActiveHarness::Errors::InvalidApiKeyError => e
  puts "API key issue: #{e.message}"
end
```
