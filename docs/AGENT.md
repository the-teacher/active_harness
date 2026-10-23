# Agent (design, v1)

> Status: **first iteration implemented** (`lib/active_harness/agent.rb`, `agent/state.rb`, `tool.rb`; tests in `test/`). This document is the design of record; it builds on [TOOLS.md](TOOLS.md). What is deliberately **not** there yet is listed in section 14 ("Not in v1"). Runnable example: `rails7-startkit/__RailsApp__/script/agent_demo.rb` (`offline` mode needs no API key).

## 1. Idea

**Agent = lifecycle + state + execution loop.**

```text
User input
   │
   ▼
Setup (optional Pipeline) ───► Goal + initial State
                                    │
                                    ▼
                            Execution loop
                       ┌──────────────────────┐
                       │ Context (from State) │
                       │ Request → LLM        │
                       │ Tools → observations │
                       │ Update State         │
                       │ Goal / Limits        │
                       └──────────┬───────────┘
                                  ▼
                       Finalize (optional Pipeline)
                                  ▼
                            Agent Result
```

| Piece | Does | Exists |
| --- | --- | --- |
| `Request` | one logical LLM call: model chain, retry, fallback, hooks, usage. **No agent loop inside** | yes (`input` may be a message Array; takes `tools:`) |
| `Tool` | one controlled action behind named steps and checks, default deny | [TOOLS.md](TOOLS.md) |
| `Pipeline` | prepares the goal (`setup`) and/or shapes the output (`finalize`) | yes |
| `Tribunal` | several requests → consensus verdict (can be a goal check) | yes |
| `GoalCheck` | decides whether enough was done; **not** the model's own opinion | new |
| `AgentState` | trustworthy data of one run; the source of truth | new |
| `ContextBuilder` | builds the messages for a particular model from `AgentState` | new |
| **`Agent`** | declares lifecycle, allowed requests/tools and limits, runs the loop | new |

An agent owns almost no logic. It declares **which requests it may call**, **which tools it may use**, **when to stop**, and runs the loop. Everything risky stays inside tools; everything model-related stays inside requests.

**v1 goal:** a simple tool-calling agent by default + extension points `setup`, `goal`, `finalize`, `context_builder`. A configurable inner loop is a later extension, not part of the MVP.

## 2. DSL

### 2.1 Short default agent

```ruby
class SearchAgent < ActiveHarness::Agent
  max_turns 10
  max_cost  0.50

  request SearchRequest
  tools   WebSearchTool, FetchPageTool
end

result = SearchAgent.call(input: "Find 5 Ruby frameworks")
```

By default the LLM receives the tool schemas, picks tools and arguments itself; the Agent validates the calls, runs the allowed ones, stores the results in the history and calls the Request again. A final answer without `tool_calls` ends the run. That means **"finished by answer"** (`stop_reason: :final_answer`), not "goal proven".

### 2.2 Setup + goal

```ruby
class ResearchSetup < ActiveHarness::Pipeline
  step :validate, InputValidationRequest
  step :plan,     BuildPlanRequest
end

class ResearchAgent < ActiveHarness::Agent
  max_turns 20
  max_cost  1.00

  request ResearchRequest
  tools   WebSearchTool, FetchPageTool
  setup   ResearchSetup
  goal    ResearchGoalCheck
end
```

`setup` returns a structured `Goal` (or a refusal / request for clarification). The plan is optional and mutable; the goal and success criteria are separate data.

### 2.3 Full lifecycle

```ruby
class CodeAuditAgent < ActiveHarness::Agent
  max_turns 30
  max_cost  2.00
  max_tool_calls 50

  request  AuditRequest
  tools    ReadFileTool, SearchCodeTool, RunTestsTool
  setup    AuditSetupPipeline
  goal     AuditGoalCheck
  finalize AuditReportPipeline
end
```

`finalize` runs on success, on a limit stop and on error; it receives the state and the outcome. A failure in finalization must not erase the primary stop reason.

### 2.4 Replanning (later)

```ruby
class DevelopmentAgent < ActiveHarness::Agent
  max_turns 50
  max_cost  5.00

  request DevelopmentRequest
  tools   ReadFileTool, EditFileTool, RunTestsTool
  setup   PlanningPipeline
  goal    TestsPassedCheck
  replan  ReplanningPipeline
end
```

A goal check returns `ActiveHarness::GoalCheckResult.new(status: :replan, feedback: "Tests failed", evidence: { failed: 2 })`. In v1 `:replan` is handled by an optional hook; the `replan` DSL is convenient but does not block the MVP. A model *asking* to replan is not the same as a *proven* failure.

