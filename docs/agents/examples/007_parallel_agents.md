# 007 — Parallel Agents

## Topic

How to run multiple agents simultaneously to process different tasks in parallel.

## Why This Is Needed

Parallel execution speeds up processing when you need results from multiple agents. For example, analyzing text from different perspectives at the same time.

## Example

```ruby
class AnalysisPrompt
  def call
    "Analyze the text. Identify main topics, tone, and key claims."
  end
end

class SentimentPrompt
  def call
    "Determine the sentiment of the text: positive, negative, or neutral. Explain briefly."
  end
end

class TranslationPrompt
  def call
    language = @context[:target_language] || "Spanish"
    "Translate the text to #{language}."
  end
end

class AnalysisAgent < ActiveHarness::Agent
  system_prompt AnalysisPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

class SentimentAgent < ActiveHarness::Agent
  system_prompt SentimentPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

class TranslationAgent < ActiveHarness::Agent
  system_prompt TranslationPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

# Text to analyze
text = "This is a great product! I'm very happy with the quality and service."

# Run agents in parallel
threads = []

analysis_result = nil
threads << Thread.new do
  agent = AnalysisAgent.new(input: text)
  agent.call
  analysis_result = agent.result
end

sentiment_result = nil
threads << Thread.new do
  agent = SentimentAgent.new(input: text)
  agent.call
  sentiment_result = agent.result
end

translation_result = nil
threads << Thread.new do
  agent = TranslationAgent.new(input: text, context: { target_language: "Spanish" })
  agent.call
  translation_result = agent.result
end

# Wait for all threads to complete
threads.each(&:join)

# Output results
puts "=== ANALYSIS ==="
puts analysis_result.output

puts "\n=== SENTIMENT ==="
puts sentiment_result.output

puts "\n=== TRANSLATION ==="
puts translation_result.output
```

## Using Concurrent::Promise (Recommended)

```ruby
require 'concurrent'

text = "This is a great product!"

# Create promises for each agent
analysis_promise = Concurrent::Promise.execute do
  agent = AnalysisAgent.new(input: text)
  agent.call
  agent.result
end

sentiment_promise = Concurrent::Promise.execute do
  agent = SentimentAgent.new(input: text)
  agent.call
  agent.result
end

translation_promise = Concurrent::Promise.execute do
  agent = TranslationAgent.new(input: text, context: { target_language: "Spanish" })
  agent.call
  agent.result
end

# Wait for results
analysis_result = analysis_promise.value
sentiment_result = sentiment_promise.value
translation_result = translation_promise.value

puts "Analysis: #{analysis_result.output}"
puts "Sentiment: #{sentiment_result.output}"
puts "Translation: #{translation_result.output}"
```

## Parallel Processing of Lists

```ruby
require 'concurrent'

texts = [
  "Great product!",
  "Didn't like it.",
  "Average quality."
]

# Process each text in parallel
promises = texts.map do |text|
  Concurrent::Promise.execute do
    agent = SentimentAgent.new(input: text)
    agent.call
    { text: text, sentiment: agent.result.output }
  end
end

# Collect results
results = promises.map(&:value)

results.each do |result|
  puts "Text: #{result[:text]}"
  puts "Sentiment: #{result[:sentiment]}\n"
end
```

## Error Handling in Parallel Execution

```ruby
require 'concurrent'

promises = [
  Concurrent::Promise.execute { AnalysisAgent.new(input: "text1").call },
  Concurrent::Promise.execute { SentimentAgent.new(input: "text2").call },
  Concurrent::Promise.execute { TranslationAgent.new(input: "text3").call }
]

results = promises.map do |promise|
  begin
    promise.value
  rescue => e
    puts "Error: #{e.message}"
    nil
  end
end

# Filter successful results
successful_results = results.compact
```

## Best Practices

1. **Use Concurrent::Promise** — safer than Thread
2. **Handle errors** — each agent can fail independently
3. **Limit parallelism** — don't run too many at once
4. **Log execution** — add logging for debugging
5. **Test thoroughly** — parallel code is harder to debug

## Limiting Parallelism

```ruby
require 'concurrent'

texts = (1..100).map { |i| "Text #{i}" }

# Process maximum 5 agents at once
executor = Concurrent::ThreadPoolExecutor.new(max_threads: 5)

promises = texts.map do |text|
  Concurrent::Promise.execute(executor: executor) do
    agent = SentimentAgent.new(input: text)
    agent.call
    agent.result
  end
end

results = promises.map(&:value)
executor.shutdown
```
