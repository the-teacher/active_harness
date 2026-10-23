# ActiveHarness — Overview

> A design-discussion document. It describes what the `active_harness` gem (v0.3.10; Tools and Agents arrived in v0.3.9 as a first iteration) does today, with small but sufficient examples of every element, and lists what is deliberately **not** there yet. Details live in the linked docs; this file is the map.

## 1. What it is and why

**ActiveHarness** is a Ruby framework (a gem, Rails-native, works in plain Ruby too) for building **reliable, observable, cost-controlled** LLM systems.

The "harness" idea: an LLM call is a non-deterministic component. Around it you build scaffolding that **directs its input, observes its output, limits its behavior, retries on failure and counts the money**. The developer writes the business logic; the framework takes the infrastructure.

**Practical facts.** Ruby >= 2.6 (the code avoids newer syntax on purpose); runtime dependencies are only `concurrent-ruby` (Tribunal) and `active_harness_pricing` (model prices); Rails is optional (Railtie, generators, SSE helpers). MIT licensed. Repository: `github.com/the-teacher/active_harness`. Docs live in `docs/`; a Rails playground app (`rails7-startkit`, run in containers) holds runnable examples.

**Naming history.** Until v0.3.0 the single-LLM-call class was called `Agent`; it was renamed to `Request` because it is one resilient call, not an autonomous entity. The name `Agent` now belongs to the tool-calling loop (3.10). Old text that says "agent" about a single call is from before the rename.

Design principles:

1. **Explicit over magic.** Memory is never injected into a prompt automatically; hooks are the single extension mechanism; there is no auto-instrumentation.
2. **Composition of uniform bricks.** Request, Tribunal, Pipeline and Agent share one contract — `Class.call(input:, context:, …)` and a `Result` — so any of them can be a step of a Pipeline.
3. **One hook and event system** on every level (`Core::HookRunner`; `on` / `before` / `after` / `callback`; blocks run via `instance_exec`; `stream:` events).
4. **Code as configuration.** Classes with a class-level DSL; prompts are plain Ruby objects; in Rails everything lives in `app/ai/…`.
5. **Default deny** for anything that touches the outside world (Tools), and **safe refusals**: the model sees only a safe message, internals stay in the trace.
6. **Cost and time are first-class.** Every `Result` carries tokens, price, duration and the attempt chain; an Agent sums them over the run.

## 2. System map

```
                    ┌──────────────────────────── Agent ────────────────────────────┐
                    │ loop: LLM → tool_calls → Tools → results back to LLM → … until │
                    │ an answer, a goal check or a limit stops it                    │
                    └───────┬─────────────────────┬───────────────────────┬──────────┘
                            │ talks to            │ runs                  │ can be
                            ▼                     ▼                       ▼
                        Request ◄──── Tribunal ── Pipeline ───────►  a step of a Pipeline
                     (one LLM call)  (N in parallel  (sequential        (setup / finalize,
                                      → verdict)      steps, stop_if)    or a normal step)

           Prompt · Memory · Result · Providers · Hooks · Stream · Pricing/Usage · Concerns (tracing)
```

| Element | Status | One-line role |
| --- | --- | --- |
| `Request` | ✅ | one resilient LLM call (model chain, retry, fallback, hooks); `input` may be a message Array and it takes `tools:` for agents |
| `Prompt` | ✅ | plain Ruby object with `#call` → system prompt string |
| `Result` | ✅ | the common result struct (now with `tool_calls` and `message`) |
| `Tribunal` | ✅ | N requests in parallel → one verdict (consensus) |
| `Pipeline` | ✅ | sequential steps (request / tribunal / lambda / nested pipeline / agent) with guards |
| `Memory` | ✅ | conversation history storage (JSON / SQLite / PostgreSQL); managed manually |
| Providers | ✅ | ~20 providers, a custom provider, a RubyLLM backend; tool calling on OpenAI-compatible ones and Anthropic |
| Hooks / Stream / Tracing | ✅ | lifecycle hooks and events for UI and logging/OpenTelemetry |
| `Tool` | ✅ first iteration | a controlled action behind named steps and checks, default deny |
| `Agent` | ✅ first iteration | the LLM ↔ Tools loop with limits, goal check, setup/finalize |
| Goal checks | ✅ first iteration | objects that judge an agent's final answer |
| Generators | ✅ | `rails g active_harness:install` and per-element generators with working examples |

