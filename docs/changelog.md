# Changelog

## Unreleased

- Verdict strategies: `verdict :unanimous` / `verdict :majority, may_fail: N` DSL
- Tribunal split into `tribunal/hooks.rb`, `tribunal/dsl.rb`, `tribunal/processing.rb`
- Tribunal `stream:`, `agent_event_stream:`, `tribunal_event_stream:` — separate streams for agents and tribunal lifecycle
- Agent `before_call` / `after_call` / `retry` hooks fire into `event_stream`
- `check_failure_threshold!` / `compute_verdict` extracted as named private methods

---

## v0.2.15 — 2026-05-25

- **Cost tracking** — `result.cost` with `input_cost`, `output_cost`, `total_cost`
- **`ActiveHarness::Costs`** module with pricing data for 100+ models (`data/models.json`)
- **Agent error docs** — `docs/agent_error_processing.md`
- **Tribunal error docs** — `docs/tribunal_errors_processing.md`
- **Tribunal streaming docs** — `docs/tribunal_streaming.md`
- **Tribunal verdict strategies docs** — `docs/tribunal_verdict_strategies.md`
- Tribunal hooks docs updated: `before_agent`, index args

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
- **RubyLLM backend** — `ActiveHarness::Agent::RubyLLMBackend`, use RubyLLM as the HTTP layer
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
