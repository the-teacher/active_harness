# Agents

## How to Create Your First Agent in 5 Minutes

### 1. Define a prompt

A prompt is a plain Ruby class with a `#call` method that returns a string.

```ruby
class GreetingPrompt
  def call
    "You are a friendly assistant. Greet the user warmly and briefly."
  end
end
```

### 2. Define an agent

```ruby
class GreetingAgent < ActiveHarness::Agent
  system_prompt GreetingPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

### 3. Call the agent

```ruby
agent = GreetingAgent.new
agent.input = "Hello!"
agent.call

puts agent.result.output
```

### 4. Inspect the result

```ruby
result = agent.result

result.provider        # => "openrouter"
result.model           # => "mistralai/mistral-nemo"
result.input           # => "Hello!"
result.output          # => "Hey there! Great to meet you..."
result.usage           # => { input_tokens: 18, output_tokens: 24, total_tokens: 42 }
result.cost            # => { input_cost: 0.0, output_cost: 0.0, total_cost: 0.0 }
result.execution_time  # => 0.843
```

---

## How to Provide Fallbacks

Add `fallback` entries inside the `model` block. If the primary model fails, the next one is tried automatically.

```ruby
class GreetingAgent < ActiveHarness::Agent
  system_prompt GreetingPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
    fallback provider: :openrouter, model: "google/gemma-4-31b-it:free"
  end
end
```

When all models fail, `ActiveHarness::Errors::AllModelsFailed` is raised:

```ruby
begin
  agent.call
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "All models exhausted: #{e.message}"
end
```

---

## Model Options

Both `use` and `fallback` accept the same set of options:

| Option            | Type    | Default | Description                                    |
| ----------------- | ------- | ------- | ---------------------------------------------- |
| `provider:`       | Symbol  | —       | Provider key (`:openrouter`, `:anthropic`, …)  |
| `model:`          | String  | —       | Model identifier string                        |
| `temperature:`    | Float   | nil     | Sampling temperature (provider default if nil) |
| `retry_attempts:` | Integer | 3       | How many times to retry this model on failure  |
| `retry_delay:`    | Float   | 1.0     | Base delay in seconds between retries          |

```ruby
model do
  use      provider:       :openrouter,
           model:          "mistralai/mistral-nemo",
           temperature:    0.7,
           retry_attempts: 2,
           retry_delay:    0.5

  fallback provider:       :openrouter,
           model:          "meta-llama/llama-3.3-70b-instruct:free",
           retry_attempts: 1
end
```

> `name:` is only used with `provider: :custom` — it selects which custom endpoint to load from the configuration. See [Custom Provider](agents/examples/013_custom_llm_backend.md).

---

## Modifying the Model Chain at Runtime

`agent.models` returns a mutable `ModelList` proxy. Use it to adjust the chain after instantiation, before calling the agent.

| Method               | What it does                                               |
| -------------------- | ---------------------------------------------------------- |
| `prepend([...])`     | Inserts models **before** the class-defined chain          |
| `push([...])`        | Appends models **after** the class-defined chain           |
| `insert(pos, {...})` | Inserts a single model at an arbitrary position            |
| `replace([...])`     | Replaces the entire chain, discarding all previous models  |

```ruby
agent = GreetingAgent.new
agent.input = "Hello!"

# Try a fast model first, before the class-defined chain
agent.models.prepend([{ provider: :openrouter, model: "google/gemma-4-31b-it:free" }])

# Add a last-resort fallback at the end
agent.models.push([{ provider: :openrouter, model: "qwen/qwen3-coder:free" }])

# Insert a model at position 1 (after the first model)
agent.models.insert(1, { provider: :openrouter, model: "mistralai/mistral-small-24b-instruct-2501:free" })