---

## 3. Elements

### 3.1 Prompt

Any class with a `call` method returning a string. Before calling it, the Request injects `@input`, `@context`, `@params`, `@memory`, `@context_window`.

```ruby
class SupportPrompt
  def call
    "You are a concise assistant. User role: #{@context[:role]}. Answer in 1-2 sentences."
  end
end
```

An inline string or a lambda works as well.

### 3.2 Request — one LLM call

The unit of work: a prompt, a model chain (primary + fallbacks), an output format, hooks.

```ruby
class GreetingRequest < ActiveHarness::Request
  system_prompt GreetingPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo", retry_attempts: 2
    fallback provider: :openai,     model: "gpt-4.1-mini"
  end

  on(:retry)   { |entry, error| Rails.logger.warn("#{entry[:model]} failed: #{error.message}") }
  on(:failure) { |attempts|     Rails.logger.error("all models failed") }
end

request = GreetingRequest.call(input: "Hello!", context: { role: "admin" })
request.result.output               # "Hey there!…"
request.result.usage.cost.total     # 0.00001
request.result.model.name           # which model actually answered
```

What it does:

- **Model chain** with per-model retry and fallback; when exhausted it raises `AllModelsFailed`. The chain can be changed at runtime (`request.models.prepend / push / replace`).
- **`format :json`** parses the answer into `result.processed` (Hash/Array), strips ```` ```json ```` fences, and enables the parse hooks.
- **Streaming:** `token: ->(chunk) {}` for tokens and `stream: ->(source, event, *args) {}` for lifecycle events; SSE helpers for Rails.
- **Multimodal:** vision input, image generation (`image true`), audio transcription (`transcribe true`).
- **Cost and usage:** prices come from `models.dev` (cached 72h); tokens and cost are in every result.
- **Validation, input normalization, custom LLM backend** (HTTP delegated to `ruby_llm`), custom providers.
- **Vercel/TypeSafe (Jev):** a model that returns typed values with probabilities (`boolean` / `choice` / `score`) instead of text — fast and cheap for classification and guards (`docs/JEV.md`).
- **Agent extension (new):** `Request.call(messages: […], tools: […])` accepts a conversation instead of one input and returns `result.tool_calls`; nothing is executed there. `Request.call(input:)` is unchanged.

Request hooks: `setup, before_call, after_call, before_system_prompt, after_system_prompt, before_parse, after_parse, parse_error, retry, failure`.

### 3.3 Result — the common contract

```ruby
result.input / result.output / result.processed   # input, raw answer, parsed answer
result.model        # name, provider, temperature, context_window, pricing
result.attempts     # what was tried and why it failed
result.usage        # tokens.{input,output,total}, cost.{input,output,total}
result.execution_time
result.tool_calls   # [{ id:, name:, arguments: }] the model asked for (nil when none)
result.message      # the assistant message, ready to append to a conversation
```

Request, Tribunal, Pipeline and Agent all expose a `Result`, which is why they are interchangeable as Pipeline steps. `ToolResult` (3.8) is deliberately a different type: an LLM call and a tool call are different things.

### 3.4 Tribunal — consensus

N requests run **in parallel** (`Concurrent::Future`); the successful results are reduced to a `verdict`. Either different requests (different aspects) or one request on different models.

```ruby
class SafetyTribunal < ActiveHarness::Tribunal
  requests ToxicityRequest, AggressionRequest, SpamRequest

  verdict :majority, may_fail: 1 do |result|      # or :unanimous, or process { |results| … }
    result.processed["result"] == true
  end
