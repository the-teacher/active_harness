# 012 — Error Handling and Retry Logic

## Topic

How to handle errors properly, use retry logic, and fallback chains for reliability.

## Why This Is Needed

Errors are inevitable in production. Proper error handling and retry logic ensure reliability and improve UX.

## Example

First, define the prompt class:

```ruby
class RobustPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class RobustAgent < ActiveHarness::Agent
  system_prompt RobustPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo", temperature: 0.5
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
    fallback provider: :openrouter, model: "google/gemma-4-31b-it:free"
  end

  on :retry do |entry, error|
    puts "[RETRY] #{entry[:provider]}/#{entry[:model]}"
    puts "  Error: #{error.class.name}"
    puts "  Message: #{error.message}"

    log_error(entry, error)
  end

  on :failure do |attempts|
    puts "[FAILURE] All models exhausted:"
    attempts.each_with_index do |attempt, i|
      puts "  #{i + 1}. #{attempt[:model]}"
      puts "     Error: #{attempt[:error]}"
    end
  end

  private

  def log_error(entry, error)
    # send to your logging system here
    Rails.logger.error({
      agent: self.class.name,
      model: entry[:model],
      error_class: error.class.name,
      error_message: error.message,
      timestamp: Time.now
    }.to_json)
  end
end

# Usage with error handling
begin
  agent = RobustAgent.new(input: "Question")
  agent.call
  result = agent.result
  puts "✓ Success: #{result.output}"

rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "✗ All models exhausted"
  # fallback: use a cached response or error message
  puts "Using cached response..."

rescue ActiveHarness::Errors::InvalidApiKeyError => e
  puts "✗ API key error"
  # critical error — notify the administrator

rescue ActiveHarness::Errors::SafetyBlockedError => e
  puts "✗ Content blocked by safety policy"
  # content failed safety check

rescue => e
  puts "✗ Unexpected error: #{e.class.name} — #{e.message}"
end
```

## Error Types

### Retryable errors (move to the next model)

```ruby
# TimeoutError             — model did not respond in time
# RateLimitError           — request rate limit exceeded
# ServerError              — provider server error
# ProviderUnavailableError — provider is unavailable
# InvalidRequestError      — bad request (but another model may succeed)
```

### Non-retryable errors (stop the chain)

```ruby
# InvalidApiKeyError — invalid API key
# SafetyBlockedError — content blocked
```

## Error Handling with Logging

```ruby
class LoggingAgent < ActiveHarness::Agent
  system_prompt LoggingPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  on :setup do
    @attempt_count = 0
    @start_time = Time.now
  end

  on :before_call do
    @attempt_count += 1
    puts "[ATTEMPT #{@attempt_count}] Starting..."
  end

  on :after_call do |result|
    elapsed = Time.now - @start_time
    puts "[SUCCESS] Completed in #{elapsed.round(2)}s"
    puts "  Model: #{result.model.name}"
    puts "  Tokens: #{result.usage.tokens.total}"
    puts "  Cost: $#{result.usage.cost.total}"
  end

  on :retry do |entry, error|
    elapsed = Time.now - @start_time
    puts "[RETRY] After #{elapsed.round(2)}s"
    puts "  Failed model: #{entry[:model]}"
    puts "  Error: #{error.class.name}"
  end

  on :failure do |attempts|
    elapsed = Time.now - @start_time
    puts "[FAILURE] After #{elapsed.round(2)}s and #{attempts.size} attempts"
  end
end
```

## Retry with Exponential Backoff

```ruby
class RetryAgent < ActiveHarness::Agent
  system_prompt RetryPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  on :retry do |entry, error|
    delay = exponential_delay
    puts "[RETRY] Waiting #{delay}s before next attempt..."
    sleep(delay)
  end

  private

  def exponential_delay
    attempt = @retry_count ||= 0
    @retry_count += 1
    2 ** attempt  # 1s, 2s, 4s, 8s...
  end
end
```

## Handling with a Fallback Value

```ruby
def call_agent_with_fallback(input)
  agent = RobustAgent.new(input: input)
  agent.call
  agent.result.output
rescue ActiveHarness::Errors::AllModelsFailed => e
  # return a fallback response
  "Sorry, I'm temporarily unavailable. Please try again later."
rescue => e
  # log the unexpected error
  Rails.logger.error("Agent error: #{e.message}")
  "An error occurred. Please contact support."
end
```

## Handling in a Rails Controller

```ruby
class Ai::AgentsController < ApplicationController
  def call
    begin
      agent = RobustAgent.new(input: params[:input])
      agent.call
      result = agent.result

      render json: {
        success: true,
        output: result.output,
        model: result.model.name,
        time: result.execution_time
      }

    rescue ActiveHarness::Errors::AllModelsFailed => e
      render json: {
        success: false,
        error: "All models failed",
        message: "Please try again later"
      }, status: :service_unavailable

    rescue ActiveHarness::Errors::InvalidApiKeyError => e
      render json: {
        success: false,
        error: "Configuration error"
      }, status: :internal_server_error

    rescue => e
      Rails.logger.error("Unexpected error: #{e.message}")
      render json: {
        success: false,
        error: "Unexpected error"
      }, status: :internal_server_error
    end
  end
end
```

## Best Practices

1. **Always use a fallback chain** — at least 2–3 models
2. **Log errors** — send to a monitoring system
3. **Handle different error types** — retryable vs non-retryable
4. **Provide fallback responses** — don't leave the user without an answer
5. **Monitor metrics** — track success rate and response time
