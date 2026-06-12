# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**ActiveHarness** is a Ruby gem (`active_harness`) for building production-grade LLM pipelines. It wraps individual LLM calls with retry logic, fallback chains, observability hooks, cost tracking, streaming, and consensus-based decisions. Works in plain Ruby and Rails. Current version: `0.2.x`.

## Commands

```bash
# Install dependencies (gem has no Gemfile — use bundler in consuming apps)
bundle install

# Run all tests
bundle exec rake test

# Build gem artifact
make build

# Bump patch version, sync, and release to RubyGems
make up

# Bump minor version
make up/minor

# Bump major version
make up/major
```

Tests live in `test/active_harness/` and use Minitest. There is no linter. Ruby 2.6+ compatibility is required — no endless `def`, no numbered block params.

## Architecture

### Three Primary Abstractions

**`ActiveHarness::Agent`** (`lib/active_harness/agent.rb` + `lib/active_harness/agent/`)
Single LLM call with a model chain, system prompt, hooks, retry policy, and optional streaming. Call pattern: `MyAgent.call(input: "...", context: {}, params: {}, memory: nil, models: nil, streams: {})`. Returns `self`; result is on `agent.result` (a `Result` struct). Can also be instantiated and called inline: `agent.call("new input")`.

**`ActiveHarness::Tribunal`** (`lib/active_harness/tribunal.rb` + subdirs)
Runs multiple agents in parallel via `concurrent-ruby`'s `Concurrent::Future`. Computes a verdict from all successful results using either a `:unanimous`/`:majority` built-in strategy or a custom `process { |results| ... }` block. Tolerates partial failure via `may_fail: N`. Returns `self`; verdict is on `tribunal.verdict`.

**`ActiveHarness::Pipeline`** (`lib/active_harness/pipeline.rb` + subdirs)
Sequential chain of agents and tribunals as named steps. Each step can have a `stop_if` lambda; when it fires, `pipeline.stopped?` becomes true and subsequent steps are skipped. Step results accumulate in `pipeline.step_results` and are also forwarded as `context[step_name]` to downstream steps. Each step's output replaces the payload only when `step.transform?` is true (i.e., a `use` agent rather than a tribunal that only produces a verdict).

### Supporting Components

**Prompt classes** (`app/ai/prompts/` in Rails) — Plain Ruby objects with `#call` (or `#text`) that return strings. Agent injects `@input`, `@context`, `@params`, `@memory`, `@context_window`, and `@config` into prompt instances before calling them. Also accepts inline strings or lambdas.

**`ActiveHarness::Memory`** (`lib/active_harness/memory.rb`) — Conversation history storage. Must be subclassed (`Memory::JsonFile`, `Memory::Postgresql`, `Memory::Sqlite`). Records turns automatically after each successful agent/pipeline call. **Memory is never auto-injected into LLM messages** — always inject manually via a hook, prompt class, or `before_call` block.

**`ActiveHarness::Result`** — `Struct` wrapping: `input`, `output`, `processed`, `system_prompt`, `model` (a `ModelInfo` struct with `.name`, `.provider`, `.temperature`, `.context_window`, `.pricing`), `model_list`, `attempts`, `execution_time`, `usage` (a `UsageInfo` struct with `.tokens.{input,output,total}` and `.cost.{input,output,total}`). For `format :json` agents, `processed` is a parsed Ruby Hash/Array; for `:text` it's the raw string.

**Providers** (`lib/active_harness/providers/`) — One file per provider, all subclassing `Providers::Base`. Supported symbols: `:openai`, `:anthropic`, `:gemini`, `:groq`, `:openrouter`, `:xai`, `:deepseek`, `:mistral`, `:ollama`, `:perplexity`, `:gpustack`, `:azure`, `:bedrock`, `:vertexai`, `:custom`. To add a provider: subclass `Providers::Base`, implement `#call`, register in `agent/providers.rb` `PROVIDERS` hash.

**`ActiveHarness::Pricing`** — Pulls pricing from `models.dev` API (cached 24h in `tmp/active_harness/pricing.json`), falls back to bundled `lib/active_harness/data/models.json`.

### Hooks System

All three abstractions share `Core::HookRunner`. Hooks are arrays — multiple registrations accumulate, all fire in order. Blocks run via `instance_exec` so they have access to agent/pipeline/tribunal instance variables.

Agent hooks: `:setup`, `:before_call`, `:after_call`, `:before_system_prompt`, `:after_system_prompt`, `:before_parse`, `:after_parse`, `:parse_error`, `:retry`, `:failure`.
Rails-style aliases: `before :call`, `after :call`, `callback :setup`, etc.

Pipeline hooks: `:before_step`, `:after_step`, `:stopped`, `:complete`. Can be scoped to a specific step: `on :before_step, :translate do |payload| ... end`.

Tribunal hooks: `:before_call`, `:after_call`, `:before_agent`, `:after_agent`, `:agent_error`, `:before_verdict`, `:after_verdict`.

**Event streams** (`streams: { token:, agent:, tribunal:, pipeline: }`) are lambdas passed at call-site that fire alongside DSL hooks — used for Rails SSE, OpenTelemetry, logging, etc. Pipelines merge class-level `on_agent_event`/`on_tribunal_event`/`on_pipeline_event` blocks with runtime-passed lambdas.

### Model Chain DSL

```ruby
# Block form
model do
  use      provider: :openrouter, model: "mistralai/mistral-nemo"
  fallback provider: :openai,     model: "gpt-4.1-mini", temperature: 0.3
end

# Array form
models [
  { provider: :openai, model: "gpt-4.1-mini" },
  { provider: :anthropic, model: "claude-haiku-4-5-20251001" }
]
```

Each entry supports `retry_attempts:` and `retry_delay:` overrides. At runtime the model chain can be mutated via `agent.models.prepend(...)`, `.push(...)`, `.insert(pos, ...)`, or `.replace(...)`.

**Retry policy** (`Http::RetryPolicy`): exponential backoff, defaults 3 attempts / 1s base delay. `RETRYABLE_ERRORS` (timeout, rate-limit, server, unavailable, invalid-request) advance to the next fallback model. `STOP_ERRORS` (invalid API key, safety-blocked) abort the chain immediately.

### Custom LLM Backend

Agents can delegate HTTP calls to `ruby_llm` (or any external client) instead of the built-in Net::HTTP providers:

```ruby
custom_llm_backend do |params|
  RubyLLM.chat(model: params.model, provider: params.provider, assume_model_exists: true)
end
```

All ActiveHarness features (fallbacks, retry, hooks, streaming) still apply.

### Rails Integration

`Railtie` auto-adds `app/ai/{agents,prompts,tribunals,pipelines,memory}` to `autoload_paths`. Configure in `config/initializers/active_harness.rb`:

```ruby
ActiveHarness.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # All API keys fall back to matching ENV vars by default.
end
```

Generators: `rails g active_harness:install`, `rails g active_harness:agent NAME`, `rails g active_harness:prompt NAME`, `rails g active_harness:tribunal NAME`, `rails g active_harness:pipeline NAME`, `rails g active_harness:memory NAME`.

## Key Constraints

- **`Memory` is abstract** — cannot be instantiated directly; use `Memory::JsonFile`, `Memory::Postgresql`, or `Memory::Sqlite`.
- **Each subclass gets its own isolated config** via `inherited` hooks — never share config across agent/tribunal/pipeline classes at the class level.
- **No Gemfile in this repo** — it is a gem, not an application. Tests are run via Rake.
- **Single runtime dependency**: `concurrent-ruby` (for `Tribunal`). Keep new dependencies minimal and justified.