end

t = SafetyTribunal.call(input: "I hate this product!")
t.verdict        # true / false
t.results        # results of each request
t.errors         # failed requests (excluded from the verdict)
```

Priority: instance `process` → class `process` → `verdict` strategy. `may_fail: N` is how many failures are tolerated. Hooks: `before_call, after_call, before_request, after_request, request_error, before_verdict, after_verdict`.

### 3.5 Pipeline — sequential steps

Steps run in order; a transform step's output becomes the next step's input.

| Step type | Changes the payload | Can stop |
| --- | :-: | :-: |
| Transform: `step :n, SomeRequest` | yes | no |
| Guard: `step :n do use …; stop_if … end` | no | yes |
| Tribunal: `step :n do use SomeTribunal; stop_if … end` | no | yes |
| Lambda: `step :n, ->(input) { Result.new(…) }` | yes | with `stop_if` |
| Nested Pipeline: `use InnerPipeline` | via `transform` | yes |
| Agent: `step :n, SomeAgent` | yes | — |

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  step :injection_guard do
    use InjectionGuardRequest                       # cheap classifier model
    stop_if ->(r) { r.processed["detected"] == true }
  end

  step :translate, TranslationRequest

  step :safety do
    use SafetyTribunal                              # consensus of several models
    stop_if ->(r) { r.processed["verdict"] == false }
  end

  step :respond, SupportRequest
end

p = SupportPipeline.new(input: "Wie geht es dir?", memory: memory)
p.call
p.stopped?      # false
p.stopped_at    # nil | :injection_guard
p.output        # final answer
p.steps         # (name, executor, result) for tracing
```

Earlier step results are available as `context[step_name]`; executors can be adjusted before `call` (`pipeline.executors[:translate].models.prepend(…)`); nesting is unlimited and events flow through every level. A pipeline records the turn into Memory after a successful run. Hooks: `before_step, after_step, stopped, complete` (plus a per-step form).

### 3.6 Memory

History storage: `Memory::JsonFile`, `Memory::Sqlite`, `Memory::Postgresql` (plus your own subclasses).

**Principle:** memory is **never** injected into the LLM messages automatically. You decide when to load, what to put into the prompt and when to record — usually with a hooks concern:

```ruby
module RequestMemory
  def self.included(base)
    base.on(:before_call)          { @memory&.load }
    base.on(:after_system_prompt)  { |prompt| "#{prompt}\n\nHistory:\n#{@memory.to_messages}" }
    base.on(:after_call)           { |result| @memory&.record(request: @input, response: result.output) }
  end
end
```

Inside an Agent run the `AgentState` is the history; between runs `memory:` is passed explicitly, exactly as for a Request.

### 3.7 Providers

One file per provider under `lib/active_harness/providers/`, all subclassing `Providers::Base`: OpenAI, Anthropic, Gemini, Groq, OpenRouter, xAI, DeepSeek, Mistral, Ollama (+ cloud), Perplexity, GPUStack, Azure, Bedrock, Vertex AI, Cohere, Hetzner, Vercel, TypeSafe, a `:custom` endpoint, and image / audio providers.

**Tool calling** is implemented on the OpenAI-compatible providers (OpenAI, OpenRouter, Groq, xAI, DeepSeek, Mistral, Ollama, Ollama Cloud, Hetzner, GPUStack — shared `Providers::ToolCalling`) and on Anthropic (`tool_use` / `tool_result` blocks). A provider without `supports_tools?` is skipped by the model chain with an `InvalidRequestError`, so a chain such as `use anthropic, fallback gemini` degrades correctly. Calls that carry `tools:` are not streamed.

### 3.8 Tool — a controlled action

**Goal:** give the model a *declared, safe* way to touch the outside world (OS, network, DB). The model never gets a shell — it can only call tools you wrote, and every call passes through your checks first. Details: `docs/TOOLS.md`.

