# Agent → Request Migration Checklist

**Status:** planning only — nothing in this repo has been renamed yet. This document is the punch list for when the rename is actually executed.

## Why

`ActiveHarness::Agent` today is a single resilient LLM call: a model chain with fallback, retry policy, hooks, streaming, and output parsing. It has no notion of choosing/using tools or taking autonomous actions. The name `Agent` is being reserved for a *future*, different abstraction (an entity that uses a model to decide and execute actions). The current class is being renamed to `ActiveHarness::Request` to free up the name and to accurately describe what it does today.

The `#call` interface (both `SomeRequest.call(...)` and `instance.call(...)`) stays exactly as it is — it's shared with `Tribunal` and `Pipeline` and is a deliberate Ruby "callable object" idiom. Only the *name* of the class (and everything that says "agent" to describe it) changes.

## Non-goals

- **Not implementing the future tool-using `Agent` concept.** This migration only frees the name; a new `ActiveHarness::Agent` may be introduced later as a separate effort, at which point it will likely reclaim `app/ai/agents/`, `docs/agents/`, and the `active_harness:agent` generator name.
- **Not rewriting `CHANGELOG.md` history.** Past entries describing `ActiveHarness::Agent` document what shipped in those versions and must stay as-is. Only add a *new* entry for this rename under the next version.
- **Not changing the `#call` method name or signature** on any of the three abstractions.

## Naming map

| Old | New |
|---|---|
| `ActiveHarness::Agent` (class) | `ActiveHarness::Request` |
| `lib/active_harness/agent.rb` | `lib/active_harness/request.rb` |
| `lib/active_harness/agent/` (dir + all files inside) | `lib/active_harness/request/` |
| `agent_config` (class method) | `request_config` |
| `Agent::IMAGE_PROVIDERS` | `Request::IMAGE_PROVIDERS` |
| `Agent::TRANSCRIPTION_PROVIDERS` | `Request::TRANSCRIPTION_PROVIDERS` |
| Tribunal DSL: `agents PolitenessAgent, ...` | `requests PolitenessRequest, ...` |
| Tribunal keyword arg: `agents:` | `requests:` |
| Tribunal attr: `agent_execution_times` | `request_execution_times` |
| Tribunal hooks: `:before_agent` / `:after_agent` / `:agent_error` | `:before_request` / `:after_request` / `:request_error` |
| Tribunal hook aliases: `before :agent` / `after :agent` / `callback :agent_error` | `before :request` / `after :request` / `callback :request_error` |
| Tribunal internal: `resolve_agents`, `@agents`, `agent_handlers` | `resolve_requests`, `@requests`, `request_handlers` |
| `Errors::AllAgentsFailed` | `Errors::AllRequestsFailed` (keep `Errors::AllModelsFailed` — unrelated, still per-`Request` model-chain exhaustion) |
| Pipeline: `on_agent_event` | `on_request_event` |
| Pipeline stream source symbol `:agent` (in `stream: ->(source, event, *args) {}`) | `:request` |
| `app/ai/agents/` (Rails app dir) | `app/ai/requests/` |
| `Railtie::APP_AI_DIRS` entry `"agents"` | `"requests"` |
| Generator `active_harness:agent` | `active_harness:request` |
| `lib/generators/active_harness/agent/` | `lib/generators/active_harness/request/` |
| Generated file suffix `*_agent.rb` | `*_request.rb` |
| Doc dir `docs/agents/` | `docs/requests/` |
| `docs/AGENTS.md` | `docs/REQUESTS.md` |

## Decisions needed before starting

- [ ] **Backward-compat alias?** Ship `ActiveHarness::Agent = ActiveHarness::Request` (deprecated constant) for one release, or hard-break immediately? README already states "API is under active development and may change between versions without notice" and gem is pre-1.0 — hard break is defensible, but confirm with anyone else depending on the gem.
- [ ] **Version bump.** This is a breaking rename → use `make up/minor` (per `CLAUDE.md`), not `make up`.
- [ ] Confirm final class name is `Request` (not `Completion`/`Operation`/etc. — locking this in before touching files avoids a second pass).

## Phase 1 — Core library rename

