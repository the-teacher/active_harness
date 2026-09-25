# Tribunals

## How to Create Your First Tribunal in 5 Minutes

A Tribunal runs multiple requests **in parallel** and reduces their results to a single **verdict**.

<img width="100%" src="images/tribunals.png" alt="Tribunal Diagram"/>

### 1. Define a prompt

The prompt must instruct the model to return JSON with a consistent field every request in the tribunal will produce:

```ruby
class PolitenessPrompt
  def call
    <<~PROMPT
      Evaluate whether the user's message is polite.
      Return only valid JSON, no prose, no code fences:
      RESPONSE FORMAT:
      {
        "result": true|false,
        "reason": "..."
      }
    PROMPT
  end
end
```

### 2. Define a request

```ruby
class PolitenessRequest < ActiveHarness::Request
  system_prompt PolitenessPrompt
  format :json

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end
end
```

### 3. Define a tribunal — one request, three models in parallel

Pass three pre-built instances of the same request, each configured with a different model. The tribunal runs them simultaneously and computes a consensus verdict:

```ruby
class PolitenessTribunal < ActiveHarness::Tribunal
  # Verdict is true only when all three models agree
  process do |results|
    results.all? { |r| r.processed["result"] == true }
  end

  def initialize(input:)
    super(
      input:  input,
      requests: [
        PolitenessRequest.new(models: [{ provider: :openrouter, model: "mistralai/mistral-nemo" }]),
        PolitenessRequest.new(models: [{ provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free" }]),
        PolitenessRequest.new(models: [{ provider: :openrouter, model: "google/gemma-4-31b-it:free" }])
      ]
    )
  end
end
```

### 4. Call the tribunal

```ruby
tribunal = PolitenessTribunal.new
tribunal.input = "I hate this product!"
tribunal.call

puts tribunal.verdict          # => true / false
puts tribunal.execution_time   # => 1.243  — wall time of the parallel run
```

### 5. Inspect results

```ruby
tribunal.results.each do |result|
  puts result.model.name
  puts result.processed["result"]   # => true / false
  puts result.processed["reason"]   # => "The message is impolite because..."
  puts result.execution_time
end

tribunal.errors.each do |e|
  puts "#{e[:request]}: #{e[:error].message}"
end
```

---

## Tribunal from Different Requests

Each request in a tribunal checks a different aspect of the input. Define a prompt and a request per concern, then assemble them into a tribunal.

### Prompts

```ruby
class PolitenessPrompt
  def call
    <<~PROMPT
      Evaluate whether the user's message is polite.
      Return only valid JSON, no prose, no code fences:
      {"result": true|false, "reason": "..."}
    PROMPT
  end
end

class ConstructivenessPrompt
  def call
    <<~PROMPT
      Evaluate whether the user's message is constructive and helpful.
      Return only valid JSON, no prose, no code fences:
      {"result": true|false, "reason": "..."}
    PROMPT
  end
end

class RelevancePrompt
  def call
    <<~PROMPT
      Evaluate whether the user's message is relevant to the discussion topic.
      Return only valid JSON, no prose, no code fences:
      {"result": true|false, "reason": "..."}
    PROMPT
  end
end
```

### Requests

```ruby
class PolitenessRequest < ActiveHarness::Request
  system_prompt PolitenessPrompt
  format :json

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end
end

class ConstructivenessRequest < ActiveHarness::Request
  system_prompt ConstructivenessPrompt
  format :json

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end
end

class RelevanceRequest < ActiveHarness::Request
  system_prompt RelevancePrompt
  format :json

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end
end
```

### Tribunal

```ruby
class ContentQualityTribunal < ActiveHarness::Tribunal
  requests PolitenessRequest, ConstructivenessRequest, RelevanceRequest

  process do |results|
    results.all? { |r| r.processed["result"] == true }
  end
end
```

```ruby
tribunal = ContentQualityTribunal.new
tribunal.input = "I hate this product!"
tribunal.call

puts tribunal.verdict  # => true only when all three requests agree
```

---

## Verdict Strategies

Instead of a custom `process` block, use a built-in strategy with an evaluator block:

| Strategy     | Verdict is `true` when…                              |
| ------------ | ---------------------------------------------------- |
| `:unanimous` | **every** successful request evaluates to `true`       |
| `:majority`  | **more than half** of successful requests evaluate to `true` |

```ruby
class SafetyTribunal < ActiveHarness::Tribunal
  requests ToxicityRequest, AggressionRequest

  # true only when every request evaluates to true
  verdict :unanimous do |result|
    result.processed["result"] == true
  end
end
```

```ruby
class ModerationTribunal < ActiveHarness::Tribunal
  requests SentimentRequest, ToneRequest, RelevanceRequest

  # true when more than half of requests evaluate to true
  verdict :majority do |result|
    result.processed["result"] == true
  end
end
```

---

## Custom Verdict Logic

For anything beyond `:unanimous` and `:majority`, use a `process` block. It receives the full array of successful results and its return value becomes `#verdict`.

**At least one request says ok:**

```ruby
class SafetyTribunal < ActiveHarness::Tribunal
  requests ToxicityRequest, AggressionRequest, SpamRequest

  process do |results|
    results.any? { |r| r.processed["result"] == true }
  end
end
```

**Minimum count threshold:**

```ruby
process do |results|
  results.count { |r| r.processed["result"] == true } >= 2
end
```

**Weighted by confidence score:**