### 2.5 Several Requests

```ruby
class BudgetAgent < ActiveHarness::Agent
  max_turns 12
  max_cost  0.75

  request DefaultRequest
  request :cheap,   CheapRequest
  request :compact, CompactHistoryRequest
  tools   SearchTool

  request_for { |turn| turn.number > 4 ? :cheap : :default }
end
```

A bare `request X` is the `:default` one; `request :name, X` registers a named one. `request_for` picks the Request **between turns**. Retry/fallback of models inside one Request is the Request's job, never a re-run of the agent iteration.

### 2.6 Context and resume (after MVP)

```ruby
class LongRunningAgent < ActiveHarness::Agent
  max_turns 100
  max_cost  10.00

  request MainRequest
  tools   SearchTool, ReadFileTool
  setup   TaskSetupPipeline

  context_builder AgentContextBuilder
  checkpoint SqliteCheckpointStore       # later
end

result = LongRunningAgent.call(input: "Analyze repository")
result = LongRunningAgent.resume(run_id: result.run_id)   # later, NOT a contract in v1
```

v1 makes `AgentState` serializable; `checkpoint` / `resume` come in the next iteration.

### 2.7 Explicit loop DSL (not MVP)

`loop do … end` and `loop ActiveHarness::Loops::ToolCalling do … end` are **postponed**: they complicate step contracts, transitions and nested limits. v1 has an implicit standard loop; its internal steps are already **named** (section 5) so the DSL can be added later without renaming.

## 3. DSL reference

| DSL | Purpose | Priority |
| --- | --- | --- |
| `request SomeRequest` / `request :name, SomeRequest` | default / named Request | MVP |
| `tools ToolA, ToolB` | allowed tool registry (default deny) | MVP |
| `max_turns N` / `max_cost USD` / `max_tool_calls N` | hard limits | MVP |
| `request_for { \|turn\| … }` | Request for the next turn | MVP |
| `goal GoalCheck` | check that the goal is reached | MVP |
| `loop_guard(times: 3)` | stop when the same tool calls with the same input repeat `times` turns in a row | MVP |
| `stop_if(:name) { \|turn\| … }` | custom stop rule | MVP |
| `on(:event) { … }` | hooks (section 7) | MVP |
| `setup SomePipeline` | validation, goal building | MVP |
| `finalize SomePipeline` | shape the outcome | MVP |
| `context_builder SomeBuilder` | LLM context from run state | MVP |
| `max_goal_retries N` | cap on `goal` → `:continue` rounds (default **2**) | MVP |
| `max_tool_errors N` | cap on consecutive unexpected tool `:error`s (default **3**) | MVP |
| `max_denials N` | cap on refused tool calls per run (default **5**) → `:too_many_denials` | MVP |
| `replan SomePipeline` | replanning | later |
| `checkpoint SomeStore` | persist state | later |
| `loop do … end` / `loop LoopClass do … end` | override loop phases / engine | later |

`setup`, `goal`, `finalize`, `context_builder` are optional. `goal` **checks** a result; **building** a goal belongs to `setup`.

## 4. Data contracts

Ruby 2.6+ compatibility is required for the gem, so these are `Struct`s (`keyword_init: true`), like `Result` / `ToolResult`. They live in the `ActiveHarness` namespace: `ActiveHarness::Goal`, `ActiveHarness::GoalCheckResult`, `ActiveHarness::AgentState`, `ActiveHarness::AgentTurn`, `ActiveHarness::ToolCall`.

```ruby
Goal = Struct.new(:task, :constraints, :success_criteria, :plan, keyword_init: true)

ActiveHarness::Goal.new(
  task: "Find five Ruby frameworks",
  constraints: { read_only: true },
  success_criteria: { framework_count: 5, sources_required: true },
  plan: nil
)
```

`Goal` is intent + verification criteria; `plan` changes independently of the task. Without `setup`, the runtime builds a minimal `Goal` from `input` (no extra LLM call).

```ruby
AgentState = Struct.new(
  :run_id, :status, :input, :goal, :plan,
  :messages, :events, :artifacts,
  :turn, :tool_calls_count, :usage, :stop_reason,
  keyword_init: true
)
```

`messages` — normalized messages for the LLM. `events` — the full journal of turns, denials, tool calls and results. **The journal is never replaced by a summary.** `ContextBuilder` may build a shortened context from trustworthy data but never rewrites the primary history. Compact context is a *view* of the state, not the source of truth.