- [ ] `git mv lib/active_harness/agent.rb lib/active_harness/request.rb`
- [ ] `git mv lib/active_harness/agent lib/active_harness/request` (carries all files below with it)
  - [ ] `lib/active_harness/agent/cost.rb`
  - [ ] `lib/active_harness/agent/custom_llm_backend.rb`
  - [ ] `lib/active_harness/agent/hooks.rb`
  - [ ] `lib/active_harness/agent/image.rb`
  - [ ] `lib/active_harness/agent/models.rb`
  - [ ] `lib/active_harness/agent/output_parser.rb`
  - [ ] `lib/active_harness/agent/prompt.rb`
  - [ ] `lib/active_harness/agent/providers.rb`
  - [ ] `lib/active_harness/agent/transcription.rb`
- [ ] In `request.rb`: rename `class Agent` → `class Request`, `agent_config` → `request_config`, `@agent_config` ivar → `@request_config`, update the `require_relative "agent/..."` lines to `"request/..."`.
- [ ] Inside each moved file under `request/`: update `module ActiveHarness; class Agent` reopenings to `class Request`, and any internal references/comments to "agent".
- [ ] `lib/active_harness.rb:30` — `require_relative "active_harness/agent"` → `"active_harness/request"`.

## Phase 2 — Ripple into Tribunal

`lib/active_harness/tribunal.rb`, `lib/active_harness/tribunal/dsl.rb`, `lib/active_harness/tribunal/hooks.rb`:

- [ ] DSL method `agents(*list)` → `requests(*list)`; `tribunal_config[:agents]` → `tribunal_config[:requests]`.
- [ ] Constructor kwarg `agents:` → `requests:`; `@agents` ivar → `@requests`.
- [ ] `attr_reader :agent_execution_times` → `:request_execution_times`; `@agent_execution_times` → `@request_execution_times`.
- [ ] Hook names `:before_agent`, `:after_agent`, `:agent_error` → `:before_request`, `:after_request`, `:request_error` (in `tribunal/hooks.rb` HOOK list and doc comments, and `Rails-style aliases`: `before :agent` → `before :request`, etc.).
- [ ] Method `resolve_agents` → `resolve_requests`; local var `agent`/`agents` throughout `call`/`resolve_requests`/`error_summary` → `request`/`requests`.
- [ ] `fire(:before_agent, ...)` / `fire(:after_agent, ...)` / `fire(:agent_error, ...)` calls → `:before_request`/`:after_request`/`:request_error`.
- [ ] `value.is_a?(ActiveHarness::Agent)` (tribunal.rb ~line 142) → `ActiveHarness::Request`.
- [ ] Class-comment examples at top of `tribunal.rb` (direct-usage and DSL-subclass examples) — rewrite `ToxicityAgent, BiasAgent, SpamAgent` etc. to `*Request` names.

## Phase 3 — Ripple into Pipeline

`lib/active_harness/pipeline.rb`, `lib/active_harness/pipeline/step.rb`:

- [ ] `on_agent_event` class method → `on_request_event`; `pipeline_config[:streams][:agent]` → `[:request]`.
- [ ] `agent_handlers = Array(class_handlers[:agent])` → `request_handlers = Array(class_handlers[:request])`; the `when :agent then agent_handlers` branch → `when :request then request_handlers`.
- [ ] Doc comments: `use InjectionGuardAgent`, `step :translate, TranslationAgent` and similar examples → `*Request` names.
- [ ] Comment "matching the same interface as Agent and Tribunal" / "Agent/Tribunal call interface" → "Request and Tribunal".

## Phase 4 — Errors, Result, Memory, Configuration, Railtie (comments/docs only unless noted)

- [ ] `lib/active_harness/core/errors.rb`: `AllAgentsFailed` → `AllRequestsFailed` (keep `AllModelsFailed` untouched — different failure mode, still owned by `Request`). Update the comment above it.
- [ ] `lib/active_harness/core/hooks.rb`: comment "Shared hook execution logic included by Agent, Tribunal, and Pipeline" and example `class MyAgent < ActiveHarness::Agent` → `Request`.
- [ ] `lib/active_harness/result.rb`: comments referencing "Agent#call", "agent call", "agents" (:json/:text) → `Request#call` / "request call" / "requests".
- [ ] `lib/active_harness/memory.rb`: multiple doc-comment references (`Agent.call(memory:)`, `SupportAgent.call(...)`, `turn[:agent]`, "agents", "per-agent") → `Request` equivalents. Note: `turn[:agent]` may be an actual stored-data key in consumer apps' memory backends — if any generator/template writes that key literally, decide whether to rename the *stored field* too (breaking for existing persisted memory) or just the doc language. Recommend: leave persisted-data key names alone, only fix prose, unless a template actually sets `agent:` as a hash key (check `lib/generators/active_harness/*/templates/` for this before deciding).
- [ ] `lib/active_harness/configuration.rb:115`: comment "Use in an agent:" → "Use in a request:".
- [ ] `lib/active_harness/providers/azure.rb`, `bedrock.rb`, `custom.rb`, `vertexai.rb`: comment-only mentions ("Example agent config", "agent falls through to the next model", "Use in an agent:") → `Request` wording.
- [ ] `lib/active_harness/railtie.rb`: `APP_AI_DIRS = %w[agents prompts tribunals pipelines memory]` → `%w[requests prompts tribunals pipelines memory]`.

