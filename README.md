# ActiveHarness

<p align="center">
  <img src="docs/top-logo.png" alt="ActiveHarness" width="600">
</p>

[![Gem Version](https://badge.fury.io/rb/active_harness.svg)](https://rubygems.org/gems/active_harness)

> **⚠️ Work in progress.** The API is under active development and may change between versions without notice.

**ActiveHarness** is a Ruby framework for building production-grade LLM pipelines — with deep observability, consensus-based decisions, automatic fallbacks, and real-time cost and timing control. Made for Rails, works in plain Ruby too.

## Build AI-Based Pipelines!

Build multi-step, trackable, cost-effective, and reliable AI flows with a clean, Rails-native DSL.

<img width="1920" height="1080" src="https://github.com/user-attachments/assets/fc987934-1dfa-4898-8e6b-0f88f24648b7" alt="Pipeline Flow"/>

## Use Consensus-Based Decisions!

Use **Tribunals** to run multiple agents in parallel and make `Verdicts` based on their agreement — improving **reliability** and reducing **biases** and **hallucinations**.

<img width="1920" height="1080" alt="Tribunals" src="https://github.com/user-attachments/assets/1acc68b3-2d9f-4732-945b-4e99a32e853d" />

## Provide Event Tracing & Observability

Use power of event hooks to log and trace every step of your AI flows, from individual agent calls to multi-step pipelines and parallel tribunals.

| Event Tracing Architecture               | Grafana Dashboard                    |
| ---------------------------------------- | ------------------------------------ |
| ![Event Tracing](docs/event_tracing.png) | ![Grafana Metrics](docs/grafana.png) |

## Use Memory to make your agents stateful!

Store conversation history in JSON, SQLite and PostgreSQL. Inject memory into prompts to make agents that remember past interactions.

<img width="1920" height="1080" alt="Memory" src="https://github.com/user-attachments/assets/30ca27a5-5c7a-4123-ba7d-dbf6da0b077d" />

## Streaming (SSE)

| Rails App                         | Console                          |
| --------------------------------- | -------------------------------- |
| ![Streaming](docs/streaming2.gif) | ![Streaming](docs/streaming.gif) |

## Why ActiveHarness?

Running a single LLM call is easy. Running a _reliable, observable, cost-controlled AI system_ is not.

ActiveHarness gives you the scaffolding to build multi-step pipelines where every agent is under full control: its inputs are directed, its outputs are observed, its errors are retried, and its cost is tracked. You define the logic; ActiveHarness handles the infrastructure.

**What you get out of the box:**

| Capability                  | What it means                                                                                               |
| --------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **Multi-step Pipelines**    | Chain agents sequentially, with per-step stop conditions and context forwarding                             |
| **Tribunal Consensus**      | Run multiple agents in parallel and accept the result only if they agree (unanimous, majority, or custom)   |
| **Automatic Fallbacks**     | If a model fails, the next one in the chain takes over — zero extra code                                    |
| **Retry Policy**            | Exponential backoff per model, globally configurable or per-agent                                           |
| **Full Observability**      | Lifecycle hooks on every agent event: `before_call`, `after_call`, `retry`, `failure` — log, stream, or act |
| **Real-time Streaming**     | SSE-ready token streaming from any agent into your Rails response                                           |
| **Execution Time Tracking** | Per-agent and per-pipeline timing built in                                                                  |
| **Token & Cost Tracking**   | Know exactly what each call cost in tokens and dollars                                                      |
| **Rails-native DSL**        | Clean file structure, Railtie integration, generator support                                                |
| **Event Tracing**           | OpenTelemetry integration for distributed tracing of agents, tribunals, and pipelines                       |

## Event Tracing & Observability

ActiveHarness ships with production-ready distributed tracing to monitor AI execution flows across your application.

| Event Tracing Architecture               | Grafana Dashboard                    |
| ---------------------------------------- | ------------------------------------ |
| ![Event Tracing](docs/event_tracing.png) | ![Grafana Metrics](docs/grafana.png) |

**Backend Agnostic** — Built on OpenTelemetry, ready for any collector (Jaeger, Datadog, Honeycomb, or custom).

## What is a "Harness"?

A **harness** in software is scaffolding that keeps a component under control — directing its inputs, observing its outputs, and enforcing rules around it. **ActiveHarness** does exactly that for LLM agents.

### Table of Contents

**Core Concepts:**

- [Prompts](#prompts)
- [Agents](#agents)
- [Tribunals](#tribunals)
- [Pipelines](#pipelines)
- [Memory](#memory)
- [Streaming (SSE)](#streaming-sse)

**Using with Ruby on Rails:**

- [Ruby on Rails File Structure](#file-structure)
- [Using with Ruby on Rails](#using-with-ruby-on-rails)

**Other Topics:**

- [Providers](#providers)
- [Setup API Keys](#api-keys)
- [Configuration](#configuration)
- [Retry Policy](#retry-policy)
- [Execution Time](#execution-time)
- [Token Usage Info](#token-usage-info)
- [Cost Calculation](#cost-calculation)
- [RubyLLM Integration](#rubyllm-integration)
- [ActiveHarness and RubyLLM](#activeharness-and-rubyllm)

## File Structure

File structure for Ruby and Ruby on Rails applications:

```
app/
├── models/
├── controllers/
├── views/
└── ai/
    ├── prompts/      # system prompt classes
    ├── agents/       # agent classes
    ├── tribunals/    # parallel verdict panels
    ├── pipelines/    # multi-step pipelines
    └── memory/       # custom memory classes
```

# Components of the ActiveHarness ecosystem:

## Prompts

A **prompt** is a plain Ruby class with a `call` method that returns the system prompt string.

Before `call` is invoked, the agent automatically injects `@input`, `@context`, and `@config` —
so you can build dynamic prompts without any extra wiring.

```ruby
class SupportPrompt
  def call
    "You are a concise and friendly customer support assistant. " \
    "Answer briefly, in 2-3 sentences max." \
    + reply_in_language
  end

  private

  def reply_in_language
    return "" unless @context[:language]
    " (reply in #{@context[:language]})"
  end
end
```

## Agents

An **agent** is a single LLM call wrapped in a class. It declares a system prompt, a model chain with automatic fallbacks, and lifecycle hooks for observing or modifying every stage of the call.

→ [Agent hooks reference](docs/agents/agent_hooks.md)

```ruby
class SupportAgent < ActiveHarness::Agent
  system_prompt SupportPrompt

  # Models are tried in order.
  # If one fails, the next fallback is used automatically.
  model do
    use  provider: :openrouter,
         model: "mistralai/mistral-nemo",
         temperature: 0.5

    fallback provider: :openai,    model: "gpt-4o-mini"
    fallback provider: :anthropic, model: "claude-3-haiku-20240307",
             retry_attempts: 2, retry_delay: 0.5  # per-model retry override
    fallback provider: :groq,      model: "llama-3.1-8b-instant"
    fallback provider: :gemini,    model: "gemini-2.0-flash"
  end

  # Save tokens
  # Trim user input whitespace and normalize spaces before the call.
  callback :setup do
    @input = @input&.strip&.gsub(/\s+/, " ")
  end

  before :call do
    if @context[:language]
      suffix = " (reply in #{@context[:language]})"
      @input += suffix unless @input.end_with?(suffix)
    end
  end

  callback :retry do |entry, error|
    puts "[retry] #{entry[:model]} — #{error.message}"
  end

  callback :failure do |attempts|
    puts "[failure] all #{attempts.size} models failed"
  end
end
```

**Usage:**

```ruby
agent = SupportAgent.new
agent.input   = "What is your return policy?"
agent.context = { language: "English" }
agent.call

result = agent.result

puts result.output                     # => "Our return policy is..."
puts result.model                      # => "mistralai/mistral-nemo"
puts result.execution_time             # => 1.352  (seconds)

# If providers return token usage info, it's all here:
puts result.usage[:input_tokens]       # => 41
puts result.usage[:output_tokens]      # => 78
puts result.usage[:total_tokens]       # => 119
```

`call` returns `self`, so calls can be chained:

```ruby
result = SupportAgent.new.tap { |a| a.input = "Hi" }.call.result
```

## Tribunals

![AI Tribunal](docs/tribunals.png)

A **tribunal** runs several agents on the same input **in parallel** and produces a single consensus **VERDICT** (final decision).

This improves reliability — a single model can be wrong or biased, but two (or more) independent models rarely agree on the same mistake.

→ [Tribunal hooks reference](docs/tribunals/tribunal_hooks.md)

**Prompt** — each agent returns structured JSON:

```ruby
class PolitenessPrompt
  def call
    <<~PROMPT.strip
      You are a politeness evaluator.
      Analyze the message and decide whether it is polite.
      Reply ONLY with valid JSON, no markdown:
      {"result": true, "reason": "..."}
    PROMPT
  end
end
```

**Agent** — uses the prompt and parses JSON output automatically:

```ruby
class PolitenessAgent < ActiveHarness::Agent
  system_prompt PolitenessPrompt

  # Parse the raw string output into a JSON object
  # Parsed results are available on result.parsed
  format :json

  # default model chain with fallbacks
  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.1-8b-instruct"
  end
end
```

**Tribunal** — runs two instances of the agent on different models, verdict is `true` only if both agree:

```ruby
class PolitenessTribunal < ActiveHarness::Tribunal
  def initialize(input:)
    # Two independent agents with different models, running in parallel.
    agent_1 = PolitenessAgent.new
    agent_1.models.prepend([{ provider: :openai, model: "gpt-4o-mini" }])

    agent_2 = PolitenessAgent.new
    agent_2.models.prepend([{ provider: :anthropic, model: "claude-3-haiku-20240307" }])

    super(
      input: input,
      agents: [agent_1, agent_2]
    )
  end

  # Define how the tribunal makes a VERDICT based on all agents' results.
  process do |results|
    results.all? do |result|
      result.parsed["result"] == true
    end
  end
end
```

**Usage:**

```ruby
aggressive_message = "I hate this product! It is the worst thing I've ever bought!!!"

politeness_tribunal = PolitenessTribunal.new

politeness_tribunal.input = aggressive_message
politeness_tribunal.call

puts politeness_tribunal.verdict          # => false
puts politeness_tribunal.execution_time   # => 0.94  (both agents ran in parallel)

# Inspect each agent's reasoning:
politeness_tribunal.results.each do |result|
  puts result.model                        # => "gpt-4o-mini"
  puts result.parsed["result"]             # => false
  puts result.parsed["reason"]             # => "The message contains aggressive language..."
end
```

## Pipelines

A **pipeline** chains agents and tribunals into a sequential, multi-step flow. Each step receives the output of the previous step as its input. Any step can stop the pipeline early — the remaining steps are skipped.

→ [Pipeline hooks reference](docs/pipelines/pipeline_hooks.md)

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  # Step 1 — Guard: detect prompt injection before wasting tokens.
  # stop_if receives the result and halts the pipeline if true.
  step :injection_guard do
    use InjectionGuardAgent
    stop_if ->(result) { result.parsed["detected"] == true }
  end

  # Step 2 — Shorthand: no stop_if, always continues.
  step :translate, TranslationAgent

  # Step 3 — Tribunal as a step: parallel safety check.
  step :safety_tribunal do
    use PolitenessTribunal
    stop_if ->(result) { result.processed["verdict"] == false }
  end

  # Step 4 — Final answer on a clean, safe, on-topic request.
  step :respond, SupportAgent

  # ~~~ Global hooks — fire on every step ~~~

  before :step do |step_name, payload|
    puts "[pipeline] → :#{step_name}"
  end

  after :step do |step_name, result|
    puts "[pipeline] ✓ :#{step_name} (#{result.execution_time}s)"
  end

  # ~~~ Per-step hook — fires only for :injection_guard ~~~

  after :step, :injection_guard do |result|
    status = result.parsed["detected"] ? "INJECTION DETECTED" : "clean"
    puts "[injection_guard] #{status}: #{result.parsed["reason"]}"
  end

  # ~~~ Terminal hooks ~~~

  callback :stopped do |step_name, result|
    puts "[pipeline] STOPPED at :#{step_name}"
  end

  callback :complete do |last_result|
    puts "[pipeline] complete"
  end
end
```

**Call:**

```ruby
pipeline = SupportPipeline.new
pipeline.input = "What is your return policy?"
pipeline.call

if pipeline.stopped?
  puts pipeline.stopped_at    # => :injection_guard  (name of the step that stopped it)
else
  puts pipeline.output        # => "Our return policy is..."
end

puts pipeline.execution_time  # => 3.12  (total wall time for all steps)

# Individual step results:
pipeline.step_results.each do |step_name, result|
  puts "#{step_name}: #{result.execution_time}s"
end
```

## Memory

**Memory** records the conversation history (request + response turns) for an agent session.
Recording is automatic — you only need to pass a `memory:` object when constructing an agent.
**Injection is always manual** — you decide when and how past turns are included in the prompt.

**Custom memory class** — wrap `ActiveHarness::Memory` once with your application defaults:

```ruby
class AppMemory < ActiveHarness::Memory
  STORAGE_PATH = Rails.root.join("storage/ai/memory").freeze

  def initialize(session_id:)
    super(
      session_id:   session_id,
      depth:        10,          # how many turns to keep in memory
      adapter:      :file,
      path:         STORAGE_PATH,
      storage_size: 200,         # max chars per stored message
      pretty:       true
    )
  end
end
```

**Wire memory to an agent** — pass it at construction time:

```ruby
memory = AppMemory.new(session_id: "user_42")

agent = SupportAgent.new(
  context: { language: "English" },
  memory:  memory
)

agent.call("What is your return policy?")
agent.call("Does that apply to digital products too?")
agent.call("How long does a refund take?")

puts memory.size          # => 3  (one turn per call)
```

Before `call` is invoked, the agent automatically injects `@memory`, `@input`, and `@context` — so you can include conversation history without any extra wiring.

```ruby
class SupportPrompt
  def call
    "You are a concise and friendly customer support assistant." \
    + history_context
  end

  private

  def history_context
    return "" unless @memory&.size&.positive?

    history = @memory.to_messages
                     .map { |m| "#{m[:role]}: #{m[:content]}" }
                     .join("\n")

    "\n\nConversation so far:\n#{history}"
  end
end
```

## Streaming (SSE)

![Streaming](docs/streaming.gif)

To stream responses token by token, include `ActionController::Live` and pass a `stream:` lambda to the agent:

```ruby
class AiController < ApplicationController
  include ActionController::Live

  # GET /ai/stream?input=What+is+your+return+policy%3F
  def stream
    input = params.require(:input)

    response.headers["Content-Type"]      = "text/event-stream"
    response.headers["Cache-Control"]     = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"  # disable nginx buffering

    sse = ActionController::Live::SSE.new(response.stream, event: "message")

    SupportAgent.call(
      input:  input,
      stream: ->(token) { sse.write({ token: token }.to_json) }
    )

    sse.write({ done: true }.to_json)
  rescue ActionController::Live::ClientDisconnected
    # client closed the connection — nothing to do
  ensure
    sse.close
  end
end
```

**JavaScript client:**

```js
const es = new EventSource("/ai/stream?input=Hello");

es.onmessage = ({ data }) => {
  const { token, done } = JSON.parse(data);
  if (done) {
    es.close();
    return;
  }
  document.querySelector("#output").insertAdjacentText("beforeend", token);
};
```

Each SSE frame carries one token: `data: {"token":"Hello"}`. The final frame: `data: {"done":true}`.

For a complete step-by-step guide covering token streaming, lifecycle events sidebar, two SSE channels on one connection, and vanilla JS client — see the [Rails Streaming guide →](docs/rails/rails_streaming.md).

---

## Reference Documentation

## Providers

ActiveHarness has built-in support for OpenAI, Anthropic, Gemini, Groq, OpenRouter, xAI, DeepSeek, Mistral, Perplexity, Ollama, GPUStack, and Azure OpenAI — see the [full Providers reference →](docs/common/providers.md).

## API Keys

Each provider reads its key from an environment variable — see the [full API keys reference →](docs/common/api_keys.md).

## Configuration

Configure API keys, provider URLs, retry policy, and custom providers — see the [full Configuration reference →](docs/common/configuration.md).

## Retry Policy

ActiveHarness automatically retries a model on transient errors with exponential backoff, then moves to the next fallback — see the [full Retry Policy reference →](docs/agents/retry_policy.md).

## Using with Ruby on Rails

ActiveHarness ships with a Rails generator that creates the full `app/ai/` structure, example classes, a controller, and routes — see the [full Rails Integration guide →](docs/rails/rails_integration.md).

## Rails Streaming (SSE)

Step-by-step guide: token streaming, lifecycle events sidebar, two SSE channels on one connection, vanilla JS client — see the [Rails Streaming guide →](docs/rails/rails_streaming.md).

## Execution Time

Every object that makes an LLM call (`Agent`, `Tribunal`, `Pipeline`) exposes `#execution_time` in seconds — see the [full Execution Time reference →](docs/agents/execution_time.md).

## Token Usage Info

When a provider returns token counts, they are available on the `Result` object under `#usage` — see the [full Token Usage reference →](docs/agents/token_usage.md).

## Cost Calculation

ActiveHarness automatically calculates the monetary cost of every LLM call and attaches it to the `Result` object as `result.cost`:

Pricing data is bundled with the gem and refreshed automatically once per day from [models.dev](https://models.dev) — see the [full Cost Calculation reference →](docs/agents/costs.md).

## RubyLLM Integration

ActiveHarness can delegate HTTP calls to the `ruby_llm` gem instead of its built-in providers, giving you access to tools, vision, structured output, and audio while keeping the full ActiveHarness interface — see the [full RubyLLM Integration guide →](docs/common/ruby_llm_integration.md).

## ActiveHarness and RubyLLM

RubyLLM is a transport layer — a unified API for any LLM provider. ActiveHarness is an architectural framework for organizing complex AI flows. They live at different levels of the stack and work great together — see [ActiveHarness and RubyLLM →](docs/common/activeharness_and_rubyllm.md).

## License

MIT © [the-teacher](https://github.com/the-teacher)
