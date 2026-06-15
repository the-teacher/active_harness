# Changelog

## v0.2.39 — 2026-06-15

### Pipeline: lambda steps, `executors` accessor, `steps` iterator, unified `call` interface

#### Lambda steps

A step can now be a plain Ruby lambda instead of an agent class. The lambda must return an `ActiveHarness::Result`:

```ruby
step :normalize, ->(input) {
  clean = input.strip.gsub(/\s+/, " ")
  ActiveHarness::Result.new(output: clean, processed: clean)
}
```

Declare `context:` and/or `params:` in the signature to receive pipeline context and params:

```ruby
step :enrich, ->(input, context:, params:) {
  prefix = context[:user_name] || params[:prefix] || ""
  ActiveHarness::Result.new(output: "#{prefix}: #{input}", processed: "#{prefix}: #{input}")
}
```

Lambda steps support `stop_if` via the block form:

```ruby
step :length_guard do
  use ->(input) {
    ActiveHarness::Result.new(output: input, processed: { "too_long" => input.length > 500 })
  }
  stop_if ->(result) { result.processed["too_long"] == true }
end
```

Lambda steps have no model chain, no retry logic, and no hooks. They run synchronously.

#### `pipeline.executors` — pre-call configuration

All non-lambda executor instances (agents, tribunals, nested pipelines) are now created at `Pipeline.new` — before `call` runs. This lets you reconfigure them per-request:

```ruby
pipeline = SupportPipeline.new(input: "...")
pipeline.executors[:translate].models.prepend(provider: :openai, model: "gpt-4.1-mini")
pipeline.executors[:respond].params = { tone: "formal" }
pipeline.call
```

#### `pipeline.steps` iterator — replaces `step_results`

`pipeline.step_results` (hash) is replaced by `pipeline.steps` (enumerator). Each iteration yields `(name, executor, result)`:

```ruby
pipeline.steps { |name, executor, result| puts "#{name}: #{result.output}" }

# Enumerator form
pipeline.steps.map { |name, executor, result| [name, result.output] }
```

Steps that did not run (pipeline stopped before reaching them) are skipped automatically.

**Breaking change:** `pipeline.step_results` is removed. Use `pipeline.steps { |name, executor, result| }` or `pipeline.steps.to_a`.

#### Unified `call` interface

`Pipeline#call` and `Tribunal#call` now accept `(input = nil, token: nil, stream: nil)`, matching the `Agent#call` interface. This makes all three abstractions interchangeable as pipeline executors.

---

## v0.2.38 — 2026-06-15

### Cost lookup extracted to `agent/cost.rb` with extensible provider table

`lookup_model_cost` moved from `agent.rb` to `agent/cost.rb` and refactored to a three-tier fallback:

1. `provider_cost` in the API response (handled upstream in `build_usage`)
2. Provider-specific source from `PROVIDER_PRICING_SOURCES` (e.g. `Pricing::OpenRouter` for `:openrouter`)
3. `Pricing::ModelsDev` general fallback

```ruby
PROVIDER_PRICING_SOURCES = {
  openrouter: Pricing::OpenRouter
}.freeze
```

To add pricing support for a new provider, add an entry to `PROVIDER_PRICING_SOURCES` — no other changes required.

---

## v0.2.37 — 2026-06-14

### Pricing extracted to `active_harness_pricing` gem

