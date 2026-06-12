# Event Tracing and Observability

## How It Works

Every agent, tribunal, and pipeline exposes lifecycle hooks. You attach handlers to those hooks — either to log to `Rails.logger`, or to create OpenTelemetry spans that appear in Jaeger, Datadog, Honeycomb, or any OTLP-compatible backend.

The pattern is always the same:

```
lifecycle hook → record an event or close a span
```

No monkey-patching, no auto-instrumentation. You control exactly what is recorded and when.

---

## Simple Logging with Hooks

No dependencies needed. Use lifecycle hooks directly with `Rails.logger`:

```ruby
class SupportAgent < ActiveHarness::Agent
  system_prompt SupportPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  before(:call) do
    Rails.logger.info "[#{self.class.name}] calling..."
  end

  after(:call) do |result|
    Rails.logger.info "[#{self.class.name}] done " \
                      "model=#{result.model.name} " \
                      "time=#{result.execution_time}s " \
                      "tokens=#{result.usage&.tokens&.total}"
  end

  callback(:retry) do |entry, error|
    Rails.logger.warn "[#{self.class.name}] retry model=#{entry&.dig(:model)} error=#{error&.message}"
  end

  callback(:failure) do
    Rails.logger.error "[#{self.class.name}] all models failed"
  end
end
```

Move these hooks into a concern to reuse across agents:

```ruby
# app/ai/concerns/agent_logging.rb
module AgentLogging
  def self.included(base)
    base.before(:call) do
      Rails.logger.info "[#{self.class.name}] calling..."
    end

    base.after(:call) do |result|
      Rails.logger.info "[#{self.class.name}] done " \
                        "model=#{result.model.name} " \
                        "time=#{result.execution_time}s"
    end

    base.callback(:retry) do |entry, error|
      Rails.logger.warn "[#{self.class.name}] retry " \
                        "model=#{entry&.dig(:model)} error=#{error&.message}"
    end

    base.callback(:failure) do
      Rails.logger.error "[#{self.class.name}] all models failed"
    end
  end
end
```

```ruby
class SupportAgent < ActiveHarness::Agent
  include AgentLogging

  system_prompt SupportPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

---

## OpenTelemetry Setup

### Gems

```ruby
# Gemfile
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
```

### Initializer

Define the SDK configuration and an `AiTracer` helper in one initializer:

```ruby
# config/initializers/opentelemetry.rb
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "my_app")

  exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
    # /v1/traces is required when passing the endpoint directly
    endpoint: ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", "http://jaeger:4318/v1/traces")
  )

  # SimpleSpanProcessor sends each span immediately — good for development.
  # Use BatchSpanProcessor in production.
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
  )
end

module AiTracer
  def self.tracer
    @tracer ||= OpenTelemetry.tracer_provider.tracer("active_harness")
  end

  # Start a span, optionally nested inside parent_ctx.
  def self.start_span(name, attributes: {}, parent_ctx: nil)
    ctx  = parent_ctx || OpenTelemetry::Context.current
    span = tracer.start_span(name, with_parent: ctx, attributes: attributes.transform_values(&:to_s))
    SpanWrapper.new(span)
  end

  # Convert a span into a Context so it can be passed as parent_ctx: to child spans.
  def self.span_context(span)
    span = span.unwrap if span.is_a?(SpanWrapper)
    OpenTelemetry::Trace.context_with_span(span)
  end

  class SpanWrapper
    def initialize(span)
      @span = span
    end

    def unwrap = @span

    # Set span attributes (chainable)
    def attrs(hash)
      hash.each { |k, v| @span.set_attribute(k, v.to_s) }
      self
    end

    # Add a named event with nested attribute hashes (flattened to dot notation)
    def event(name, **attrs)
      @span.add_event(name, attributes: flatten(attrs))
      self
    end

    def finish
      @span.finish
      self
    end

    def method_missing(method, *args, **kwargs)
      @span.respond_to?(method) ? @span.public_send(method, *args, **kwargs) : super
    end

    def respond_to_missing?(method, include_private = false)
      @span.respond_to?(method) || super
    end

    private

    def flatten(hash, prefix = nil)
      hash.each_with_object({}) do |(key, value), result|
        full_key = prefix ? "#{prefix}.#{key}" : key.to_s
        if value.is_a?(Hash)
          result.merge!(flatten(value, full_key))
        else
          result[full_key] = value.to_s
        end
      end
    end
  end