```ruby
GoalCheckResult = Struct.new(:status, :feedback, :evidence, keyword_init: true)
# status: :achieved | :continue | :replan | :needs_input | :failed
```

`goal` gets the candidate answer, the `Goal` and the `State`. It runs when the model proposed a final answer (not on every tool call). It may be a Request, a Tribunal, a lambda or a deterministic check (tests, schemas) — prefer deterministic checks to LLM grading when possible. Without `goal`, a final answer means `stop_reason: :final_answer`.

```ruby
result = SearchAgent.call(input: "Find 5 Ruby frameworks")

result.status          # :done | :stopped | :failed | :paused (later)
result.stop_reason     # :final_answer | :goal_reached | :max_turns | ...
result.output          # always a String (the final answer); if the last Request has `format :json`, the parsed value is in result.processed
result.usage           # tokens + cost summed over all Requests
result.execution_time
result.turns           # typed turn summaries (trace)
result.run_id          # needed for resume (later)
```

### Setup and finalize data flow (first iteration)

`Pipeline` is not changed; data goes through its existing mechanisms:

- **`setup`:** `ResearchSetup.new(input: input, context: { … }).call`. The **last step's** `result.processed` is the goal: a Hash `{ task:, constraints:, success_criteria:, plan: }` (string or symbol keys) or just a String (the rewritten task). The agent builds a `Goal` from it and requires a non-empty `task`; the task becomes the first user message. If a step stopped the pipeline (`stop_if`: invalid input, clarification needed) or the Hash is invalid → `status: :stopped`, `stop_reason: :setup_rejected`, with the pipeline's refusal text as output.
- **`finalize`:** `AuditReportPipeline.call(input: final_answer, context: { state: state, status: …, stop_reason: … })`. Steps read the outcome from `context` (as they read `context[step_name]` today). `pipeline.output` becomes `result.output`. If finalization fails, the original `output` and `stop_reason` are kept and the finalize error goes to the trace.

> First iteration: the formats are deliberately simple and will be revisited after real use.

Messages between the Agent and any `Request` use one normalized shape (providers map it to their native format, including fallback between providers):

```ruby
{ role: :user,      content: "…" }
{ role: :assistant, content: "…", tool_calls: [{ id: "call_1", name: "os__ls", arguments: { path: "…" } }] }
{ role: :tool,      tool_call_id: "call_1", name: "os__ls", content: "…" }
```

The agent's result extends the common `Result` contract (`Class.call(input:, context:, …) → Result`) rather than introducing an incompatible type, so an agent can be a step in a `Pipeline`.

### Goal checks (`app/ai/goals/`)

A goal check is a subclass of `ActiveHarness::GoalCheck` that overrides `call(candidate:, goal:, state:)` and returns a `GoalCheckResult`. The base class implements only `call`, which raises `NotImplementedError` naming the class — so a forgotten method fails loudly instead of as an obscure `NoMethodError` mid-run. In Rails such classes live in `app/ai/goals/` (`rails g active_harness:goal NAME`; no registration needed). The base class is optional: `goal` also accepts any object with that `call`, or a block `goal { |candidate, goal, state| … }`. To use a `Request` or `Tribunal` as the judge, wrap it in a goal class (see the last example).

**Deterministic check** — the preferred kind:

```ruby
# app/ai/goals/tests_passed_goal.rb
class TestsPassedGoal < ActiveHarness::GoalCheck
  def call(candidate:, goal:, state:)
    output, ok = run_tests(goal.constraints[:test_command] || "bin/rails test")

    if ok
      ActiveHarness::GoalCheckResult.new(status: :achieved, evidence: { output: output.last(500) })
    else
      ActiveHarness::GoalCheckResult.new(
        status: :continue,
        feedback: "Tests are failing. Fix them and try again.",
        evidence: { output: output.last(500) }
      )
    end
  end
end
```

**Check against the `Goal` criteria:**

```ruby
# app/ai/goals/frameworks_found_goal.rb
class FrameworksFoundGoal < ActiveHarness::GoalCheck
  def call(candidate:, goal:, state:)
    wanted = goal.success_criteria[:framework_count]
    found  = candidate.scan(/^\d+\./).size

    return ActiveHarness::GoalCheckResult.new(status: :achieved) if found >= wanted
    ActiveHarness::GoalCheckResult.new(status: :continue, feedback: "Found #{found} of #{wanted}. Add more.")
  end
end
```

**Semantic check by LLM or Tribunal** — the Request / Tribunal itself stays in `app/ai/requests/` or `app/ai/tribunals/`; a goal class is only needed to turn its verdict into a `GoalCheckResult`:

