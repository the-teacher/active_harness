# Pipeline

A pipeline chains multiple agents and tribunals into a sequential workflow.
Each step receives the current payload, can transform it, and can stop the pipeline early.

## Basic usage

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  step :translate, TranslationAgent

  step :injection_guard do
    use InjectionGuardAgent
    stop_if ->(result) { result.processed["detected"] == true }
  end

  step :safety_tribunal do
    use SafetyTribunal
    stop_if ->(result) { result.verdict == false }
  end
end

pipeline = SupportPipeline.new(input: "Hello", context: { user_id: 1 })
pipeline.call

pipeline.output       # => final payload string (nil if stopped)
pipeline.stopped?     # => false
pipeline.step_results # => { translate: <Result>, injection_guard: <Result>, ... }
```

## Step types

There are two kinds of classes a step can use.

**Agent step** — runs the agent, takes `result.output` as the new payload:

```ruby
step :translate, TranslationAgent
```

**Tribunal step** — runs the tribunal, returns a `Result` with `processed["verdict"]`.
Payload is never updated by a tribunal step (it always has `stop_if`):

```ruby
step :safety_tribunal do
  use SafetyTribunal
  stop_if ->(result) { result.processed["verdict"] == false }
end
```

## Payload propagation

The payload starts as the value passed to `input:` and flows through the steps:

| Condition | Payload after step |
|-----------|--------------------|
| Agent step, no `stop_if` | Updated to `result.output` |
| Agent step with `stop_if` | Unchanged (guard step) |
| Tribunal step | Unchanged |

After each step the result is also stored in `context[step_name]`,
so later steps can read earlier results via `@context[:translate]` etc.

## Stopping the pipeline

Any step can stop the pipeline by defining `stop_if`:

```ruby
step :injection_guard do
  use InjectionGuardAgent
  stop_if ->(result) { result.processed["detected"] == true }
end
```

When the condition is true:
- remaining steps are skipped
- `pipeline.stopped?` returns `true`
- `pipeline.stopped_at` holds the step name
- `pipeline.output` is `nil`

## Events and hooks

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  on_agent_event    do |event, result|  ... end  # fires for every agent inside
  on_tribunal_event do |event, verdict| ... end  # fires for every tribunal inside
  on_pipeline_event do |event, *args|   ... end  # :before_step, :after_step, :stopped, :complete
end
```

Runtime streams can be passed at construction time:

```ruby
SupportPipeline.new(
  input:   "...",
  streams: { token: token_lambda, agent: agent_lambda }
)
```

## Memory

A memory object can be attached to the pipeline. It is loaded before the first step
and a record is written after successful completion (skipped if the pipeline stops early):

```ruby
mem = ActiveHarness::Memory::JsonFile.new(file_name: "session_42")

SupportPipeline.new(input: "...", memory: mem).call
```

---

## Proposal: universal step interface

Currently `Pipeline::Step` special-cases two concrete classes: `Agent` and `Tribunal`.
This section explores making the pipeline open to any entity — a plain Ruby object,
a lambda, a nested pipeline, an HTTP call, a cache lookup — with no inheritance required.

The core question is: **what must a step return so the pipeline can drive it?**

---

### Option A — Duck-type protocol (minimal change)

Define a lightweight protocol. Any object that satisfies it can be a step:

```ruby
# Contract: class responds to .new(input:, context:, params:, streams:)
# Instance responds to .call → returns an object with:
#   .output  — new payload (String or any value); nil keeps payload unchanged
#   .stop?   — true signals the pipeline to halt (replaces stop_if in step DSL)

class UppercaseStep
  def initialize(input:, **); @input = input; end

  def call
    Pipeline::StepResult.new(output: @input.upcase)
  end
end

step :upcase, UppercaseStep
```

`Pipeline::StepResult` would be a tiny value object:

```ruby
Pipeline::StepResult = Struct.new(:output, :stop, keyword_init: true) do
  def stop? = stop
end
```

**Pros:** almost no change to existing code; agents and tribunals get thin adapters.  
**Cons:** every custom step must construct `StepResult`; slightly more boilerplate.

---

### Option B — Callable (lambda / proc) as a step

Allow any `Proc`/`lambda` directly, without a wrapper class:

```ruby
step :sanitize, ->(payload, ctx) { payload.strip }

step :length_guard, ->(payload, ctx) {
  payload.length > 1000 ? Pipeline::Stop : payload
}
```

Return value rules:
- any value other than `Pipeline::Stop` → becomes new payload
- `Pipeline::Stop` (or `Pipeline::Stop.new(reason)`) → halts the pipeline

**Pros:** perfect for simple transformations and guards; zero boilerplate.  
**Cons:** no access to `params:` or `streams:` without enlarging the lambda signature;
harder to test in isolation.

---

### Option C — Rack-style env hash

Each step receives and returns a single hash (`env`), similar to Rack middleware:

```ruby
# env keys: :input, :output, :context, :params, :streams
# Return env to continue, return Pipeline::Stop to halt.

class UppercaseStep
  def call(env)
    env.merge(output: env[:input].upcase)
  end
end

class LengthGuard
  def call(env)
    env[:input].length > 1000 ? Pipeline::Stop.new("too long") : env
  end
end
```

Steps become stateless (no `initialize`) — a single instance can be reused:

```ruby
UPCASE = UppercaseStep.new

step :upcase,       UPCASE
step :length_guard, LengthGuard.new
```

**Pros:** stateless, composable, easy to test (`call(env)` in one line); nested
pipelines become trivial — a pipeline is just another object with `call(env)`.  
**Cons:** largest departure from the current API; requires migrating Agent/Tribunal wrappers.

---

### Option D — `Pipeline::Callable` module (explicit contract)

A module that documents the contract and provides `StepResult` helpers:

```ruby
class EnrichStep
  include ActiveHarness::Pipeline::Callable  # documents intent, no magic

  def initialize(input:, context:, **); @input = input; @context = context; end

  def call
    data = ExternalService.fetch(@context[:user_id])
    result(output: "#{@input} [enriched: #{data}]")  # helper from Callable
  end
end
```

Agents and Tribunals include `Callable` automatically, so they work as before.
Any plain class can opt in with one `include`.

**Pros:** clear opt-in contract; helpers reduce boilerplate; IDE-friendly.  
**Cons:** still requires `include`; doesn't help lambdas or nested pipelines directly.

---

### Comparison

| | No inheritance | Lambda support | Nested pipeline | Migration cost |
|---|---|---|---|---|
| **A — duck type** | yes | with wrapper | yes | low |
| **B — lambda** | yes | native | no | low |
| **C — Rack env** | yes | yes (`.call`) | yes (trivially) | high |
| **D — module** | yes (opt-in) | with wrapper | yes | low |

**Recommendation:** start with **B** (lambda steps) for simple cases and **A** (duck-type
protocol + `StepResult`) for structured steps — both require minimal changes to the
existing engine. Option C is the most powerful but is a bigger refactor; consider it
if nested pipelines or stateless reuse become a real need.