## Phase 5 — Generators

- [ ] `git mv lib/generators/active_harness/agent lib/generators/active_harness/request`
  - [ ] `agent_generator.rb` → `request_generator.rb`; class `Agent::AgentGenerator`-style name → `Request::RequestGenerator`-style (match actual class/module naming inside the file).
  - [ ] `templates/agent.rb.tt` → `templates/request.rb.tt`; template content's `class <%= ... %> < ActiveHarness::Agent` → `< ActiveHarness::Request`.
- [ ] `lib/generators/active_harness/install/install_generator.rb`: any reference to the `agents/` template dir or `active_harness:agent` generator name → `requests/`.
- [ ] `git mv lib/generators/active_harness/install/templates/agents lib/generators/active_harness/install/templates/requests`
  - [ ] `support_agent.rb` → `support_request.rb`; class `SupportAgent` → `SupportRequest`; `< ActiveHarness::Agent` → `< ActiveHarness::Request`.
  - [ ] `support_guard_agent.rb` → `support_guard_request.rb`; class `SupportGuardAgent` → `SupportGuardRequest`.
- [ ] `lib/generators/active_harness/install/templates/controllers/ai_controller.rb`: update references to `SupportAgent`/`SupportGuardAgent`.
- [ ] `lib/generators/active_harness/install/templates/pipelines/support_pipeline.rb`: update `use SupportAgent` / `use SupportGuardAgent`-style references.
- [ ] `lib/generators/active_harness/install/templates/tribunals/support_guard_tribunal.rb`: update `agents SupportGuardAgent, ...` → `requests SupportGuardRequest, ...`.
- [ ] Other generators (`memory`, `memory_postgresql`, `memory_sqlite`, `pipeline`, `prompt`, `tribunal`) — no rename needed, just grep their templates for stray "Agent" mentions in comments.

## Phase 6 — Docs directory & filenames

- [ ] `git mv docs/agents docs/requests`
  - [ ] `agent_error_processing.md` → `request_error_processing.md`
  - [ ] `agent_hooks.md` → `request_hooks.md`
  - [ ] `audio_transcription.md`, `execution_time.md`, `image_generation.md`, `normalize_input.md`, `pricing.md`, `retry_policy.md`, `token_usage.md`, `validation_proposal.md`, `vision.md` — filenames stay, content needs an "Agent" → "Request" pass.
  - [ ] `examples/` subdir (23 files) — filenames stay (numbered), content pass on every file: `001_basic_agent.md`, `002_fallback_chain_basic.md`, `003_fallback_chain.md`, `004_agent_hooks.md`, `005_parse_hooks.md`, `006_system_prompts.md`, `007_parallel_agents.md`, `008_streaming_basic.md`, `009_streaming_rails_sse.md`, `010_streaming_multiple_streams.md`, `011_memory_and_history.md`, `012_error_handling.md`, `013_custom_llm_backend.md`, `014_guards_and_validation.md`, `015_pipelines_orchestration.md`, `016_caching_and_optimization.md`, `017_monitoring_and_metrics.md`, `018_testing_agents.md`, `019_memory_postgresql.md`, `020_memory_sqlite.md`, `QUICK_START.md`, `README.md`.
    - Consider also renaming `001_basic_agent.md` → `001_basic_request.md`, `004_agent_hooks.md` → `004_request_hooks.md`, `007_parallel_agents.md` → `007_parallel_requests.md`, `018_testing_agents.md` → `018_testing_requests.md` for consistency — lower priority than content, but do it in the same pass to avoid two rounds of link updates.