```ruby
# app/ai/goals/answer_quality_goal.rb
class AnswerQualityGoal < ActiveHarness::GoalCheck
  def call(candidate:, goal:, state:)
    if AnswerQualityTribunal.call(input: candidate).verdict
      ActiveHarness::GoalCheckResult.new(status: :achieved)
    else
      ActiveHarness::GoalCheckResult.new(status: :continue, feedback: "Answer is incomplete")
    end
  end
end
```

```ruby
class DevelopmentAgent < ActiveHarness::Agent
  max_turns 30

  request DevelopmentRequest
  tools   ReadFileTool, EditFileTool, RunTestsTool
  goal    TestsPassedGoal
end
```

Rules: stateless (everything comes through the arguments); no side effects in the check itself — running tests is the exception, but prefer a tool and read its result from `state`; prefer deterministic checks to LLM grading (invariant 8). `Goal` (data built by `setup`) and `GoalCheckResult` (data returned by a check) are plain structs, not user classes.

## 5. The standard loop

Each turn consists of **named steps** (same idea as `Pipeline` and `Tool` steps, so hooks and tracing are uniform):

```
turn N
  step :context   ContextBuilder: State → messages for this model
  step :llm       Request chosen by request_for → answer OR tool_calls
  step :tools     if tool_calls: registry lookup → Tool.call each → observations into State
  step :goal      if a final answer was proposed: GoalCheck (or accept as :final_answer)
  step :limits    max_turns / max_cost / max_tool_calls / loop_guard / stop_if
```

Pseudo-code of the contract (not copy-paste code):

```ruby
def run(input:, context: {})
  state = initialize_state(input: input, context: context)       # exists even for early errors
  state = run_setup(state) if setup_configured?

  until finished?(state)
    enforce_limits_before_request!(state)
    messages = context_builder.call(state: state)
    response = selected_request(state).call(messages: messages, tools: allowed_tool_schemas, context: context)
    state = record_llm_response(state, response)
    enforce_limits_after_request!(state)          # over the limit → no new tools are started

    if response.tool_calls.any?
      response.tool_calls.each do |call|
        enforce_tool_limits!(state)
        state = record_tool_result(state, call, execute_registered_tool(call, context: context))
      end
      state = evaluate_loop_guards(state)
      next
    end

    state = apply_goal_decision(state, check_goal_or_accept_answer(state, response))
  end

  finalize_and_build_result(state)
rescue StandardError => error
  finalize_and_build_failure(state, error)        # finalize runs on every exit path
end
```

| After `:llm` | `goal` declared? | Result |
| --- | --- | --- |
| tool_calls present | — | run `:tools`, next turn (goal is not asked: the model is not done) |
| no tool_calls | no | stop, `:final_answer` |
| no tool_calls | yes, `:achieved` | stop, `:goal_reached` |
| no tool_calls | yes, `:continue` | feedback goes to the model, next turn (up to `max_goal_retries`, then `:goal_failed`) |
| no tool_calls | yes, `:replan` | `replan` handler, or feedback as for `:continue` |
| no tool_calls | yes, `:needs_input` | v1: stop `:stopped` / `:needs_input` (not a success); later pause/resume |
| no tool_calls | yes, `:failed` | stop, `:goal_failed` |
| any | — | `:limits` may stop at the end of any turn |

### One tool call

1. Look the name up in the registry (`os__ls` → `LsTool`). **Unknown or invalid → never executed**; a refusal goes back to the model, the loop continues.
2. `tool.call(input: arguments, context: context)` — the tool's own steps, checks and hooks ([TOOLS.md](TOOLS.md)).
3. The result becomes a `tool` message **bound to the original call id**: `output` on success, the **safe** `failed_step.message` on denial, and on an unexpected error the generic text *"tool failed, try another approach or finish"* (or *"result unknown, verify before retrying"* when the tool reports an unknown outcome). Internals (`detail`) stay in the trace only. **A tool failure never stops the agent by itself** — the model decides whether to try another tool or to finish; the agent only counts denials and errors (`:too_many_denials`, `:too_many_tool_errors`).
4. The full `ToolResult` (with `steps`, `failed_step`, `detail`) is kept in the journal.

### Example trace

```text
turn 1 → Request → tool_call web::search(query="Ruby web frameworks")
       → Tool.call → URLs
turn 2 → Request → tool_call web::fetch(url="https://rubyonrails.org")
       → Tool.call → page text
turn 3 → Request → final answer (no tool_calls)
       → GoalCheck (if configured) → :achieved
       → Finalize → Result(:done, :goal_reached)
```

## 6. Who decides what