end
```

`AiTracer` is a thin wrapper that adds:
- `SpanWrapper` — a fluent API for setting attributes and events
- Automatic flattening of nested hashes to dot-notation: `{ llm: { model: "gpt-4" } }` → `"llm.model" => "gpt-4"`

---

## AgentTracing Concern

Wraps every agent call in a span. Fires events for each lifecycle step, records model, execution time, and tokens on close.

```ruby
# app/ai/concerns/agent_tracing.rb
module AgentTracing
  def self.included(base)
    base.before(:call) do
      @tracer_span = AiTracer.start_span(
        tracing_span_name,
        attributes: { "agent.class" => self.class.name },
        parent_ctx:  @params[:tracer_ctx]
      )
      @tracer_span.event("before_call")
    end

    base.after(:call) do |result|
      if @tracer_span
        @tracer_span
          .event("after_call",
            llm: { model: result.model.name, time_s: result.execution_time, tokens: result.usage&.tokens&.total }
          )
          .attrs({
            "llm.model"  => result.model.name,
            "llm.time_s" => result.execution_time,
            "llm.tokens" => result.usage&.tokens&.total
          })
          .attrs(tracing_extra_params(result))
          .finish
        @tracer_span = nil
      end
    end

    base.before(:system_prompt) do
      @tracer_span&.event("before_system_prompt")
    end

    base.after(:system_prompt) do |prompt|
      @tracer_span&.event("after_system_prompt", prompt: { chars: prompt.to_s.length })
    end

    base.callback(:parse_error) do |_raw, error|
      @tracer_span&.event("parse_error",
        error: { class: error.class.name, message: error.message.to_s[0, 200] }
      )
    end

    base.callback(:retry) do |entry, error|
      @tracer_span&.event("retry", model: entry&.dig(:model), error: error&.message)
    end

    base.callback(:failure) do |_attempts|
      if @tracer_span
        @tracer_span.status = OpenTelemetry::Trace::Status.error("all_models_failed")
        @tracer_span.finish
        @tracer_span = nil
      end
    end
  end

  # Override to add domain-specific attributes to the span before it closes.
  def tracing_extra_params(_result) = {}

  # Override to change the span name in the trace UI.
  def tracing_span_name = self.class.name
end
```

### Usage

```ruby
class InjectionGuardAgent < ActiveHarness::Agent
  include AgentTracing

  system_prompt InjectionGuardPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # Add domain-specific data to the span — visible in Jaeger alongside model/tokens/time
  def tracing_extra_params(result)
    { "guard.detected" => result.processed&.dig("detected").to_s }
  end
end
```

---

## TribunalTracing Concern

Wraps the tribunal in a span and propagates it as the parent context to all agent spans running inside — so the trace shows the full parent → child hierarchy.

```ruby
# app/ai/concerns/tribunal_tracing.rb
module TribunalTracing
  def self.included(base)
    base.on(:before_call) do
      @tracer_span = AiTracer.start_span(
        tracing_span_name,
        attributes: { "tribunal.class" => self.class.name },
        parent_ctx:  @params[:tracer_ctx]
      )
      # Propagate tribunal span so all child agents become its children in the trace
      @params[:tracer_ctx] = AiTracer.span_context(@tracer_span)
    end

    base.on(:after_agent) do |result, index|
      @tracer_span&.event("agent_done",
        agent: { index: index },
        llm:   { model: result.model.name, time_s: result.execution_time }
      )
    end

    base.on(:agent_error) do |name, error, _index|
      @tracer_span&.event("agent_error", agent: { class: name }, error: error&.message)
    end

    base.on(:after_verdict) do |verdict|
      if @tracer_span
        @tracer_span
          .attrs({ "tribunal.verdict" => verdict.to_s, "tribunal.time_s" => execution_time.to_s })
          .finish
        @tracer_span = nil
      end
    end
  end

  def tracing_span_name = self.class.name
