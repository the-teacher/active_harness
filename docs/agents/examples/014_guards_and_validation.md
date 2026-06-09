# 014 — Guards and Validation

## Topic

How to use guards to validate input data and results, and to enforce safety.

## Why This Is Needed

Guards protect the agent from invalid input, malicious content, and ensure output quality. Critical for production applications.

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
class GuardedAgent < ActiveHarness::Agent
  system_prompt GuardedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # guard for input validation
  guard :input_validation do
    if @input.blank?
      raise ActiveHarness::GuardError, "Input cannot be empty"
    end

    if @input.length > 5000
      raise ActiveHarness::GuardError, "Input is too long (max 5000 characters)"
    end

    if contains_malicious_content?(@input)
      raise ActiveHarness::GuardError, "Input contains malicious content"
    end
  end

  # guard for output validation
  guard :output_validation do
    output = @result.output

    if output.blank?
      raise ActiveHarness::GuardError, "Output is empty"
    end

    if @context[:expect_json] && !valid_json?(output)
      raise ActiveHarness::GuardError, "Output is not valid JSON"
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
  rescue JSON.ParserError
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

rescue ActiveHarness::GuardError => e
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

  guard :input_length do
    if @input.length < 3
      raise ActiveHarness::GuardError, "Input too short"
    end
  end

  guard :input_language do
    unless russian?(@input) || english?(@input)
      raise ActiveHarness::GuardError, "Only Russian or English supported"
    end
  end

  guard :input_format do
    if @context[:expect_email] && !valid_email?(@input)
      raise ActiveHarness::GuardError, "Invalid email format"
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

  guard :output_length do
    if @result.output.length > 10000
      raise ActiveHarness::GuardError, "Output too long"
    end
  end

  guard :output_safety do
    if contains_harmful_content?(@result.output)
      raise ActiveHarness::GuardError, "Output contains harmful content"
    end
  end

  guard :output_format do
    if @context[:expect_json]
      unless valid_json?(@result.output)
        raise ActiveHarness::GuardError, "Output is not valid JSON"
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
  rescue JSON.ParserError
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

  guard :context_validation do
    required_params = [:user_id, :language]
    missing = required_params - @context.keys

    if missing.any?
      raise ActiveHarness::GuardError, "Missing context: #{missing.join(', ')}"
    end

    unless [:Russian, :English].include?(@context[:language])
      raise ActiveHarness::GuardError, "Invalid language"
    end
  end
end
```

## Guard Error Handling

```ruby
begin
  agent = GuardedAgent.new(input: "")
  agent.call

rescue ActiveHarness::GuardError => e
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

    rescue ActiveHarness::GuardError => e
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

  guard :input_validation do
    validate_input!
  end

  guard :context_validation do
    validate_context!
  end

  guard :output_validation do
    validate_output!
  end

  on :retry do |entry, error|
    puts "[RETRY] #{entry[:model]}"
  end

  private

  def validate_input!
    raise ActiveHarness::GuardError, "Empty input" if @input.blank?
    raise ActiveHarness::GuardError, "Input too long" if @input.length > 5000
  end

  def validate_context!
    raise ActiveHarness::GuardError, "Missing user_id" unless @context[:user_id]
  end

  def validate_output!
    raise ActiveHarness::GuardError, "Empty output" if @result.output.blank?
  end
end
```

## Best Practices

1. **Validate input data** — check type, length, and format
2. **Check for safety** — detect malicious content
3. **Validate results** — make sure the output meets expectations
4. **Log rejections** — track which guards fire and how often
5. **Test guards** — make sure they work correctly