```ruby
class LsTool < ActiveHarness::Tool
  include ActiveHarness::Tool::PathPolicy      # safe_path!: symlinks, "..", prefix check
  include ToolTracing                          # logging lives in a concern

  tool_scope :os          # full name os::ls; wire name os__ls
  tool_name  "ls"

  description "List files in a directory inside the workspace"
  param :path, "Directory to list"             # type :string, required by default; also enum:, type:

  ALLOWED_PATHS = [Rails.root.join("storage").to_s].freeze

  step :resolve_path, transform: true do |input|     # replaces the input for later steps and #perform
    input.merge(path: safe_path!(input[:path]))
  end

  step :no_hidden_dirs do |input|                    # a check: refuse with deny!
    deny!("hidden dirs are off limits") if input[:path].split("/").any? { |s| s.start_with?(".") }
  end

  def perform(input)                                 # the action; always the last step
    Dir.children(input[:path]).first(200)
  end
end

r = LsTool.call(input: { path: "/…/storage/.git" }, context: { user: current_user })
r.status               # :denied            (:ok | :denied | :error)
r.failed_step.name     # :no_hidden_dirs
r.failed_step.message  # "hidden dirs are off limits"   — safe text, goes to the model
r.failed_step.detail   # nil | internals                — traces and logs only
r.model_message        # what the agent sends back as the `tool` message
```

- **Never raises for expected failures** — a `ToolResult` with the per-step trace comes back.
- **Three outcomes for the model:** `:ok` → the output; `:denied` → the safe `deny!` text; `:error` → a generic "tool failed, try another approach or finish". `unknown_outcome!` marks a side effect that may have happened ("result unknown, verify before retrying"); such a call is never retried automatically.
- **Hooks:** `before_step`, `after_step`, `before_perform`, `after_perform` (per-step form too); they can read and replace the payload / output and may `deny!`.
- **Schema:** `param` builds `Tool.to_schema` (provider-neutral); providers map it to their wire format.
- The agent validates arguments (required / unknown / enum) before a tool runs; the tool itself receives the input as validated.

### 3.9 Goal check

"The model stopped asking for tools" does not prove the job is done. A goal check judges the final answer and can send the agent back for another turn. It is a subclass of `ActiveHarness::GoalCheck` that overrides `call(candidate:, goal:, state:)` and returns a `GoalCheckResult`; the base class only raises a clear "must define #call" error if you forget. The base class is optional — any object with that `call`, or a block, is accepted. In Rails such classes live in `app/ai/goals/`.

```ruby
class TestsPassedGoal < ActiveHarness::GoalCheck
  def call(candidate:, goal:, state:)
    output, ok = run_tests
    return ActiveHarness::GoalCheckResult.new(status: :achieved) if ok

    ActiveHarness::GoalCheckResult.new(status: :continue, feedback: "Tests are failing. Fix them.", evidence: { output: output.last(500) })
  end
end
```

Statuses: `:achieved`, `:continue` (feedback goes to the model, up to `max_goal_retries`, default 2, then `:goal_failed`), `:replan`, `:needs_input` (stops with `:needs_input` — not a success), `:failed`. Prefer deterministic checks (tests, schemas, counts) to LLM grading; a Tribunal can be wrapped in a small goal class when a semantic check is needed.

### 3.10 Agent — the loop

An Agent owns almost no logic: it declares which Requests it may call, which Tools it may use and when to stop, and runs the loop. Everything risky stays in Tools, everything model-related stays in Requests. Details: `docs/AGENT.md`.

```ruby
class FilesAgent < ActiveHarness::Agent
  max_turns 8                           # hard limits
  max_cost  0.50
  loop_guard                            # same tool calls repeating → :repeating

  include AgentTracing

  request FilesRequest                  # the model chain lives in the Request; `request :cheap, X` adds named ones
  tools   LsTool, ReadFileTool          # default deny: any other name is "unknown tool"
  goal    AnswerPresentGoal             # optional; without it the first answer without tool calls ends the run
end

agent = FilesAgent.call(input: "What is in the workspace?")
agent.status        # :done | :stopped | :failed
agent.stop_reason   # :final_answer | :goal_reached | :max_turns | :max_cost | :repeating | …
agent.output        # final answer (String)
agent.usage         # tokens and cost summed over every Request
puts agent.trace
```

