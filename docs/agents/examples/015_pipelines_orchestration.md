# 015 — Pipelines and Agent Orchestration

## Topic

How to build pipelines for sequential or parallel execution of multiple agents.

## Why This Is Needed

Pipelines let you combine multiple agents to solve complex tasks. For example: analyze text → translate → format.

> The examples below show manual orchestration in plain Ruby, for illustration. For a real sequential-step orchestrator with built-in hooks, `stop_if`, and context propagation between steps, use `ActiveHarness::Pipeline` instead; see [PIPELINES.md](../../PIPELINES.md).

## Sequential Pipeline

First, define the prompt classes and agents:

```ruby
class AnalysisPrompt
  def call
    "Analyze the text. Identify main topics and key claims."
  end
end

class SentimentPrompt
  def call
    "Determine the sentiment: positive, negative, or neutral."
  end
end

class TranslationPrompt
  def call
    language = @context[:target_language] || "English"
    "Translate the text to #{language}."
  end
end

class AnalysisAgent < ActiveHarness::Agent
  system_prompt AnalysisPrompt
  model { use provider: :openrouter, model: "mistralai/mistral-nemo" }
end

class SentimentAgent < ActiveHarness::Agent
  system_prompt SentimentPrompt
  model { use provider: :openrouter, model: "mistralai/mistral-nemo" }
end

class TranslationAgent < ActiveHarness::Agent
  system_prompt TranslationPrompt
  model { use provider: :openrouter, model: "mistralai/mistral-nemo" }
end
```

Then define the pipeline:

```ruby
class AnalysisPipeline
  def initialize(input)
    @input = input
    @results = {}
  end

  def call
    puts "[STEP 1] Analyzing text..."
    @results[:analysis] = analyze_text

    puts "[STEP 2] Detecting sentiment..."
    @results[:sentiment] = detect_sentiment

    puts "[STEP 3] Translating..."
    @results[:translation] = translate_text

    puts "[STEP 4] Formatting result..."
    @results[:formatted] = format_result

    @results
  end

  private

  def analyze_text
    agent = AnalysisAgent.new(input: @input)
    agent.call
    agent.result.output
  end

  def detect_sentiment
    agent = SentimentAgent.new(input: @input)
    agent.call
    agent.result.output
  end

  def translate_text
    agent = TranslationAgent.new(
      input: @input,
      context: { target_language: "English" }
    )
    agent.call
    agent.result.output
  end

  def format_result
    {
      original: @input,
      analysis: @results[:analysis],
      sentiment: @results[:sentiment],
      translation: @results[:translation],
      timestamp: Time.now.iso8601
    }
  end
end

# Usage
pipeline = AnalysisPipeline.new("This is a great product!")
results = pipeline.call

puts "\n=== RESULTS ==="
puts results.to_json
```

## Parallel Pipeline

```ruby
require 'concurrent'

class ParallelAnalysisPipeline
  def initialize(input)
    @input = input
  end

  def call
    executor = Concurrent::ThreadPoolExecutor.new(max_threads: 3)

    analysis_promise = Concurrent::Promise.execute(executor: executor) do
      agent = AnalysisAgent.new(input: @input)
      agent.call
      agent.result.output
    end

    sentiment_promise = Concurrent::Promise.execute(executor: executor) do
      agent = SentimentAgent.new(input: @input)
      agent.call
      agent.result.output
    end

    translation_promise = Concurrent::Promise.execute(executor: executor) do
      agent = TranslationAgent.new(input: @input, context: { target_language: "English" })
      agent.call
      agent.result.output
    end

    results = {
      analysis: analysis_promise.value,
      sentiment: sentiment_promise.value,
      translation: translation_promise.value
    }

    executor.shutdown

    results
  end
end

# Usage
pipeline = ParallelAnalysisPipeline.new("This is a great product!")
results = pipeline.call

puts "Analysis: #{results[:analysis]}"
puts "Sentiment: #{results[:sentiment]}"
puts "Translation: #{results[:translation]}"
```

## Conditional Pipeline

```ruby
class ConditionalPipeline
  def initialize(input)
    @input = input
  end

  def call
    analysis = analyze_text

    if analysis.include?("negative")
      support_response = get_support_response
      return { analysis: analysis, support: support_response }
    elsif analysis.include?("positive")
      thank_you = send_thank_you
      return { analysis: analysis, thank_you: thank_you }
    else
      clarification = request_clarification
      return { analysis: analysis, clarification: clarification }
    end
  end

  private

  def analyze_text
    agent = AnalysisAgent.new(input: @input)
    agent.call
    agent.result.output
  end

  def get_support_response
    agent = SupportAgent.new(input: @input)
    agent.call
    agent.result.output
  end

  def send_thank_you
    agent = ThankYouAgent.new(input: @input)
    agent.call
    agent.result.output
  end

  def request_clarification
    agent = ClarificationAgent.new(input: @input)
    agent.call
    agent.result.output
  end
end
```

## Pipeline with Error Handling

```ruby
class RobustPipeline
  def initialize(input)
    @input = input
    @errors = []
  end

  def call
    begin
      step1_result = execute_step("Step 1", :analyze_text)
      return { error: "Step 1 failed" } if step1_result.nil?

      step2_result = execute_step("Step 2", :detect_sentiment, step1_result)
      return { error: "Step 2 failed" } if step2_result.nil?

      step3_result = execute_step("Step 3", :translate_text, step2_result)
      return { error: "Step 3 failed" } if step3_result.nil?

      {
        success: true,
        step1: step1_result,
        step2: step2_result,
        step3: step3_result,
        errors: @errors
      }

    rescue => e
      {
        success: false,
        error: e.message,
        errors: @errors
      }
    end
  end

  private

  def execute_step(name, method, *args)
    puts "[#{name}] Starting..."

    begin
      result = send(method, *args)
      puts "[#{name}] ✓ Success"
      result

    rescue ActiveHarness::Errors::AllModelsFailed => e
      @errors << "#{name}: All models failed"
      puts "[#{name}] ✗ All models failed"
      nil

    rescue => e
      @errors << "#{name}: #{e.message}"
      puts "[#{name}] ✗ Error: #{e.message}"
      nil
    end
  end

  def analyze_text
    agent = AnalysisAgent.new(input: @input)
    agent.call
    agent.result.output
  end

  def detect_sentiment(previous_result)
    agent = SentimentAgent.new(input: @input, context: { previous: previous_result })
    agent.call
    agent.result.output
  end

  def translate_text(previous_result)
    agent = TranslationAgent.new(input: @input, context: { target_language: "English" })
    agent.call
    agent.result.output
  end
end
```

## Pipeline in a Rails Controller

```ruby
class Ai::PipelinesController < ApplicationController
  def analyze
    begin
      pipeline = AnalysisPipeline.new(params[:input])
      results = pipeline.call

      render json: {
        success: true,
        results: results
      }

    rescue => e
      render json: {
        success: false,
        error: e.message
      }, status: :internal_server_error
    end
  end
end
```

## Best Practices

1. **Separate concerns** — each step should be its own method
2. **Handle errors** — each step can fail independently
3. **Log progress** — output information about each step
4. **Use parallelism** — when steps are independent
5. **Test** — verify each step in isolation
