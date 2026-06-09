# 005 — Parse Hooks

## Topic

How to use `before_parse` and `after_parse` hooks to transform JSON results from the LLM.

## Why This Is Needed

Parse hooks allow you to normalize, validate, and enrich structured results from the LLM before they're stored in `result.processed`. They only run when `format :json` is set.

## Transform Hooks

The `:before_parse` and `:after_parse` hooks are **transform hooks** — their return value replaces the current value:

- `before :parse` receives the LLM output string and returns a modified string for JSON parsing
- `after :parse` receives the parsed Hash/Array and returns a modified object

```ruby
class AnalysisPrompt
  def call
    <<~PROMPT
      Analyze the text and return a JSON object with the following fields:
      - "sentiment": overall tone, one of: "positive", "negative", "neutral"
      - "keywords": array of key words or phrases from the text

      Example output:
      {
        "sentiment": "positive",
        "keywords": ["great", "fast", "easy to use"]
      }

      Return only valid JSON, no explanation.
    PROMPT
  end
end
```

```ruby
class AnalysisAgent < ActiveHarness::Agent
  system_prompt AnalysisPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # Enrich the parsed hash with a timestamp
  after :parse do |parsed|
    parsed.merge("analyzed_at" => Time.now.iso8601)
  end
end

agent = AnalysisAgent.new(input: "The product is great and very fast!")
agent.call

puts agent.result.processed["sentiment"]    # => "positive"
puts agent.result.processed["analyzed_at"]  # => "2025-01-01T12:00:00Z"
```

## Parse Error Handling

The `:parse_error` hook fires when JSON parsing fails. If the hook returns a non-nil value, that value is used as the fallback result and the exception is suppressed. Return `nil` (or omit a return) to re-raise the exception.

```ruby
class ExtractPrompt
  def call
    <<~PROMPT
      Extract named entities from the text and return a JSON object with:
      - "names": array of person names found in the text
      - "places": array of place names found in the text

      Example output:
      {
        "names": ["Alice", "Bob"],
        "places": ["London", "Paris"]
      }

      Return only valid JSON, no explanation.
    PROMPT
  end
end
```

```ruby
class RobustAgent < ActiveHarness::Agent
  system_prompt ExtractPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # Replace single quotes with double quotes if the model used them
  before :parse do |output|
    output.gsub("'", '"')
  end

  # Return a safe fallback so the caller always gets a Hash
  on :parse_error do |output, error|
    puts "[PARSE_ERROR] #{error.message}"
    puts "Output (first 100 chars): #{output[0..100]}"
    { "names" => [], "places" => [], "parse_failed" => true }
  end
end
```

## Transformation Chain

```
1. :before_parse  — transform LLM output string before JSON.parse
   ↓
2. strip_code_fences (built-in, always runs)
   ↓
3. JSON.parse
   ↓
4. :after_parse   — transform the parsed Hash/Array
   ↓
5. result.processed  — final value
```

> **Note:** `before_parse` and `after_parse` only run when `format :json` is declared on the agent.