# Replace the entire chain for this request only
agent.models.replace([{ provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free" }])

agent.call
```

The final order is: `prepended + class chain + pushed`. `insert` collapses everything into a single flat list at the moment of insertion.

---

## How to Track Retries and Failures

Use `on :retry` to react to each failed model attempt, and `on :failure` when the entire chain is exhausted.

```ruby
class GreetingAgent < ActiveHarness::Agent
  system_prompt GreetingPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  # Fires after each failed attempt — before trying the next model.
  # entry — the model entry that failed: { provider:, model:, ... }
  # error — the exception raised
  on :retry do |entry, error|
    Rails.logger.warn("Model failed: #{entry[:model]} — #{error.message}")
  end

  # Fires when all models in the chain have failed.
  # attempts — array of { provider:, model:, error:, error_code:, execution_time: }
  on :failure do |attempts|
    Rails.logger.error("All models failed. Attempts: #{attempts.map { |a| a[:model] }.join(', ')}")
  end
end
```

---

## How to Use with RubyLLM

By default ActiveHarness uses its own Net::HTTP providers. To delegate HTTP calls to the `ruby_llm` gem instead, define a `custom_llm_backend` block. Everything else — fallback chain, retry policy, hooks, streaming — works unchanged.

```ruby
class GreetingAgent < ActiveHarness::Agent
  system_prompt GreetingPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo", temperature: 0.7
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  # The block receives BackendParams with fields: model, provider, temperature.
  # Must return a RubyLLM::Chat instance.
  custom_llm_backend do |params|
    RubyLLM.chat(
      model:               params.model,
      provider:            params.provider,
      assume_model_exists: true
    ).tap do |chat|
      chat.with_temperature(params.temperature) if params.temperature
    end
  end
end
```

> Requires `gem "ruby_llm"` in your Gemfile. ActiveHarness maps RubyLLM errors to its own error classes so the fallback chain and rescue blocks work the same way.

---

## JSON Output and Parsing

Define a prompt that instructs the model to return JSON, and add `format :json` to the agent:

```ruby
class SentimentPrompt
  def call
    <<~PROMPT
      Analyze the sentiment of the user's message.
      Return only valid JSON, no prose, no code fences:
      RESPONSE FORMAT:
      {
        "sentiment": "positive"|"negative"|"neutral",
        "score": 0.0..1.0
      }
    PROMPT
  end
end
```

```ruby
class SentimentAgent < ActiveHarness::Agent
  system_prompt SentimentPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

```ruby
agent = SentimentAgent.new
agent.input = "I love this product!"
agent.call

result = agent.result

result.output     # => '{"sentiment":"positive","score":0.92}'  — raw string, always present
result.processed  # => {"sentiment"=>"positive","score"=>0.92}  — parsed Ruby Hash
```

`format :json` is required explicitly because ActiveHarness cannot infer your intent from the prompt alone — the model might return JSON as part of a text answer. Setting the flag also enables automatic stripping of markdown code fences (` ```json ... ``` `) that some models add despite being instructed not to, and activates the `:before_parse` / `:after_parse` / `:parse_error` hooks.

Without `format :json`, `result.processed` equals `result.output` — the raw string.

---

## Lifecycle Events

| Event                      | Alias                   | Arguments      | When it fires                                |
| -------------------------- | ----------------------- | -------------- | -------------------------------------------- |
| `on :setup`                | `callback :setup`       | —              | Once, inside `initialize`                    |
| `on :before_call`          | `before :call`          | —              | Before the first model attempt               |
| `on :after_call`           | `after :call`           | `result`       | After a successful model response            |
| `on :before_system_prompt` | `before :system_prompt` | —              | Before the system prompt is resolved         |
| `on :after_system_prompt`  | `after :system_prompt`  | `prompt`       | After the system prompt string is ready      |
| `on :before_parse`         | `before :parse`         | `raw`          | Before output parsing (`format :json` only)  |
| `on :after_parse`          | `after :parse`          | `parsed`       | After successful parse (`format :json` only) |
| `on :parse_error`          | `callback :parse_error` | `raw, error`   | When JSON parse fails                        |
| `on :retry`                | `callback :retry`       | `entry, error` | After each failed model attempt              |
| `on :failure`              | `callback :failure`     | `attempts`     | When the entire fallback chain is exhausted  |

To share hooks across agents, extract them into a module and use `self.included`:

```ruby
module AgentLogging
  def self.included(base)
    base.on(:setup) do
      Rails.logger.debug("[#{self.class.name}] initialized")
    end

    base.before(:call) do
      Rails.logger.info("[#{self.class.name}] ▶ calling with input: #{@input.to_s[0, 80]}")
    end

    base.before(:system_prompt) do
      Rails.logger.debug("[#{self.class.name}] resolving system prompt")
    end

    base.after(:system_prompt) do |prompt|
      Rails.logger.debug("[#{self.class.name}] prompt ready (#{prompt.to_s.length} chars)")
    end

    base.before(:parse) do |raw|
      Rails.logger.debug("[#{self.class.name}] parsing output (#{raw.to_s.length} chars)")
    end

    base.after(:parse) do |parsed|
      Rails.logger.debug("[#{self.class.name}] parsed: #{parsed.inspect[0, 120]}")
    end

    base.on(:parse_error) do |_raw, error|
      Rails.logger.error("[#{self.class.name}] parse failed — #{error.message}")
    end

    base.after(:call) do |result|
      Rails.logger.info("[#{self.class.name}] ✓ #{result.model} (#{result.execution_time}s, #{result.usage&.dig(:total_tokens)} tokens)")
    end
  end
end
```

Include the concern into an agent. Use `format :json` so the parse hooks actually fire:

```ruby
class SentimentAgent < ActiveHarness::Agent
  include AgentLogging

  system_prompt SentimentPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

---

## Custom Providers

Any OpenAI-compatible endpoint can be registered under an arbitrary name and used alongside built-in providers.

Register in `config/initializers/active_harness.rb`:

```ruby
ActiveHarness.configure do |config|
  config.custom["MyLocal"]["url"]     = "http://localhost:11434/v1/chat/completions"
  config.custom["MyLocal"]["api_key"] = ENV["MYLOCAL_API_KEY"]  # omit if no auth required

  config.custom["PrivateGPU"]["url"]     = "https://gpu.internal/v1/chat/completions"
  config.custom["PrivateGPU"]["api_key"] = ENV["PRIVATEGPU_API_KEY"]
end
```

Use in an agent with `provider: :custom` and `name:` matching the registered key:

```ruby
class GreetingAgent < ActiveHarness::Agent
  system_prompt GreetingPrompt

  model do
    use      provider: :custom, name: "MyLocal",    model: "llama3.2"
    fallback provider: :custom, name: "PrivateGPU", model: "mixtral-8x7b"
    fallback provider: :openrouter,                 model: "mistralai/mistral-nemo"
  end
end
```

> `name:` is mandatory for `provider: :custom` — it identifies which endpoint to load from `config.custom`. Omitting it raises `InvalidRequestError` at call time.

---

## Streaming in the Console

Pass a lambda to `streams: { token: }` to receive each token as it arrives. The full output is still available in `result.output` after the stream ends.

Instance API:

```ruby
agent = GreetingAgent.new

print "AI: "
agent.call("Tell me about the water cycle.", streams: { token: ->(token) { print token; $stdout.flush } })
puts

puts agent.result.execution_time
```

Class API:

```ruby
print "AI: "
agent = GreetingAgent.call(
  input:   "Tell me about the water cycle.",
  streams: { token: ->(token) { print token; $stdout.flush } }
)
puts

puts agent.result.output.length
```

> `$stdout.flush` is required in the console — without it tokens are buffered and appear all at once at the end.

---

## Streaming in a Rails App

Use `ActionController::Live` and SSE to push tokens to the browser in real time.

```ruby
class AiController < ApplicationController
  # Required — enables response.stream and keeps the connection open
  include ActionController::Live

  def agent_stream
    prepare_sse_response

    # All frames on this connection carry event: "message"
    sse = ActionController::Live::SSE.new(response.stream, event: "message")

    SupportAgent.call(
      input:   params.require(:input),
      # Each token is pushed to the browser immediately as it arrives
      streams: { token: ->(token) { sse.write({ token: token }.to_json) } }
    )

    # Signal the client that the stream is complete
    sse.write({ done: true }.to_json)
  rescue ActionController::Live::ClientDisconnected
    # Browser closed the tab or navigated away — nothing to do
  rescue StandardError => e
    sse.write({ error: e.message }.to_json) rescue nil
    sse.write({ done: true }.to_json)       rescue nil
  ensure
    # Must always close — otherwise the thread and connection leak
    sse.close
  end

  private

  def prepare_sse_response
    # ActionDispatch::ServerTiming crashes with Live on Rails 8
    request.env["action_dispatch.server_timing_events"] ||= []
    # Tell the browser this is a streaming SSE response
    response.headers["Content-Type"]      = "text/event-stream"
    # Every request must reach the server — no caching
    response.headers["Cache-Control"]     = "no-cache"
    # Disable nginx / proxy buffering so tokens arrive immediately
    response.headers["X-Accel-Buffering"] = "no"
  end
end
```

Client-side JavaScript:

```javascript
const source = new EventSource("/ai/agent_stream?input=" + encodeURIComponent(input));

source.addEventListener("message", (e) => {
  const data = JSON.parse(e.data);
  
  if (data.token) output.textContent += data.token;  // append token to the output element
  if (data.done)  source.close();                    // graceful close after last token
  if (data.error) console.error(data.error);
});
```