| Question | Owner |
| --- | --- |
| Which tool and with which arguments? | **LLM** (within the schemas it was given) |
| Is the chosen tool allowed to run? | **Agent registry + Tool policies** |
| Which model; retry/fallback? | **Request** |
| Which Request on the next turn? | **Agent / `request_for`** |
| What history goes to the model? | **ContextBuilder** |
| When to stop? | **GoalCheck + hard limits / default final answer** |
| What happens after exit? | **Finalize Pipeline** |

Every tool call is validated and passes policies **at execution time**; the LLM is never a source of permissions. Tool output (web pages, files) is untrusted input, including prompt-injection risk. Do not let a read tool's output authorize a write tool.

## 7. Hooks, events, tracing

Hooks use the same style as `Pipeline` / `Tool` (`on`, `before` / `after` aliases, `instance_exec` on the agent, per-name form `on :before_tool, "os::rm"`).

| Hook | Block args | Use |
| --- | --- | --- |
| `:before_setup` / `:after_setup` | `\|state\|` | inspect the goal |
| `:before_turn` / `:after_turn` | `\|turn\|` | log, adjust limits |
| `:before_step` / `:after_step` | `\|step_name, turn\|` | any of `:context :llm :tools :goal :limits` |
| `:before_llm` / `:after_llm` | `\|turn, request\|` | tweak the request, inspect usage |
| `:before_tool` | `\|call\|` | audit, extra policy, `deny!` |
| `:after_tool` | `\|call, result\|` | log, post-process `result.output` |
| `:tool_denied` | `\|call, result\|` | alert on repeated refusals |
| `:stopped` | `\|reason\|` | a limit, `goal_failed` or `stop_if` fired |
| `:replan` | `\|verdict\|` | a goal check returned `:replan` (the loop then continues like `:continue`) |
| `:before_finalize` / `:complete` | `\|state\|` / `\|result\|` | always, at the end |

`stream:` gets `:agent` as a new source next to `:request` / `:tribunal` / `:pipeline`. Every hook is also a stream event with the same name and arguments: `[:agent, :before_turn, turn]`, `[:agent, :before_tool, call]`, `[:agent, :after_tool, call, result]`, `[:agent, :stopped, reason]`, `[:agent, :complete, result]`; the usual `:request` events flow through from the Requests inside. With `tools:` present, providers answer non-streaming (`token:` is not used for those calls).

Tracking is one chain at every level: **agent turn → step → request result / tool call → tool steps**.

```ruby
result.turns.each do |turn|
  turn.number; turn.request_name; turn.request        # Request instance (result, usage, attempts)
  turn.tool_calls.each { |c| c.id; c.tool.full_name; c.input; c.result }  # ToolResult
  turn.steps      # [{ name: :context, status:, ms: }, { name: :llm, … }, :tools, :goal, :limits]
  turn.verdict    # GoalCheckResult or nil
end
agent.tool_calls; agent.denied_calls
```

```text
turn 1  llm(default) gpt-4.1-mini  412 tok  $0.0004  820ms
        tool os::ls {path: "/srv/app/workspace"}       ok
        tool os::ls {path: ".../.git"}                 denied at no_hidden_dirs
turn 2  llm(default) gpt-4.1-mini  655 tok  $0.0006  1100ms
        answer: "The biggest file is ..."
stop    final_answer   2 turns, 2 tool calls (1 denied), $0.0010
```

## 8. Invariants

1. **One Request = one logical LLM call**, even with retry/fallback. The Agent never re-runs tool calls because a Request failed.
2. **Tool calls are structured messages**: unique id, name, validated arguments, status, result. A tool result message is bound to its call id.
3. **Model fallback:** one normalized context adapted to the provider schema; unfinished tool calls are not lost.
4. **The full event journal is separate from the bounded model context.** Summarization never destroys source data.
5. **Limits** are checked before an expensive operation and after the results are counted. `max_cost` is a hard stop for *new* steps, not a guarantee the current call stays within budget.
6. **Safety:** default deny; schema and arguments validated; external actions have timeouts, size caps, SSRF/path protection per Tool policy.
7. **No automatic repeats of side effects.** Write-tools are idempotent or verify the outcome; unknown outcome → no unconditional retry.
8. **GoalCheck ≠ the LLM's self-assessment.** Prefer tests, schemas and deterministic checks.
9. **Finalize** receives `status`, `stop_reason` and state, runs on every kind of exit, and never hides the original error.
10. **No breaking changes:** `Request.call(input: "...")` stays valid; an Array `input:` and `tools:` are additive.