```text
turn 1  llm(default) openai/gpt-4.1-mini  412 tok  $0.0004  820ms
        tool os::ls {path: "/srv/app/storage"}              ok
turn 2  llm(default) openai/gpt-4.1-mini  655 tok  $0.0006  1100ms
        tool os::ls {path: "/srv/app/storage/.git"}         denied at no_hidden_dirs: hidden dirs are off limits
turn 3  llm(default) …  answer: "The biggest file is …"
stop    goal_reached   3 turns, 2 tool calls (1 denied), $0.0010
```

**The loop.** Each turn is five named steps: `:context` (build the messages from the state) → `:llm` (one Request) → `:tools` (if the model asked for tools) → `:goal` (if it proposed a final answer) → `:limits`. Tool calls are validated against the registry and the tool's schema, run through the tool's own steps, and answered with a `tool` message bound to the call id.

**Principles.**
- A tool failure never stops the run by itself: the model gets a refusal / generic error text and decides — another tool, or finish. The agent only counts them (`max_denials` default 5 → `:too_many_denials`, `max_tool_errors` default 3 consecutive → `:too_many_tool_errors`).
- One Request is one logical LLM call; its retry/fallback never re-runs tools.
- `AgentState` (messages + a full event journal, never summarized) is the source of truth; the model-facing context is just a view built by a context builder.
- Run-time failures never raise: `status: :failed`, `stop_reason: :request_error | :runtime_error`, `agent.error`. `finalize` runs on every exit.

**Optional lifecycle.**

```ruby
class ResearchAgent < ActiveHarness::Agent
  max_turns 20

  request  ResearchRequest
  request  :cheap, CheapResearchRequest      # named Request, picked per turn by request_for
  tools    WebSearchTool, FetchPageTool
  setup    ResearchSetup        # a Pipeline: validate / plan; its last step returns the Goal ({ task:, success_criteria:, plan: } or a String)
  goal     ResearchGoalCheck
  finalize ResearchReportPipeline   # shapes the output; gets state / status / stop_reason via context; runs on every exit

  request_for { |turn| turn.number > 4 ? :cheap : :default }
  stop_if(:enough) { |turn| … }
end
```

If `setup` rejects the input the run ends with `:setup_rejected`. An agent is also a normal Pipeline step (`step :act, ResearchAgent`).

**Defaults and results.** `max_turns` 10, `max_tool_errors` 3, `max_denials` 5, `max_goal_retries` 2; `max_cost` and `max_tool_calls` are off unless set. The run's data lives in `agent.state` (`AgentState`: goal, messages, a full `events` journal, usage); each turn is an `AgentTurn` (`agent.turns`) with its tool calls (`agent.tool_calls`, `agent.denied_calls`). `agent.result` is a normal `Result`, so an agent can be a Pipeline step.

**Hooks:** `before_setup / after_setup`, `before_turn / after_turn`, `before_step / after_step` (+ `on :after_step, :goal`), `before_llm / after_llm`, `before_tool / after_tool / tool_denied` (+ `on :before_tool, "os::rm"`), `replan`, `stopped`, `before_finalize`, `complete`. Every hook is also a `stream:` event with source `:agent`.

### 3.11 Tracing as concerns

Basic tracing is **not** written into the examples. It lives in `app/ai/concerns/` and the examples `include RequestTracing` / `TribunalTracing` / `PipelineTracing` / `AgentTracing` / `ToolTracing`. All of them write through one method, `TracingLog#trace_log` (Rails.logger today); swapping it for OpenTelemetry spans, metrics or database rows changes every element at once. A class adds its own details by overriding a small method (`tracing_details(result)` on a Request). An OpenTelemetry variant is described in `docs/TRACING.md`.