end
```

### Usage

```ruby
class SafetyTribunal < ActiveHarness::Tribunal
  include TribunalTracing

  agents ToxicityAgent, AggressionAgent
end
```

---

## PipelineTracing Concern

Creates a root pipeline span and a child span for each step. The step span is passed down to agents and tribunals as `@params[:tracer_ctx]`, so the full tree is visible in one trace.

```ruby
# app/ai/concerns/pipeline_tracing.rb
module PipelineTracing
  def self.included(base)
    base.before(:step) do |step_name, _payload|
      @tracer_spans ||= {}

      unless @tracer_span_pipeline
        @tracer_span_pipeline = AiTracer.start_span(tracing_span_name, attributes: {
          "pipeline.class" => self.class.name
        })
        @tracer_ctx_pipeline = AiTracer.span_context(@tracer_span_pipeline)
      end

      step_span = AiTracer.start_span(step_name.to_s, attributes: {
        "pipeline.class" => self.class.name,
        "step.name"      => step_name.to_s
      }, parent_ctx: @tracer_ctx_pipeline)

      @tracer_spans[step_name]  = step_span
      @params[:tracer_ctx]      = AiTracer.span_context(step_span)
    end

    base.after(:step) do |step_name, result|
      if (span = @tracer_spans&.delete(step_name))
        attrs = {}
        attrs["llm.time_s"] = result.execution_time if result.respond_to?(:execution_time)
        attrs["llm.model"]  = result.model.name          if result.respond_to?(:model)
        span.attrs(attrs).finish
      end
    end

    base.callback(:stopped) do |step_name, _result|
      @tracer_spans&.delete(step_name)&.attrs({ "pipeline.stopped" => true })&.finish
      if @tracer_span_pipeline
        @tracer_span_pipeline.attrs({ "pipeline.stopped_at" => step_name.to_s }).finish
        @tracer_span_pipeline = nil
      end
    end

    base.callback(:complete) do |_last_result|
      if @tracer_span_pipeline
        @tracer_span_pipeline.attrs({ "pipeline.time_s" => execution_time }).finish
        @tracer_span_pipeline = nil
      end
    end
  end

  def tracing_span_name = self.class.name
end
```

### Usage

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  include PipelineTracing

  step :injection_guard do
    use InjectionGuardAgent
    stop_if ->(result) { result.processed["detected"] == true }
  end

  step :safety_check do
    use SafetyTribunal
    stop_if ->(result) { result.verdict == false }
  end

  step :respond, SupportAgent
end
```

---

## Span Hierarchy

When all three concerns are used together, every call produces a nested trace:

```
SupportPipeline
├── injection_guard
│   └── InjectionGuardAgent
│       ├── event: before_call
│       ├── event: after_system_prompt  (prompt.chars)
│       └── event: after_call           (llm.model, llm.time_s, llm.tokens, guard.detected)
├── safety_check
│   └── SafetyTribunal
│       ├── ToxicityAgent               (child of tribunal span)
│       │   └── event: after_call
│       ├── AggressionAgent             (child of tribunal span)
│       │   └── event: after_call
│       └── event: after_verdict        (tribunal.verdict, tribunal.time_s)
└── respond
    └── SupportAgent
        └── event: after_call
```

The tree is visible as a single trace in Jaeger or any OTLP backend.

---

## Connecting to a Backend

All backends are configured via the `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable:

| Backend    | Endpoint                                  |
| ---------- | ----------------------------------------- |
| Jaeger     | `http://jaeger:4318/v1/traces`            |
| Datadog    | `http://localhost:4318/v1/traces`         |
| Honeycomb  | `https://api.honeycomb.io/v1/traces`      |
| Custom     | any OTLP HTTP endpoint                    |

For Honeycomb, also set:

```
OTEL_EXPORTER_OTLP_HEADERS=x-honeycomb-team=YOUR_API_KEY
```

Switch from `SimpleSpanProcessor` (development) to `BatchSpanProcessor` (production) in the initializer:

```ruby
c.add_span_processor(
  OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
)
```
