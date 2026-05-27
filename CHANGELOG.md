# Changelog

## v0.2.21 — 2026-05-27

- **`pipeline/hooks.rb`** — hooks DSL extracted from `pipeline.rb` into a dedicated file, consistent with `agent/hooks.rb` and `tribunal/hooks.rb`
  - `VALID_HOOKS`, `VALID_STEP_HOOKS` constants moved to `pipeline/hooks.rb`
  - Class-level DSL (`on`, `before`, `after`, `callback`) moved to `pipeline/hooks.rb`
  - Private instance methods `fire` and `fire_step` moved to `pipeline/hooks.rb`
  - `pipeline.rb` now `require_relative`s `pipeline/hooks` alongside `pipeline/step`

---

## v0.2.20 — 2026-05-27

- **`streams:` hash API** — `Agent`, `Tribunal`, and `Pipeline` now accept a single `streams: {}` hash instead of discrete keyword arguments; keys: `:token` (token stream lambda), `:agent` (agent lifecycle events), `:tribunal` (tribunal lifecycle events), `:pipeline` (pipeline lifecycle events)
  - `Agent.new(streams: { token: ->(t){...}, agent: ->(ev,*a){...} })`
  - `Tribunal.new(streams: { token:, agent:, tribunal: })`
  - `Pipeline.new(streams: { token:, agent:, tribunal:, pipeline: })`
  - All three cascade streams automatically to inner agents/tribunals; no manual wiring needed
  - Old params `stream:`, `token_stream:`, `event_stream:`, `agent_event_stream:`, `tribunal_event_stream:`, `pipeline_event_stream:` removed
- **`Agent#fire`** — new unified internal method replacing `run_hook`; fires the DSL hook **and** the `@event_stream` lambda in one call; rescues `IOError` / `ActionController::Live::ClientDisconnected`
- **`Pipeline#fire`** — replaces `fire_global`; fires the DSL hook **and** `@pipeline_event_stream`; `:stopped` and `:complete` hooks also forward to `@pipeline_event_stream` directly
- **`attr_reader` for stream attrs** — `token_stream`, `event_stream` (Agent), `token_stream`, `agent_event_stream`, `tribunal_event_stream` (Tribunal) are now read-only from outside; `stream` attr removed

---

## v0.2.19 — 2026-05-27

- **`VERSION` auto-sync** — `make up` / `make up/minor` / `make up/major` now automatically update `VERSION` in `lib/active_harness.rb` to match the gemspec; new `sync-version` Make target handles this step

---

## v0.2.18 — 2026-05-27

- **`custom_llm_backend`** — renamed from `ruby_llm_backend`; the DSL now makes it clear that any LLM client can be plugged in, not just `ruby_llm`
- File `agent/ruby_llm_backend.rb` → `agent/custom_llm_backend.rb`; internal methods `attempt_via_ruby_llm` / `ruby_llm_usage` renamed accordingly
- Docs updated: `ruby_llm_integration.md`, `activeharness_and_rubyllm.md`, `providers.md`

---

## v0.2.17 — 2026-05-25

- **Pipeline stream propagation** — `Pipeline.new` / `Pipeline.call` now accept `stream:`, `agent_event_stream:`, `tribunal_event_stream:`, `pipeline_event_stream:`; all four are forwarded automatically to every agent and tribunal step
- **Pipeline hooks via `instance_exec`** — `:stopped`, `:complete`, per-step and global hooks are now called with `instance_exec` so hook blocks can reference pipeline instance variables (`@payload`, `@context`, `@step_results`, …)
- **Tribunal `fire` method** — `run_hook` replaced by `fire` in the call loop; `fire` invokes the DSL hook **and** the external `tribunal_event_stream` lambda in one place; `IOError` / `ActionController::Live::ClientDisconnected` are silently rescued to survive SSE disconnects
- Docs: `docs/pipelines/pipeline_hooks.md`

---

## v0.2.16 — 2026-05-25

- **`normalize_input`** — automatic strip + whitespace collapse on `@input` before every call; enabled by default, disable with `normalize_input false`
- Docs: `docs/agents/normalize_input.md`

---

## v0.2.15 — 2026-05-25

- **Verdict strategies** — `verdict :unanimous` / `verdict :majority, may_fail: N` DSL
- **`tribunal/dsl.rb`** — `agents`, `verdict`, `process` moved to dedicated module
- **`tribunal/processing.rb`** — `compute_verdict`, `apply_strategy`, `check_failure_threshold!` extracted as named private methods
- **`may_fail: N`** — tolerate up to N agent errors before raising `AllAgentsFailed`
- Docs: `docs/tribunals/tribunal_verdict_strategies.md`

