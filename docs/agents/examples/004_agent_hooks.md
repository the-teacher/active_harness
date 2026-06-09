# 004 — Agent Lifecycle Hooks

## Topic

How to use hooks to execute code at different stages of agent execution.

## Why This Is Needed

Hooks let you intervene in the agent's workflow: normalize input data, log events, transform results, and handle errors.

## Example

```ruby
class HookedPrompt
  def call
    <<~PROMPT
      Answer the question and return a JSON object with the following field:
      - "answer": your response as a string

      Example output:
      {
        "answer": "The capital of France is Paris."
      }

      Return only valid JSON, no explanation.
    PROMPT
  end
end

class HookedAgent < ActiveHarness::Agent
  system_prompt HookedPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # Hook 1: setup — initialization before everything
  on :setup do
    puts "[SETUP] Initializing agent..."
    @input = @input&.strip&.gsub(/\s+/, " ")
    @context[:started_at] = Time.now
  end

  # Hook 2: before_call — before sending request
  before :call do
    puts "[BEFORE_CALL] Preparing to send request..."
    puts "  Input: #{@input}"
    puts "  Context: #{@context.inspect}"
  end

  # Hook 3: after_system_prompt — after building prompt
  after :system_prompt do |prompt|
    puts "[AFTER_SYSTEM_PROMPT] Prompt built (#{prompt.length} chars)"
  end

  # Hook 4: before_parse — before parsing result
  before :parse do |output|
    puts "[BEFORE_PARSE] LLM output received (#{output.length} chars)"
    # Can transform the output before JSON parsing
    output.strip
  end

  # Hook 5: after_parse — after parsing
  after :parse do |parsed|
    puts "[AFTER_PARSE] Result parsed"
    # Can add metadata
    parsed.merge("processed_at" => Time.now.iso8601)
  end

  # Hook 6: after_call — after successful call
  after :call do |result|
    puts "[AFTER_CALL] ✓ Success!"
    puts "  Model: #{result.model}"
    puts "  Execution time: #{result.execution_time}s"
    puts "  Tokens: #{result.usage[:total_tokens]}"
  end

  # Hook 7: retry — on model error
  on :retry do |entry, error|
    puts "[RETRY] ✗ Error in #{entry[:model]}"
    puts "  Error: #{error.class.name} — #{error.message}"
  end

  # Hook 8: failure — when all models exhausted
  on :failure do |attempts|
    puts "[FAILURE] ✗ All #{attempts.size} models failed"
  end
end

# Use the agent
agent = HookedAgent.new(input: "  Hello,  how are you?  ")
agent.call
result = agent.result

puts "\n=== RESULT ==="
puts result.parsed["answer"]
puts result.parsed["processed_at"]
```

## Hook Execution Order

```
1. :setup
   ↓
2. :before_call
   ↓
3. :before_system_prompt
4. :after_system_prompt
   ↓
5. HTTP request to LLM
   ↓
6. :before_parse
7. :after_parse
   ↓
8. :after_call (on success)
   or
   :retry → :failure (on error)
```

## Hook Types

| Hook                    | Alias                   | Arguments       | Purpose                    |
| ----------------------- | ----------------------- | --------------- | -------------------------- |
| `:setup`                | `callback :setup`       | —               | Initialize before anything |
| `:before_call`          | `before :call`          | —               | Before HTTP request        |
| `:after_call`           | `after :call`           | `result`        | After successful response  |
| `:before_system_prompt` | `before :system_prompt` | —               | Before building prompt     |
| `:after_system_prompt`  | `after :system_prompt`  | `prompt`        | After building prompt      |
| `:before_parse`         | `before :parse`         | `output`        | Before parsing (transform) |
| `:after_parse`          | `after :parse`          | `parsed`        | After parsing (transform)  |
| `:parse_error`          | `callback :parse_error` | `output, error` | On parse error             |
| `:retry`                | `callback :retry`       | `entry, error`  | On model error             |
| `:failure`              | `callback :failure`     | `attempts`      | When all models exhausted  |
