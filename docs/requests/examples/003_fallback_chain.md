# 003 — Fallback Chain (With Callbacks)

## Topic

How to configure multiple models with callbacks to track retry attempts and complete failures.

## Why This Is Needed

Callbacks let you log, monitor, or react to model switching and complete failures. This is essential for observability and debugging in production systems.

## Example

First, define the prompt class:

```ruby
class ResilientPrompt
  def call
    "You are a helpful assistant. Answer questions concisely."
  end
end
```

Then define the request with callbacks for retry and failure:

```ruby
class ResilientRequest < ActiveHarness::Request
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

  # Log switch attempts
  on :retry do |entry, error|
    puts "[RETRY] #{entry[:provider]}/#{entry[:model]}"
    puts "[ERROR] #{error.class.name}: #{error.message}"
    puts "[INFO] Switching to next model...\n"
  end

  # Log complete failure
  on :failure do |attempts|
    puts "[FAILURE] All #{attempts.size} models failed:"
    attempts.each_with_index do |attempt, i|
      puts "  #{i + 1}. #{attempt[:model]} — #{attempt[:error]}"
    end
  end
end

# Use the request
request = ResilientRequest.new(input: "What is the meaning of life?")
request.call
result = request.result

puts "\n✓ Successfully used model: #{result.model.name}"
puts "Response: #{result.output}"
```

## Error Handling

```ruby
begin
  request = ResilientRequest.new(input: "Question")
  request.call
  result = request.result
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "All models exhausted: #{e.message}"
rescue ActiveHarness::Errors::InvalidApiKeyError => e
  puts "API key issue: #{e.message}"
end
```