---

## v0.2.14 — 2026-05-25

- **Tribunal stream separation** — `stream:` (passed to agents), `agent_event_stream:` (agents' lifecycle), `tribunal_event_stream:` (tribunal's own lifecycle)
- **Tribunal refactor** — `tribunal/hooks.rb`: hooks DSL (`on`, `before`, `after`, `callback`) extracted from main class
- `before_agent` / `after_agent` / `agent_error` hooks now receive agent index as extra argument
- `resolve_agents` propagates `stream:` and `event_stream:` to each instantiated agent
- Docs: `docs/tribunals/tribunal_streaming.md`, `docs/tribunals/tribunal_errors_processing.md`

---

## v0.2.13 — 2026-05-25

- **`result.cost`** — `{ input_cost:, output_cost:, total_cost: }` in USD per request
- **`agent/cost.rb`** — `calculate_cost` private method; `nil` when model or usage is missing
- **`Costs.load_registry`** — robust loading: falls back to bundled `data/models.json` when cache is absent or corrupted (`JSON::ParserError`)

---

## v0.2.12 — 2026-05-25

- **`ActiveHarness::Costs`** module — pricing registry for 100+ models
- **`data/models.json`** — bundled pricing data (`input_per_million` / `output_per_million` in USD)
- Docs: `docs/agents/costs.md`

---

## v0.2.11 — 2026-05-24

- **Streaming refactor** — unified `StreamingClient`, all providers share base streaming logic
- Anthropic streaming overhauled, token delta handling normalised across providers
- All providers (OpenAI, Groq, Mistral, Gemini, DeepSeek, Ollama, GPUStack, Perplexity, xAI) use shared base streaming

---

## v0.2.9 — 2026-05-24

- **Streaming token usage** — usage stats available after SSE stream finishes
- Streaming client extracted to `lib/active_harness/http/streaming_client.rb`

---

## v0.2.8 — 2026-05-22

- **`ActiveHarness.configure` block** — global defaults for model, temperature, timeout, retry
- **Retry policy** — exponential back-off with `max_attempts` / `base_delay`; `RETRYABLE_ERRORS` / `STOP_ERRORS` split
- **Custom LLM backend** — `ActiveHarness::Agent::CustomLLMBackend`, plug in any LLM client as the HTTP layer
- **New providers** — Azure OpenAI, AWS Bedrock, Vertex AI, DeepSeek, Mistral, Ollama, GPUStack, Perplexity, xAI
- **Custom provider** — `providers/custom.rb`, bring your own HTTP adapter
- **Rails configuration** — `ActiveHarness::Railtie`, `config/initializers/active_harness.rb`
- Docs: `rails_configuration.md`, `ruby_configuration.md`, `ruby_llm_integration.md`

---

## v0.2.7 — 2026-05-21

- **Token streaming** — `token_stream:` lambda passed to agent / `Agent.call`; live token callbacks
- **Pipeline event hooks** — `before_call`, `after_step`, `after_call`
- **Tribunal event hooks** — `before_call`, `before_agent`, `after_agent`, `agent_error`, `after_call`, `before_verdict`, `after_verdict`
- **`event_stream:`** — lifecycle event lambda for agents (separate from token stream)
- Railtie: auto-loads agents, pipelines, tribunals in Rails apps

---

## v0.2.3 — 2026-05-21

- **Rails generators** — `rails g active_harness:install`, `rails g active_harness:agent NAME`
- **Memory generator** — `rails g active_harness:memory NAME`
- **Pipeline generator** — `rails g active_harness:pipeline NAME`
- Install generator scaffolds full directory structure: agents, pipelines, tribunals, prompts, memory, controller

---

## v0.2.0 — 2026-05-20 (initial release)

- **`ActiveHarness::Agent`** — class-level DSL: `system_prompt`, `model`, `format`, `on` hooks
- **`ActiveHarness::Pipeline`** — sequential agent steps, `before_call` / `after_step` hooks
- **`ActiveHarness::Tribunal`** — parallel agent execution, verdict via `process` block
- **`ActiveHarness::Memory`** — conversation memory with `load` / `record` / `recall`
- **`ActiveHarness::Result`** — `output`, `parsed`, `usage`, `execution_time`, `model`, `attempts`
- Providers: OpenAI, Anthropic, Gemini, Groq, OpenRouter
- Output formats: `:json`, `:text`
- Model fallback chain — try models in order until one succeeds
- Docs: `agent_hooks.md`, `pipeline_hooks.md`, `tribunal_hooks.md`