### 3.12 Rails integration and generators

`rails g active_harness:install` creates a small **working example in every directory** and is safe to re-run in an existing app (per file, never overwrites, adds only missing files and missing routes):

```
app/ai/
├── concerns/    TracingLog, RequestTracing, TribunalTracing, PipelineTracing, AgentTracing, ToolTracing
├── requests/    SupportRequest, SupportGuardRequest, FilesRequest
├── prompts/     SupportPrompt, SupportGuardPrompt, FilesPrompt
├── tribunals/   SupportGuardTribunal
├── pipelines/   SupportPipeline
├── memory/      AppMemory
├── agents/      FilesAgent
├── tools/       LsTool, ReadFileTool
└── goals/       AnswerPresentGoal
```

Per-element generators: `request`, `prompt`, `tribunal`, `pipeline`, `memory`, `agent`, `tool`, `goal`. The templates carry short comments explaining *why* each DSL line exists.

---

## 4. One system, end to end: the GitHub profile assistant

A real example from the playground (`/ai/agents/github`, files under `app/ai/`). It uses every element: a guard pipeline, two agents, five tools, a goal check and tracing concerns.

```
Collect button ──► (24h freshness gate, plain code)
                    └─ stale ─► GithubCollectorAgent
                                 request GithubCollectorRequest   (tool-capable model, via OpenRouter)
                                 tools   github::fetch, github::save_note
                                 goal    GithubCollectedGoal      (profile.txt and repos.txt really exist on disk)
                                 ──► text notes in storage/github_profile/  (dir 0700, files 0600, not under public/)

Chat message ──► GithubQueryPipeline (fails closed: a guard that errors = request refused)
                  :owner_check       plain Ruby: links / @mentions of any other account stop the run
                  :injection_guard   Request  (cheap classifier, format :json)
                  :jev_guard         Request  (Jev typed probabilities: injection / other_account / off_topic; only if VERCEL_API_KEY is set)
                  :scope_guard       Request  ("is this about the owner's own profile and projects?")
                  :refine            Request  (rewrites the message into one compact question + topics, so later models read little)
                 ──► GithubChatAgent
                      tools  github::list_notes, github::read_note   (read-only, no network)
                      goal   AnswerPresentGoal
```

**Why it is shaped this way**

- **The model controls as little as possible.** `github::fetch` builds host, owner and path from constants; the model chooses only an enum (`profile | repos | repo | readme`) and a repository name that must match a strict pattern. `github::save_note` takes a file name that must match `\A[a-z0-9][a-z0-9_-]{0,60}\.txt\z` and a text; the directory is fixed. Tested: `../../users/other`, `a/b`, `..`, `../x.txt`, `../../../etc/passwd` are all refused, however the model asks.
- **Fetched text is data, not instructions.** READMEs of repositories are untrusted; the prompts say so, and the tool limits above mean that an injected instruction still cannot reach another account or another path.
- **Deterministic where possible.** The 24-hour rule and the owner check are plain code (no tokens spent); a goal check looks at files on disk instead of trusting "I saved it".
- **Expected absence is not an error.** The first real run showed this: three repositories had no README (HTTP 404), the tool reported errors, three consecutive errors hit `max_tool_errors`, and the agent stopped before saving anything. The tool now answers "(this repository has no README)" as a normal result.

A second playground pipeline (OpenAI pricing) shows the hybrid shape in its smallest form: a deterministic Playwright fetch step, then an LLM extraction step.

## 5. Status, limits and honest caveats