## 9. Completion and failure

| Event | status | stop_reason | Next |
| --- | --- | --- | --- |
| Final answer, no `goal` | `:done` | `:final_answer` | finalize |
| Goal check succeeded | `:done` | `:goal_reached` | finalize |
| Goal check says continue | `:running` | — | feedback → next turn |
| Goal check says replan | `:running` | — | replan handler or feedback |
| User input needed | `:stopped` (v1) | `:needs_input` | finalize; pause/resume later |
| Goal check failed / retries exhausted | `:stopped` | `:goal_failed` | finalize |
| Turn / cost / tool-call limit | `:stopped` | the limit | finalize |
| Repeating calls | `:stopped` | `:repeating` | finalize |
| Unexpected tool error | continue (model decides) | `:too_many_tool_errors` at `max_tool_errors` | model gets "tool failed, try another approach or finish" |
| `setup` rejected the input (pipeline stopped / invalid goal) | `:stopped` | `:setup_rejected` | finalize |
| Providers exhausted, runtime error | `:failed` | `:request_error` / `:runtime_error` | finalize |
| Tool denied by policy | continue, or stop by guard | `:too_many_denials` at the limit | give the model the **safe** denial text |

The model never sees internal policy details of a denial.

## 10. Changes to existing components

**Request** — status: a message Array as `input:` and `tools:` are **already implemented** (`request.rb`, `request/providers.rb`): conversation mode, `Result#tool_calls`, `Result#message`, retry/fallback, usage/cost, streaming and hooks work as before; string `input:` is unchanged.

**Implemented: `input` is a String *or* an Array of messages** (one input everywhere; there is **no** separate `messages:` keyword — the interface stays small). A string is shorthand for `[{ role: :user, content: "..." }]`:

```ruby
Request.call(input: "Find Ruby frameworks")
Request.call(input: [{ role: :user, content: "Find Ruby frameworks" }, ...],
             tools: [WebSearchTool.to_schema, FetchPageTool.to_schema])
```

- `result.input` echoes what was passed; `result.output` is still a String.
- `normalize_input!` must skip an Array (or normalize only the `content` of user messages). Transcription and image modes reject an Array with a clear error.
- The Request's own `system_prompt` goes first unless the conversation has its own `system` message.
- **Prompt classes** get text helpers, so they never depend on the shape of `@input`:

| Helper | Returns |
| --- | --- |
| `input_text` | text of the **last user message** (for a String input: the string itself) |
| `input_text(roles: [:user])` | all user messages joined with a blank line |
| `transcript` | role-labelled history: `user: ...` / `assistant: ...` / `tool(os::ls): ...` |

**Soft warning, nothing breaks.** If a prompt reads `@input` / `input_text` while the input is an Array with more than one message, the Request takes the last user message and reports it once per call: *"only the last user message was taken from a multi-message input — make sure that is what this prompt needs (use `transcript` for the full history)"*. It is delivered as a stream event `[:request, :warning, message]`, as the hook `on :warning do |message|`, and appended to `result.warnings` (an Array, empty by default); the call proceeds normally. Detection point: the warning is raised where a *dynamic* prompt (Class / lambda / object) or a custom LLM backend consumes the text of the input — a static String `system_prompt` never reads it. Prompt classes also get `@transcript`; lambdas can call `input_text` / `transcript`.

## 11. Implementation plan

**Stage A — minimal agent**
- [x] Array `input`, `tools`, `tool_calls` in Request / Result.
- [x] Tool registry, name/argument validation, execution with default deny.
- [x] `AgentState` and a normalized event journal.
- [x] Standard tool-calling loop: Request → Tools → State → stop/continue.
- [x] `request`, `tools`, `max_turns`, `max_cost`, `max_tool_calls`, `request_for`.
- [x] Default final answer, aggregated `Result`.
- [x] Hooks, tracing, `loop_guard`, `stop_if`.

**Stage B — v1 lifecycle**
- [x] `setup Pipeline` + structured `Goal` (plan optional).
- [x] `goal` with `achieved / continue / replan / needs_input / failed`.
- [x] `finalize Pipeline` on all exit paths.
- [x] `context_builder` (full history by default, configurable compaction).
- [x] Limit checks before/after Request and before each Tool.
- [x] `rails g active_harness:install` templates: example `agents/`, `tools/`, `goals/` (like `support_prompt.rb`).
- [x] Tests: no tools, tool series, denied tool, fallback, rejected goal, limit exceeded, finalize on failure, prompt injection, tool errors.

**Postponed:** public `loop do`, `checkpoint` / `resume`, long pauses and human approval, sub-agents, parallel tool calls, advanced replanning.