`ActiveHarness::Pricing` and its two data sources (`ModelsDev`, `OpenRouter`) moved to a standalone gem [`active_harness_pricing`](https://github.com/the-teacher/active_harness). `active_harness` now declares it as a required dependency.

- `lib/active_harness/pricing.rb` and `lib/active_harness/pricing/` removed from this repo
- `require "active_harness_pricing"` replaces the three `require_relative` calls in `active_harness.rb`
- `spec.add_dependency "active_harness_pricing"` added to gemspec
- Namespace `ActiveHarness::Pricing` is unchanged — no call-site changes required

---

## v0.2.36 — 2026-06-14

### Unified streaming interface — `streams:` hash replaced by `token:` and `stream:`

The four-key `streams: { token:, agent:, tribunal:, pipeline: }` hash is removed in favour of two flat keyword params:

| Param | Signature | Purpose |
|---|---|---|
| `token:` | `->(chunk) {}` | Raw token-by-token streaming from the LLM provider. Controls HTTP streaming mode. |
| `stream:` | `->(source, event, *args) {}` | Lifecycle events from any layer. `source` is `:agent`, `:tribunal`, or `:pipeline`. |

All three abstractions — `Agent`, `Tribunal`, `Pipeline` — now accept `token:` and `stream:` as top-level keyword arguments. The `stream:` lambda flows automatically through the entire chain: Pipeline → Tribunal → Agent. Each layer prefixes its events with the appropriate source symbol, so a single lambda handles all event types at the call site:

```ruby
SupportPipeline.new(
  input:  input,
  stream: ->(source, event, *args) {
    case source
    when :pipeline then handle_pipeline_event(event, args)
    when :tribunal then handle_tribunal_event(event, args)
    when :agent    then handle_agent_event(event, args)
    end
  }
)
```

Adding new entity types in the future only requires a new `when` branch — the interface stays the same.

**Breaking changes:**

- `Agent.call(..., streams: { token: t, agent: s })` → `Agent.call(..., token: t, stream: s)`
- `Tribunal.new(..., streams: { token: t, agent: s, tribunal: s })` → `Tribunal.new(..., token: t, stream: s)`
- `Pipeline.new(..., streams: { token: t, agent: s, tribunal: s, pipeline: s })` → `Pipeline.new(..., token: t, stream: s)`
- `Agent#token_stream` / `Agent#event_stream` → `Agent#token` / `Agent#stream`
- `Tribunal#token_stream` / `Tribunal#agent_event_stream` / `Tribunal#tribunal_event_stream` → `Tribunal#token` / `Tribunal#stream`
- Lifecycle hooks inside agent/tribunal subclasses that called `@event_stream&.call(event, *args)` or `@tribunal_event_stream&.call(event, *args)` must now call `@stream&.call(:agent, event, *args)` or `@stream&.call(:tribunal, event, *args)` respectively
- The class-level Pipeline DSL (`on_agent_event`, `on_tribunal_event`, `on_pipeline_event`) is unchanged — only the runtime-passed parameter changed

**Internal:** `Agent#fire` now calls `@stream&.call(:agent, event, *args)`; `Tribunal#fire` calls `@stream&.call(:tribunal, event, *args)`; `Pipeline#fire` calls `@stream&.call(:pipeline, event, step_name, data)`. `Pipeline#merge_stream` updated to dispatch class-level handlers by source.

---

## v0.2.35 — 2026-06-13

### `Pricing::OpenRouter` — complete rewrite (all modalities)

Previously only fetched `?output_modalities=image` models. Now fetches all 7 modality endpoints and merges results by model id:

- `GET /api/v1/models` (base, ~337 text models)
- `GET /api/v1/models?output_modalities=image` (~32 image-gen models, 25 unique)
- `GET /api/v1/models?output_modalities=embeddings` (~26 models, all unique)
- `GET /api/v1/models?output_modalities=speech` (~9 TTS models)
- `GET /api/v1/models?output_modalities=transcription` (~10 STT models)
- `GET /api/v1/models?output_modalities=video` (~14 models, $0 pricing in API)
- `GET /api/v1/models?output_modalities=rerank` (~4 models, $0 pricing in API)

Merge strategy: models seen in multiple endpoints are deduplicated by id; pricing fields are merged (non-zero value wins); `input_modalities` and `output_modalities` are unioned. Image-output models are further enriched via `GET /api/v1/models/{id}/endpoints` to get the accurate `image_output` rate.

- **Transcription pricing detection** — OpenRouter stores the audio cost in the `prompt` field with two different units depending on the model: values `< 0.0001` are per-audio-token (e.g. `gpt-4o-transcribe` at $2.5/M tokens) and converted with `× 1_000_000`; values `≥ 0.0001` are per-minute (e.g. Whisper at $0.006/min) and stored as raw USD.
- **Zero-priced models included** — rerank and video models have `pricing: {prompt: "0", completion: "0"}` in the API; previously they were filtered out; now only models with missing `id` or `name` are skipped.
- **Cache file renamed** — `pricing_openrouter.json` → `openrouter_pricing.json`

### `Pricing::ModelPrice` — extended modality-specific pricing fields

Five new fields added to the `ModelPrice` struct (all `keyword_init:`):

| field | unit | notes |
|---|---|---|
| `image_input_per_million` | USD / 1M image tokens | vision models (maps from `p[:image]`) |
| `image_output_per_million` | USD / 1M image tokens | imggen models (from `/endpoints`) |
| `audio_input_per_million` | USD / 1M or per-min | audio/transcription input |
| `audio_output_per_million` | USD / 1M audio tokens | TTS models (from `/endpoints`) |
| `web_search_per_request` | USD flat | per web-search call |

`categories` method updated:
- `"speech"` — `output_modalities.include?("speech")`
- `"transcription"` — `output_modalities.include?("transcription")`
- `"rerank"` — `output_modalities.include?("rerank")`
- `"embed"` — `output_modalities.include?("embeddings")` (was name-matching before, now modality-based)
- `"audio"` — now only from `input_modalities` (removed the `output_modalities` side that conflated audio-input and TTS)

### `Pricing::ModelsDev` — 3-day in-memory cache

- `CACHE_TTL = 86_400` (24h file TTL) → `MEMORY_TTL = 3 * 86_400` (72h, applies to both file and memory)
- Three-tier freshness: `memory_fresh?` → `file_fresh?` → network fetch; no network hit while in-memory registry is fresh
- `preload!` class method — forces a network fetch and loads result into memory; network failures are silently rescued; called by `Pricing.preload!` at Rails startup
- `reload!` now also nils `@loaded_at` so next access re-reads from file/network
- Cache file renamed: `pricing_models_dev.json` → `models_dev_pricing.json`

### `Pricing.preload!` facade method

New `Pricing.preload!` method calls `ModelsDev.preload!` and `OpenRouter.preload!` in sequence. Network failures from either source are silently rescued — the other source still loads.

### `Railtie` — pricing preloaded at Rails startup

```ruby
config.after_initialize do
  ActiveHarness::Pricing.preload!
end
```

Runs after all initializers, before the first request. In Puma with `preload!` the fetch happens in the master process and workers inherit the in-memory registry via copy-on-write.

---

## v0.2.34 — 2026-06-13

- **Image generation support** — new `image true` / `size "1024x1024"` class-level DSL on `Agent`; when set, the model chain is routed through `IMAGE_PROVIDERS` instead of the standard text provider table
- **`Providers::Images::OpenAI`** (`lib/active_harness/providers/images/openai.rb`) — calls `/v1/images/generations`; accepts `model:`, `prompt:`, `size:`, `quality:`; returns `b64_json`; defaults to `"1024x1024"` (compatible with dall-e-3 and gpt-image models)
- **`Providers::Images::OpenRouter`** (`lib/active_harness/providers/images/openrouter.rb`) — uses the chat completions endpoint with `modalities: ["image", "text"]`; builds `messages` internally from the `prompt:` string
- **`agent/image.rb`** — model validation at call time: each model in the chain is checked against `Pricing.find(model_id).categories`; raises `ArgumentError` if the model does not include `"imggen"` in its output modalities; unknown models (not in registry) pass silently
- **`Pricing::ModelsDev`** (`lib/active_harness/pricing/models_dev.rb`) — models.dev implementation extracted from `pricing.rb` into its own module; cache file renamed to `pricing_models_dev.json`; serves as the general fallback source
- **`Pricing::OpenRouter`** (`lib/active_harness/pricing/openrouter.rb`) — new pricing source specific to OpenRouter; fetches image models via `GET /api/v1/models?output_modalities=image`, then enriches each with `image_output` rate from `/api/v1/models/{id}/endpoints`; cache file `pricing_openrouter.json`; `image_output` rate is used as `output_per_million` for image-output models
- **`pricing.rb` rewritten as facade** — now only defines shared types (`ModelPrice`, `ProvidersProxy`) and delegates `Pricing.find` / `Pricing.all` / etc. to `ModelsDev`
- **`provider_cost` from response** — `Providers::Base#extract_usage_openai` extracts `usage["cost"]` when present (returned by OpenRouter for image calls); `Agent#build_usage` uses it as exact cost, bypassing token-rate calculation; `lookup_model_cost` now checks `Pricing::OpenRouter` first for `:openrouter` provider before falling back to `Pricing::ModelsDev`
- **Bundled `data/models.json` removed** — 1.4 MB snapshot deleted; `Pricing::ModelsDev` returns `nil` / `[]` when cache is absent and network is unavailable rather than serving stale bundled data

---

## v0.2.33 — 2026-06-12

- **`Core::HookRunner#run_hooks`** — minor readability fix: condition inverted from `args.any?` to `args.empty?` (same behaviour, clearer branch ordering)

---

## v0.2.32 — 2026-06-12

- **`Costs` → `Pricing`** — module renamed from `ActiveHarness::Costs` to `ActiveHarness::Pricing`; file `lib/active_harness/costs.rb` renamed to `pricing.rb`; all internal references updated
- **`docs/agents/costs.md` → `pricing.md`** — doc file renamed to match the new module name

---

## v0.2.31 — 2026-06-12

- **`Result` struct restructured** — flat fields (`provider`, `model` string, `temperature`, `context_window`, `cost`) replaced with nested value objects:
  - `ModelInfo` — `.name`, `.provider`, `.temperature`, `.context_window`, `.pricing` (`ModelPricing` or nil); `result.model` now returns this struct
  - `ModelPricing` — `.input`, `.output` per-token rates in USD
  - `TokenCounts` — `.input`, `.output`, `.total`; `result.usage.tokens`
  - `CostBreakdown` — `.input`, `.output`, `.total` in USD; `result.usage.cost`
  - `UsageInfo` — `.tokens` + `.cost`; `result.usage` now returns this struct
- **`Agent#build_model_info` / `#build_usage`** — extracted as private methods; `calculate_cost` signature changed from `(model_id, usage)` to `(pricing, tokens)` to work with the new structs
- **`@context_window` removed from `Agent` attrs** — no longer set in `initialize` or exposed as `attr_reader`; computed lazily via `context_window_for_prompt` only when injecting state into a prompt class instance

---

## v0.2.30 — 2026-06-11

- **`Pipeline#result`** — new method that wraps pipeline outcome into a `Result` struct (`input`, `output`, `processed`, `execution_time`); `processed` carries `{ "stopped" => bool, "stopped_at" => step_name_or_nil }`; lets a pipeline be used as a step inside another pipeline with the same duck-type interface as `Agent` and `Tribunal`
- **`Pipeline::Step#transform` DSL** — new block-form DSL inside a step definition; the block receives the `Result` and must return the new payload value; enables custom extraction when the raw `result.output` is not what should flow downstream (e.g. nested pipeline steps, struct fields)
- **`Step#transform?` updated** — now returns `true` when an explicit `transform` block is defined, regardless of whether `stop_if` is also set; legacy default (`!tribunal? && @stop_if.nil?`) still applies when no block is given
- **`Step#extract_payload`** — new private helper; calls the user's `transform` block when present, otherwise falls back to `result.output`; replaces the inline `result.output` assignment in `Pipeline#call`
- **`execute_step` forwards `pipeline:` stream** — nested pipeline instances now receive the outer pipeline's `@pipeline_event_stream`; inner pipeline step events (`:before_step`, `:after_step`, `:stopped`, `:complete`) propagate to SSE controllers and other stream consumers transparently

---

## v0.2.29 — 2026-06-10

- **`Memory` direct instantiation blocked** — `Memory.new(...)` now raises `NotImplementedError` when called directly; users must instantiate one of the concrete subclasses: `Memory::JsonFile`, `Memory::Postgresql`, or `Memory::Sqlite`
- **Documentation** — `docs/MEMORY.md` added: covers `Memory::JsonFile` with all options, custom memory subclass pattern, managing memory via agent callbacks, `AgentMemory` concern, three injection patterns (input prepend, system prompt hook, prompt class), `to_messages` filters, API reference, namespace isolation, pipeline sharing, and PostgreSQL / SQLite backend setup; each backend section includes a custom subclass example

---

## v0.2.28 — 2026-06-09

- **`Result#context_window`** — new field on `Result`; populated from `ActiveHarness::Pricing` after each successful call using the model that actually ran (primary or fallback); `nil` if the model is not in the registry
- **`Agent#context_window`** — new `attr_reader`; set at initialization time from the first model in the list via `Pricing`; available in all hook blocks as `@context_window`; injected into prompt class instances alongside `@input`, `@memory`, etc.
- **`Memory#to_messages(token_budget:)`** — new optional parameter; trims turns oldest-first using a `chars / 4` token estimate until the budget is satisfied; composable with existing `filter:`, `since:`, and `depth:` options
- **`MemoryPrompt` updated** — automatically passes `token_budget: context_window * 0.25` to `to_messages` when `@context_window` is present; falls back to no limit when context window is unknown

---

## v0.2.27 — 2026-06-09

- **`memory:` as a first-class parameter** — `Agent.call`, `Agent.new`, and `Tribunal.new` now accept `memory: nil` alongside `input:`, `context:`, `params:`, `streams:`; stored as `@memory` / `attr_accessor :memory`; passing memory through `context: { memory: mem }` is no longer needed or recommended
- **`inject_agent_state` injects `@memory`** — prompt classes now receive `@memory` directly as an instance variable, just like `@input` and `@context`; reading memory from `@context[:memory]` in prompts is no longer needed
- **`AgentMemory` concern simplified** — `:setup` callback that extracted `@memory` from `@context` removed; `@memory` is set by the constructor before any hook fires
- **Docs updated** — examples `011`, `019`, `020` rewritten to use `memory:` parameter at call sites; concern code updated to remove the setup extraction step

---

## v0.2.26 — 2026-06-09

- **`Result#parsed` renamed to `Result#processed`** — the field that holds the parsed JSON output of an agent is now called `processed`; reflects that the value has been processed/normalized, not just parsed; all internal code, generator templates, and docs updated
- **`Tribunal#result`** — new method that returns a `Result` with `processed: { "verdict" => @verdict }`; tribunals and agents now expose the same interface from the pipeline's point of view
- **`Pipeline#execute_step` unified** — the `if tribunal? / else` branch removed; both agents and tribunals are executed via the same single path: `.call.result`; `tribunal?` check retained only in `Step#transform?` to prevent tribunal steps from updating the payload
- **Pipeline `README.md`** — new file at `lib/active_harness/pipeline/README.md` covering basic usage, step types, payload propagation, stop mechanics, events/hooks, memory, and a design proposal for a universal step interface (duck-type, lambda, Rack-style env, module-based options)

---

## v0.2.25 — 2026-06-09

- **Memory adapter files consolidated** — `adapter/file.rb` removed; `Memory::JsonFile` (convenience class) and `Adapter::JsonFile` (raw adapter, renamed from `Adapter::File`) now live together in `adapter/json_file.rb`; same pattern applied to PostgreSQL and SQLite — each `adapter/*.rb` file defines both the raw adapter and the public `Memory::*` subclass; require chain in `memory.rb` simplified to three lines
- **`ADAPTERS` registry updated** — `:file` key replaced with `:json_file`; default adapter in `Memory#initialize` changed from `:file` to `:json_file`
- **`ActiveHarness::Memory::Postgresql`** — new PostgreSQL-backed memory; `pg` gem is NOT a dependency — install it yourself; adapter lazy-loads `pg` and raises a descriptive `LoadError` if missing; accepts `connection:` (borrow a `PG::Connection`) or `url:`/`host:`/`dbname:`/… (adapter opens and owns the connection); parameterized queries throughout; `storage_size:` + `eviction_percent:` trim oldest rows via subquery DELETE; `namespace:` uses `IS NOT DISTINCT FROM` for NULL-safe comparison
- **`ActiveHarness::Memory::Sqlite`** — new SQLite-backed memory; `sqlite3` gem is NOT a dependency — install it yourself; adapter lazy-loads `sqlite3`; accepts `connection:` (borrow a `SQLite3::Database`) or `database:` path (adapter opens, enables WAL, and owns the connection); `database: ":memory:"` supported for tests; `?` placeholders and `IS` for NULL-safe namespace comparison; meta stored as JSON text (no JSONB)
- **`Memory::Sqlite.create_schema!`** — class method that creates the table and index using `CREATE TABLE IF NOT EXISTS`; accepts a file path or an existing `SQLite3::Database`; covers plain Ruby projects where no migration system exists
- **Rails generators for migrations** — `rails generate active_harness:memory_postgresql` and `rails generate active_harness:memory_sqlite` each create a timestamped migration in `db/migrate/` using the current `ActiveRecord::Migration` version; PostgreSQL migration uses `jsonb` for meta; SQLite migration uses `text`
- **Generator templates updated** — `install` and `memory` generator templates now produce classes that inherit from `Memory::JsonFile` with `file_name:` interface instead of raw `Memory` with `adapter: :file`
- **Docs** — `docs/agents/examples/019_memory_postgresql.md` and `020_memory_sqlite.md` added; cover schema setup, Rails and plain Ruby usage, constructor options, API reference, SQL queries over history, and adapter comparison table

---

## v0.2.24 — 2026-06-09

- **`ActiveHarness::Memory::JsonFile`** — new convenience subclass of `Memory` with a `file_name:` interface; replaces `session_id:` with a path-safe name that may contain slashes (`"users/42/chat"`); final file is always `<storage_path>/<file_name>.json`; path traversal segments (`..`, `.`) and null bytes are rejected with `ArgumentError`; missing directories are created automatically on first write; default `storage_path` is `"storage/ai/memory"`
- **`Memory::JsonFile` — `.json` deduplication** — passing `file_name` with a `.json` suffix (e.g. `"chat.json"`) no longer produces a double extension (`chat.json.json`); the suffix is stripped in `sanitize!` before the session_id is set
- **Example 011 rewritten** — `docs/agents/examples/011_memory_and_history.md` updated to show the recommended concern-based pattern (`AgentMemory` concern with `:setup` / `:before_call` / `:after_call` hooks), full `JsonFile` API reference, file storage layout, and in-memory history pattern without persistence

---

## v0.2.23 — 2026-06-09

- **Memory removed from `Agent`** — `memory:` parameter removed from `Agent.call` and `Agent.new`; `memory=` setter removed; automatic `save_to_memory` and `@memory&.load` on call removed; memory management is now the caller's responsibility
- **`:before_call` fires before `resolve_system_prompt`** — hook order corrected so that `:before_call` blocks run before the system prompt is resolved; hooks can now mutate `@input` / `@context` and have those changes reflected in the system prompt
- **Pipeline class-level event stream DSL** — three new class-level methods: `on_agent_event`, `on_tribunal_event`, `on_pipeline_event`; each accepts a block and accumulates multiple handlers; blocks run via `instance_exec` so pipeline instance variables (`@params`, `@otel_span`, etc.) are accessible
- **`Pipeline#merge_stream`** — private helper that combines a runtime-passed `streams:` lambda with class-level handler blocks; returns `nil` when no handlers exist, preserving the existing no-stream fast path in agents and tribunals
- **Examples** — 18 annotated example docs added under `docs/agents/examples/` (basic agent, fallback chain, hooks, streaming, memory, error handling, custom LLM backend, guards, pipelines, caching, monitoring, testing)

---

## v0.2.22 — 2026-05-29

- **`Core::HookRunner`** — shared hook execution module extracted to `lib/active_harness/core/hooks.rb`; included by `Agent`, `Tribunal`, and `Pipeline`; replaces duplicated `run_hook` logic across all three classes
- **Multiple hooks per event** — hooks are now stored as arrays; registering the same event multiple times (e.g. from a concern and from the class body) accumulates all blocks in order instead of overwriting; `include SomeTracingConcern` + `before(:call) { ... }` in the same class both run
- **`params:` argument** — `Agent`, `Tribunal`, and `Pipeline` now accept `params: {}` alongside `context: {}`; forwarded to inner agents when a tribunal or pipeline resolves its agent chain; accessible as `@params` / `attr_accessor :params`
- **`transform_hook` multi-block chaining** — `:before_verdict` now pipes the result through every registered block in sequence (`reduce`); consistent with the new array-based hook storage
- **`Tribunal#on` instance method** — no longer overwrites class-level hooks; appends to per-instance hook array instead
- **`@hooks` deep-dup on init** — `Tribunal#initialize` clones hooks with `transform_values { Array(v).dup }` so instance-level `on(...)` calls don't mutate the shared class config

---

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
- **`Pricing.load_registry`** — robust loading: falls back to bundled `data/models.json` when cache is absent or corrupted (`JSON::ParserError`)

---

## v0.2.12 — 2026-05-25

- **`ActiveHarness::Pricing`** module — pricing registry for 100+ models
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