- **Tools and Agents are a first iteration.** They are covered by a minitest suite with a scripted LLM (`test/`: tools, agent loop, provider mapping, install generator). Provider tool-calling is verified with **mocked HTTP in the tests**; against a real API it has so far been exercised through OpenRouter (`openai/gpt-4.1-mini`) in the playground's GitHub collector. Anthropic and the other providers are not yet checked against real endpoints. Nothing has run on Ruby 2.6 yet (the code only avoids newer syntax).
- **Not in v1:** a public `loop do` DSL, `checkpoint` / `resume`, long pauses and human approval, sub-agents, parallel tool calls, automatic history compaction, a `replan` DSL (a `:replan` verdict goes through a hook and then behaves like `:continue`), streaming for calls that carry tools, tool calling on providers not listed above.
- **Known rough edges:** the install controller template is skipped when `ai_support_controller.rb` already exists, so an existing controller does not get the `files_agent` action.

## 6. Open questions for discussion

**Architecture**
1. Should the model chain adapt to tool support automatically (skip providers that cannot call tools) — it does now, via an error that is retried; is a declarative capability check better?
2. Is a single `Result` contract for executors enough, or should `ToolResult` share more of it than `status` / time / input?
3. Where should the line between a deterministic goal check and an LLM/Tribunal-based one be drawn in the DSL — keep wrapping classes, or support `goal SomeTribunal` directly?

**Agent**
4. Parallel tool calls in one turn (as in Tribunal) for tools that declare themselves independent?
5. How should history compaction work — only an explicit context builder (now), or an automatic token threshold with a `request :compact`?
6. Should `:needs_input` become a real pause with `resume`, and what is the checkpoint store?
7. Should the agent's `output` follow `format :json` of the last Request instead of always being a String (the parsed value is in `result.processed` today)?

**Tools and safety**
8. Is a human-approval outcome needed in addition to allow/deny, and where does the approval UI live?
9. How to model untrusted tool output (prompt injection): mark it "tainted" and forbid it from authorizing write tools?
10. How rich should `param` get — nested objects, arrays, or a raw JSON-schema escape hatch?

**From real use**
11. Should "expected absence" be a first-class tool outcome (not-found, empty) so it never spends the error budget, or is a normal text result enough?
12. Is a reusable *input gate* worth a name — a guard pipeline (deterministic check, injection guard, Jev, scope check, refine) placed in front of an Agent — or is it just a Pipeline by convention?
13. Freshness rules ("not more often than once a day") currently live in application code outside the agent. Should an Agent/Tool be able to declare them?

**Product**
14. Positioning: a reliability/observability layer over LLMs, or an agent framework? How does it differ from RubyLLM, LangChain or the OpenAI Agents SDK? (ActiveHarness is not trying to be an LLM client and can run on top of RubyLLM.)
15. Testing non-deterministic chains: the scripted-provider approach used in `test/` could become a public test helper — worth exposing?

## 7. Where things are

| Topic | File |
| --- | --- |
| Request | `docs/REQUESTS.md`, `docs/requests/*`, `lib/active_harness/request*` |
| Tribunal | `docs/TRIBUNALS.md`, `docs/tribunals/*` |
| Pipeline / nested | `docs/PIPELINES.md`, `docs/NESTED_PIPLINES.md`, `docs/pipelines/*` |
| Prompt / Memory | `docs/PROMPTS.md`, `docs/MEMORY.md` |
| Tracing | `docs/TRACING.md`, `lib/generators/active_harness/install/templates/concerns/` |
| Jev (typed answers) | `docs/JEV.md` |
| Tool | `docs/TOOLS.md`, `lib/active_harness/tool.rb` |
| Agent | `docs/AGENT.md`, `lib/active_harness/agent.rb` |
| Providers, configuration | `docs/common/*`, `lib/active_harness/providers/` |
| Install / generators | `docs/INSTALLATION.md`, `lib/generators/active_harness/` |
| Tests | `test/` (`ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require "./#{f}" }'`) |
| Runnable demos | `rails7-startkit/__RailsApp__/script/agent_demo.rb` (`offline` needs no API key); the GitHub assistant: `app/controllers/ai/agents_controller.rb`, `app/ai/{agents,tools,goals,pipelines}/github_*`, page `/ai/agents/github` |
| Change history | `CHANGELOG.md` |