## 12. Acceptance criteria

1. `SearchAgent` (2.1) performs at least two sequential tool calls and returns an aggregated `Result`.
2. Request fallback neither erases history nor duplicates executed tools.
3. Unregistered / invalid tools are **never** executed; the refusal is observable and safely reported to the model.
4. `max_turns`, `max_tool_calls`, `max_cost`, `loop_guard` stop execution; the reason is recorded.
5. `goal` can reject a final answer and send the agent into another turn; infinite continuation is impossible.
6. `setup` and `finalize` follow the normal executor contract; `finalize` runs for stopped and failed.
7. Turns, tools, denials, models, usage and durations appear in one trace.
8. Existing `Request.call(input:)` and Pipelines work unchanged.

## 13. Later: ideas that fall out of the pieces

- **Tribunal as a gate.** A risky call needs consensus before it runs:
  ```ruby
  on :before_tool, "os::rm" do |call|
    verdict = SafetyTribunal.call(input: "Allow #{call.tool.full_name} #{call.input}?").verdict
    deny!("rejected by tribunal") unless verdict == "yes"
  end
  ```
- **Agent as a Pipeline step.** `use FileAgent` — its `output` becomes the payload, `stop_if` and `context[step_name]` work as today.
- **Agent as a Tool** (sub-agents with a restricted toolset; the parent sees only the `ToolResult`).
- **Memory.** Inside a run the State is the history; across runs `memory:` is passed explicitly, never auto-injected.
- **Dry run.** `FileAgent.call(input:, dry_run: true)` — tools run up to `perform` (not including it); good for testing policies.
- **Per-turn model switching** via `request_for` + fallback inside each Request.

## 14. Decisions

> First iteration: decisions are the most likely ones and consistent with the rest of the system. Revisit after real use.

**Principles:** the public path is `request + tools + limits`, the rest is optional; a hidden standard loop (the LLM picks actions, the runtime owns safety and stopping); `setup` builds the Goal, `goal` checks, `finalize` shapes the outcome; State belongs to the Agent, models to the Request, effects to the Tool; `Struct` (not `Data`) for Ruby 2.6+; the DSL mirrors `Request` / `Pipeline` / `Tool` (`on`, `before` / `after`, class-level declarations, `instance_exec` blocks).

| Topic | Decision |
| --- | --- |
| `ToolResult` vs `Result` | separate types; shared only `status`, `execution_time`/`ms`, `input` |
| Tool failure | never stops the agent; the model decides; capped by `max_tool_errors` (3) and `:too_many_denials` |
| Unknown side-effect outcome | tool calls `unknown_outcome!`; model is told to verify; no auto-retry |
| `max_goal_retries` | 2, then `:goal_failed` |
| `setup` / `finalize` data | goal as Hash in `processed` → `Goal`; outcome via `context` (section 4) |
| `:needs_input` | `status: :stopped`, `stop_reason: :needs_input`; pause/resume later |
| Budget (`max_cost`) | checked before each Request and Tool from accumulated `usage`; no reservation; hard stop for *new* steps only |
| Provider tool messages | one normalized message shape (section 4); providers map to/from native format |
| Parallel tools / crash recovery | sequential only in v1; recovery arrives with `checkpoint` / `resume` later |
| `request X` vs `request :default, X` | bare form = `:default`; both are valid |
| `result.output` | always a String; parsed JSON of the last Request is in `result.processed` (same as `Request`) |
| History compaction | explicit only (`context_builder` or a hook); never automatic in v1; `request :compact` reserved |
| Tool wire names | `scope__name` on the wire, `scope::name` in code, traces and per-name hooks |
| Rails layout | `app/ai/agents/`, `app/ai/tools/`, `app/ai/goals/` (goal checks: subclasses of `ActiveHarness::GoalCheck`); generators `rails g active_harness:agent NAME` and `:tool NAME` |

**Behaviour notes (as implemented):** `Agent.call` returns the agent (like `Request.call`); run-time failures never raise — see `status`, `stop_reason`, `error`. A `goal` may be a block `{ |candidate, goal, state| }` or an object/class with `call(candidate:, goal:, state:)`; returning `true` / `false` / a Hash is accepted too. `result` (Result-compatible) is what makes an agent usable as a `Pipeline` step. Tool arguments are validated by the agent (`Tool.validate_input`: required, unknown, enum) before a tool runs; the same registry maps wire names (`os__ls`) back to tool classes. Providers with tool calling today: OpenAI-compatible ones (OpenAI, OpenRouter, Groq, xAI, DeepSeek, Mistral, Ollama, Ollama Cloud, GPUStack, Hetzner) and Anthropic; others are skipped by the model chain with an `InvalidRequestError`.

