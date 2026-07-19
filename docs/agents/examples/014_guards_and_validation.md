# 014 — Guards and Validation

## Topic

How to use guards to validate input data and results, and to enforce safety.

## Why This Is Needed

Guards protect the agent from invalid input, malicious content, and ensure output quality. Critical for production applications.

> ActiveHarness has no dedicated `guard` DSL. The examples below implement the same idea with the regular `on(:before_call)` / `on(:after_call)` hooks (see [agent_hooks.md](../agent_hooks.md)) plus a plain Ruby error class you define yourself.

## Example

First, define the prompt class:

```ruby
class GuardedPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class ValidationError < StandardError; end

class GuardedAgent < ActiveHarness::Agent
  system_prompt GuardedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # input validation — runs before the model is called
  on :before_call do
    if @input.blank?
      raise ValidationError, "Input cannot be empty"
    end

    if @input.length > 5000
      raise ValidationError, "Input is too long (max 5000 characters)"
    end

    if contains_malicious_content?(@input)
      raise ValidationError, "Input contains malicious content"
    end
  end

  # output validation — runs after a successful call, before the result is returned
  on :after_call do |result|
    output = result.output

    if output.blank?
      raise ValidationError, "Output is empty"
    end

    if @context[:expect_json] && !valid_json?(output)
      raise ValidationError, "Output is not valid JSON"
    end
  end

  private

  def contains_malicious_content?(text)
    malicious_patterns = [
      /DROP\s+TABLE/i,
      /DELETE\s+FROM/i,
      /<script/i,
      /javascript:/i
    ]

    malicious_patterns.any? do |pattern|
      text.match?(pattern)
    end
  end

  def valid_json?(text)
    JSON.parse(text)
    true
  rescue JSON::ParserError
    false
  end
end

# Usage
begin
  agent = GuardedAgent.new(
    input: "Question",
    context: { expect_json: false }
  )
  agent.call
  result = agent.result
  puts "✓ Result: #{result.output}"

rescue ValidationError => e
  puts "✗ Guard rejected: #{e.message}"
end
```

## Guard Types

### Input guards

```ruby
class InputGuardedAgent < ActiveHarness::Agent
  system_prompt InputGuardedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :before_call do
    raise ValidationError, "Input too short" if @input.length < 3
  end

  on :before_call do
    unless russian?(@input) || english?(@input)
      raise ValidationError, "Only Russian or English supported"
    end
  end

  on :before_call do
    if @context[:expect_email] && !valid_email?(@input)
      raise ValidationError, "Invalid email format"
    end
  end

  private

  def russian?(text)
    text.match?(/[а-яА-ЯёЁ]/)
  end

  def english?(text)
    text.match?(/[a-zA-Z]/)
  end

  def valid_email?(text)
    text.match?(/\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i)
  end
end
```

### Output guards

```ruby
class OutputGuardedAgent < ActiveHarness::Agent
  system_prompt OutputGuardedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :after_call do |result|
    raise ValidationError, "Output too long" if result.output.length > 10000
  end

  on :after_call do |result|
    if contains_harmful_content?(result.output)
      raise ValidationError, "Output contains harmful content"
    end
  end

  on :after_call do |result|
    if @context[:expect_json]
      unless valid_json?(result.output)
        raise ValidationError, "Output is not valid JSON"
      end
    end
  end

  private

  def contains_harmful_content?(text)
    harmful_patterns = [
      /hate|violence|discrimination/i,
      /illegal|crime/i
    ]

    harmful_patterns.any? do |pattern|
      text.match?(pattern)
    end
  end

  def valid_json?(text)
    JSON.parse(text)
    true
  rescue JSON::ParserError
    false
  end
end
```

### Context guards

```ruby
class ContextGuardedAgent < ActiveHarness::Agent
  system_prompt ContextGuardedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :before_call do
    required_params = [:user_id, :language]
    missing = required_params - @context.keys

    if missing.any?
      raise ValidationError, "Missing context: #{missing.join(', ')}"
    end

    unless [:Russian, :English].include?(@context[:language])
      raise ValidationError, "Invalid language"
    end
  end
end
```

## Guard Error Handling

```ruby
begin
  agent = GuardedAgent.new(input: "")
  agent.call

rescue ValidationError => e
  puts "Guard error: #{e.message}"
  Rails.logger.warn("Guard rejected: #{e.message}")

rescue => e
  puts "Unexpected error: #{e.message}"
end
```

## Guards in a Rails Controller

```ruby
class Ai::AgentsController < ApplicationController
  def call
    begin
      agent = GuardedAgent.new(
        input: params[:input],
        context: {
          user_id: current_user.id,
          language: current_user.language
        }
      )

      agent.call
      result = agent.result

      render json: {
        success: true,
        output: result.output
      }

    rescue ValidationError => e
      render json: {
        success: false,
        error: "Validation failed",
        message: e.message
      }, status: :unprocessable_entity

    rescue => e
      render json: {
        success: false,
        error: "Server error"
      }, status: :internal_server_error
    end
  end
end
```

## Combining Guards

```ruby
class ComprehensiveAgent < ActiveHarness::Agent
  system_prompt ComprehensivePrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  on :before_call do
    validate_input!
  end

  on :before_call do
    validate_context!
  end

  on :after_call do |result|
    validate_output!(result)
  end

  on :retry do |entry, error|
    puts "[RETRY] #{entry[:model]}"
  end

  private

  def validate_input!
    raise ValidationError, "Empty input" if @input.blank?
    raise ValidationError, "Input too long" if @input.length > 5000
  end

  def validate_context!
    raise ValidationError, "Missing user_id" unless @context[:user_id]
  end

  def validate_output!(result)
    raise ValidationError, "Empty output" if result.output.blank?
  end
end
```

## Best Practices

1. **Validate input data** — check type, length, and format
2. **Check for safety** — detect malicious content
3. **Validate results** — make sure the output meets expectations
4. **Log rejections** — track which guards fire and how often
5. **Test guards** — make sure they work correctly