```ruby
process do |results|
  total_score = results.sum { |r| r.processed["score"].to_f }
  total_score / results.size >= 0.7
end
```

The `process` block can also be set on an instance to override the class-level definition for a single call:

```ruby
tribunal = SafetyTribunal.new(input: "...")
tribunal.process { |results| results.any? { |r| r.processed["result"] == true } }
tribunal.call
```

Priority order when multiple definitions exist:

```
instance process block  →  class process block  →  verdict strategy
```

---

## Tolerating Partial Failures

By default a tribunal raises `AllRequestsFailed` only when **all** requests fail. Use `may_fail:` to set a stricter threshold:

```ruby
class SafetyTribunal < ActiveHarness::Tribunal
  requests ToxicityRequest, AggressionRequest, SpamRequest

  # Raise AllRequestsFailed if more than 1 request fails
  verdict :unanimous, may_fail: 1 do |result|
    result.processed["result"] == true
  end
end
```

Requests that fail or time out are collected in `tribunal.errors` and excluded from the verdict:

```ruby
tribunal.errors.each do |e|
  puts "#{e[:request]}: #{e[:error].message}"
end
```

---

## Same Request, Different Models

Pass pre-built request instances to run the same prompt through multiple models and reach consensus:

```ruby
class PolitenessTribunal < ActiveHarness::Tribunal
  process do |results|
    results.all? { |r| r.processed["result"] == true }
  end

  def initialize(input:)
    super(
      input:  input,
      requests: [
        PolitenessRequest.new(models: [{ provider: :openrouter, model: "mistralai/mistral-nemo" }]),
        PolitenessRequest.new(models: [{ provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free" }])
      ]
    )
  end
end
```

---

## Runtime Model Prepend per Request

Use `models.prepend` to inject a high-priority model into each request's chain at runtime — without changing the class definition. Useful for A/B testing, routing by user tier, or temporarily promoting a model.

```ruby
class PolitenessTribunal < ActiveHarness::Tribunal
  process do |results|
    results.all? { |r| r.processed["result"] == true }
  end

  def initialize(input:, fast_model: nil)
    requests = [
      PolitenessRequest.new,
      PolitenessRequest.new,
      PolitenessRequest.new
    ]

    # Prepend a different first-choice model to each request instance
    requests[0].models.prepend([{ provider: :openrouter, model: "mistralai/mistral-nemo" }])
    requests[1].models.prepend([{ provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free" }])
    requests[2].models.prepend([{ provider: :openrouter, model: "google/gemma-4-31b-it:free" }])

    # Optionally prepend a shared fast model to all requests at position 0
    if fast_model
      requests.each do |request|
        request.models.prepend([{ provider: :openrouter, model: fast_model }])
      end
    end

    super(input: input, requests: requests)
  end
end
```

```ruby
tribunal = PolitenessTribunal.new(input: "I hate this product!")
tribunal.call

tribunal.results.each do |result|
  puts "#{result.model.name}: #{result.processed["result"].inspect}"
end
```

---

## Direct Usage

Create a tribunal inline without subclassing:

```ruby
tribunal = ActiveHarness::Tribunal.new(
  input:   "Is this message toxic?",
  requests:  [ToxicityRequest, AggressionRequest],
  timeout: 7
)

tribunal.process { |results| results.all? { |r| r.processed["result"] == true } }
tribunal.call

puts tribunal.verdict
```

> `timeout:` sets the per-request wait limit in seconds (default: 7). Requests that exceed it are recorded in `#errors` as `TimeoutError`.

---

## Lifecycle Events

| Event                | Alias                   | Arguments          | When it fires                                   |
| -------------------- | ----------------------- | ------------------ | ----------------------------------------------- |
| `on :before_call`    | `before :call`          | —                  | Before any request is dispatched                  |
| `on :before_request`   | `before :request`         | `request, index`     | Before each request future is launched            |
| `on :after_request`    | `after :request`          | `result, index`    | After each request completes successfully         |
| `on :request_error`    | `callback :request_error` | `name, error, index` | When a request fails or times out              |
| `on :after_call`     | `after :call`           | `results, errors`  | After all requests finish, before verdict         |
| `on :before_verdict` | `before :verdict`       | `results`          | Before verdict — transform hook                 |
| `on :after_verdict`  | `after :verdict`        | `verdict`          | After verdict is computed                       |

> `on :before_verdict` is a **transform hook** — its return value replaces the results array passed to the `process` block. Use it to filter or reorder results before the verdict.

To share hooks across tribunals, extract them into a module:

```ruby
module TribunalLogging
  def self.included(base)
    base.on(:before_call) do
      Rails.logger.info("[#{self.class.name}] starting")
    end

    base.on(:after_request) do |result|
      Rails.logger.info("[#{self.class.name}] request done — #{result.model.name}: #{result.processed.inspect}")
    end

    base.on(:request_error) do |name, error|
      Rails.logger.warn("[#{self.class.name}] request failed — #{name}: #{error.message}")
    end

    base.on(:after_call) do |results, errors|
      Rails.logger.info("[#{self.class.name}] done — #{results.size} ok, #{errors.size} failed")
    end

    base.on(:after_verdict) do |verdict|
      Rails.logger.info("[#{self.class.name}] verdict: #{verdict.inspect}")
    end
  end
end
```

```ruby
class ContentQualityTribunal < ActiveHarness::Tribunal
  include TribunalLogging

  requests PolitenessRequest, ConstructivenessRequest

  verdict :unanimous do |result|
    result.processed["result"] == true
  end
end
```