**Not in v1:** `loop do`, `checkpoint` / `resume`, human approval, sub-agents, parallel tool calls, Tribunal as a gate (section 13).

## 15. Planned improvements

The agent should reuse the existing composition (`Request`, `Tribunal`, `Pipeline`), not grow a parallel execution system. `setup`, `goal` and `finalize` stay **optional**, so both of these stay valid:

```ruby
class SimpleAgent < ActiveHarness::Agent
  request MainRequest
  tools   SearchTool
end

class AdvancedAgent < ActiveHarness::Agent
  request  MainRequest
  tools    SearchTool, ReadFileTool
  setup    PreparationPipeline
  goal     VerificationTribunal
  finalize ReportPipeline
end
```

Shape of a full agent: `Setup (Pipeline) → Loop (Request → Tool → State → Goal) → Finalize (Pipeline)`.

| Planned | Why | Example |
| --- | --- | --- |
| `setup` takes a Pipeline **or a compatible executor** (Request, Tribunal) | task preparation without a one-step Pipeline | `setup InjectionGuardRequest` |
| `goal` takes a Request, a **Tribunal** or a lambda directly | independent check instead of trusting the main LLM | `goal AuditValidationTribunal` |
| Tribunal → `GoalCheckResult` adapter | a plain verdict does not drive the loop; it must map to `:achieved` / `:continue` (+ feedback) | `unanimous → :achieved`, otherwise `:continue` with the dissenting reasons as `feedback` |
| `finalize` takes a Pipeline or a compatible executor | shape the result | `finalize ReviewReportPipeline` |
| One `AgentState` / hooks / `Result` across nested executors | end-to-end trace and cost | see "Discrepancies" below |
| Agent usable as a `Pipeline` step | composition | `step :audit do use AuditAgent end` |
| `input` as String **or** message Array; `input_text` / `transcript` helpers + soft warning | one input shape across all entities; conversations without a separate `messages:` keyword | section 10 |
| Contracts to verify next | before building more on top | `AgentState`, `GoalCheckResult`, propagation of events, errors and cost between nested executors |

Goal check with a Tribunal (target form):

```ruby
class AuditAgent < ActiveHarness::Agent
  max_turns 30

  request AuditRequest
  tools   ReadFileTool, RunTestsTool
  setup   AuditSetupPipeline
  goal    AuditValidationTribunal      # adapter turns the verdict into :achieved / :continue
end
```

### Discrepancies found (code vs. these ideas) — resolved

All five were implemented and are covered by `test/agent_composition_test.rb` and `test/input_test.rb`.

1. **Tribunal / Request as `goal`** — fixed. `goal SomeTribunal` and `goal SomeRequest` work directly. Tribunal verdict `true` → `:achieved`; `false`/`nil` → `:continue` with the reasons of the answers that did not approve as `feedback` (`reason` / `feedback` key of `processed`, else the output); a `GoalCheckResult` or a Hash with `status` is used as is. A Request judge answers with a Hash (`{"status": "achieved", "feedback": "..."}`) or text starting with `yes` / `true` / `achieved` / `done`. Other classes (`GoalCheck` subclasses) keep the `call(candidate:, goal:, state:)` contract.
2. **Nested cost** — fixed. `setup`, `finalize` and goal checks (Pipeline steps, every member Request of a Tribunal, nested pipelines) are added to `agent.usage` and journaled as `:nested_usage` events, so `max_cost` counts them.
3. **`setup` / `finalize` with a bare Request or Tribunal** — fixed: wrapped into an implicit one-step Pipeline (`step :run`).
4. **Failures visible from outside** — fixed.
   - `agent.finalize_error` and the hook `on :finalize_error do |error|`.
   - `agent.result.meta` → `{ status:, stop_reason:, run_id: }`, so a Pipeline step can tell a stopped agent from a successful one (`stop_if ->(r) { r.meta[:status] != :done }`).
   - `finalize` gets the last Request's `processed` in `context[:processed]` (plus `state`, `status`, `stop_reason`).
5. **`on_agent_event`** — added to `Pipeline` next to `on_request_event` / `on_tribunal_event` / `on_pipeline_event`.

Verification: the suite (`ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require "./#{f}" }'`) passes — 77 runs, 0 failures. It was run here with a throw-away synchronous stand-in for `concurrent-ruby` outside the repo (the gem is not installed in this environment); run it once with the real gem too.