- [ ] `git mv docs/AGENTS.md docs/REQUESTS.md`, full content pass (every code sample uses `< ActiveHarness::Agent`).
- [ ] Content-only pass (no rename) on: `docs/common/activeharness_and_rubyllm.md`, `docs/common/configuration.md`, `docs/common/providers.md`, `docs/common/ruby_configuration.md`, `docs/common/ruby_llm_integration.md`, `docs/INSTALLATION.md`, `docs/MEMORY.md`, `docs/NESTED_PIPLINES.md`, `docs/PIPELINES.md`, `docs/pipelines/pipeline_hooks.md`, `docs/PROMPTS.md`, `docs/rails/rails_configuration.md`, `docs/rails/rails_integration.md`, `docs/rails/rails_streaming.md`, `docs/TRACING.md` (includes an "AgentTracing Concern" heading — decide new heading name, e.g. "RequestTracing Concern"), `docs/TRIBUNALS.md` (headings like "Tribunal from Different Agents", "Same Agent, Different Models", "Runtime Model Prepend per Agent" — renaming these changes their anchors, see Phase 7).

## Phase 7 — README, gemspec, CLAUDE.md

- [ ] `README.md`: full "agent" pass — prose (lines ~15, 19, 41, 51, 59, 67, 69, 87–96), `app/ai` tree diagram (`agents/ # agent classes` → `requests/ # request classes`), the "## Agent Documentation" section header → "## Request Documentation", and **every link that points at a renamed anchor**:
  - `docs/AGENTS.md#...` links → `docs/REQUESTS.md#...` with matching new anchor slugs (anchors change if you reword the heading text — update both together).
  - `docs/TRIBUNALS.md#tribunal-from-different-agents`, `#same-agent-different-models`, `#runtime-model-prepend-per-agent` — update once those headings are renamed in Phase 6.
  - `docs/MEMORY.md#managing-memory-via-agent-callbacks` — same.
  - `docs/TRACING.md#agenttracing-concern` — same.
- [ ] `active_harness.gemspec`: `spec.summary = "DSL for describing and running AI agents with safety layers"` → reword around "requests" (or keep "agents" here deliberately if the summary is meant to describe the *product category*, not the class — **decide**: this is marketing copy, not API surface, may be fine to leave until the future `Agent` concept exists).
- [ ] `CLAUDE.md`: update the "Three Primary Abstractions" section — `ActiveHarness::Agent` → `ActiveHarness::Request`, its file paths, its call pattern description, and every other place in the file that says "agent" describing this class (Model Chain DSL section, Hooks System section's `Agent hooks:` list, Custom LLM Backend section, Rails Integration generators list, Key Constraints section). This file is read into every future session, so it must not describe stale class names.
- [ ] `CHANGELOG.md`: **add a new entry** at the top for the version this ships in, e.g. `Renamed ActiveHarness::Agent to ActiveHarness::Request (breaking).` Do not touch existing entries.

## Phase 8 — Verification sweep

- [ ] `grep -rin "agent" lib/ | grep -v "AllRequestsFailed\|user.agent\|User-Agent"` — expect zero remaining hits describing the renamed class (should surface only truly unrelated matches, if any).
- [ ] `grep -rli "agent" docs/ README.md CHANGELOG.md CLAUDE.md` — confirm only `CHANGELOG.md` (old entries) and the new future-`Agent` placeholders (if any) remain.
- [ ] `ruby -Ilib -e "require 'active_harness'; ActiveHarness::Request"` — loads without `NameError`.
- [ ] Manually re-run the rewritten `docs/requests/examples/001_basic_agent.md` (basic call) and `002_fallback_chain_basic.md` (fallback chain) snippets in a console against a real/mock provider to confirm the renamed class still behaves identically (per `CLAUDE.md`, there's no automated test suite in this repo).
- [ ] Confirm `rails g active_harness:request NAME` (post-rename generator name) produces a file under `app/ai/requests/` subclassing `ActiveHarness::Request`.
- [ ] Confirm `rails g active_harness:install` produces `app/ai/requests/support_request.rb` and `support_guard_request.rb`, and that the generated `ai_controller.rb`, `support_pipeline.rb`, `support_guard_tribunal.rb` reference the new class names correctly together.
- [ ] Bump version with `make up/minor` per the decision in "Decisions needed before starting".
