# Terms

The few words ActiveHarness is built from. Each one is a plain Ruby class you subclass; the bigger pieces are made of the smaller ones:

```
Prompt ─┐
        ├─► Request ─┬─► Pipeline   steps in a row
Model chain ─┘       ├─► Tribunal   several at once → one verdict
                     └─► Agent      a loop ──uses──► Tool   a safe action
```

## 1. Structure

All AI code lives in `app/ai` (in Rails it is autoloaded; in plain Ruby put the files wherever you like). One directory per kind of class:

```
app/
└── ai/
    ├── prompts/      # 2. what the model is told           support_prompt.rb
    ├── requests/     # 3. one LLM call                      support_request.rb
    ├── pipelines/    # 4. steps in a row                    support_pipeline.rb
    ├── tribunals/    # 5. parallel requests, one verdict    politeness_tribunal.rb
    ├── memory/       # 6. custom conversation storage
    ├── tools/        # 7. safe actions for a model          ls_tool.rb
    ├── agents/       # 8. loops over requests and tools     files_agent.rb
    ├── goals/        #    goal checks for agents            answer_present_goal.rb
    └── concerns/     #    shared tracing / logging
```

Generators: `rails g active_harness:install` creates the tree, `rails g active_harness:request NAME` (also `prompt`, `tribunal`, `pipeline`, `memory`, `tool`, `agent`, `goal`) adds a single class.

## 2. Prompt

**Prompt** is the instruction that tells the model who it is and how to answer: a string, or a small class whose `#call` builds it from `@input`, `@context`, `@params` and `@memory`. → [How prompts work](PROMPTS.md#how-prompts-work)

```ruby
class SupportPrompt
  def call
    "You are a concise assistant for #{@context[:product]}. Answer in 1-2 sentences."
  end
end
```

## 3. Request

**Request** is one call to an LLM: a prompt plus a chain of models (with retries and fallback) that returns a Result with the answer, the tokens and the cost. → [Your first Request](REQUESTS.md#how-to-create-your-first-request-in-5-minutes)

```ruby
class SupportRequest < ActiveHarness::Request
  system_prompt SupportPrompt

  model do
    use      provider: :openai,    model: "gpt-4.1-mini"                    # tried first
    fallback provider: :anthropic, model: "claude-haiku-4-5-20251001"       # if the first one fails
  end
end

request = SupportRequest.call(input: "How do I reset my password?", context: { product: "Acme" })
request.result.output     # the answer (String)
request.result.usage      # tokens and cost
```

Good to know:
- **Input and output.** Every entity takes an `input` and produces an `output` (a String). For a Request `input` is a String or a conversation (an Array of messages). → [Input as a message Array](AGENT.md#10-changes-to-existing-components)
- **Model chain.** The ordered models a Request tries; each model has its own retry with backoff. → [Fallbacks](REQUESTS.md#how-to-provide-fallbacks), [Retry policy](requests/retry_policy.md)
- **Result.** `input`, `output`, `processed` (parsed JSON for `format :json`), `model`, `usage`, `execution_time`, `attempts`. → [Token usage](requests/token_usage.md)
- **Context and params.** `context:` is what your app passes in (a user, a tenant), `params:` tunes a prompt; both reach prompts, hooks and tools. → [@context](PROMPTS.md#dynamic-content-with-context), [@params](PROMPTS.md#tuning-with-params)

## 4. Pipeline

**Pipeline** is a sequence of named steps — requests, tribunals, agents, lambdas — where each step's output is the next step's input and any step can stop the run. → [Your first Pipeline](PIPELINES.md#how-to-create-your-first-pipeline-in-5-minutes), [Step types](PIPELINES.md#step-types), [Stop conditions](PIPELINES.md#stop-conditions)

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  step :translate, TranslationRequest     # any language → English
  step :respond,   SupportRequest         # answers the translated question
end

pipeline = SupportPipeline.new(input: "Wie geht es dir?").call
pipeline.output                            # the last step's output
```

## 5. Tribunal

**Tribunal** is a panel of requests run in parallel whose answers are reduced to one verdict (unanimous, majority or your own rule) — for decisions one model should not make alone. → [Your first Tribunal](TRIBUNALS.md#how-to-create-your-first-tribunal-in-5-minutes), [Verdict strategies](TRIBUNALS.md#verdict-strategies)

```ruby
class PolitenessTribunal < ActiveHarness::Tribunal
  requests PolitenessByModelA, PolitenessByModelB, PolitenessByModelC   # Requests with format :json

  verdict :unanimous do |result|
    result.processed["result"] == true           # a "yes" vote
  end
end

PolitenessTribunal.new(input: "Thanks a lot!").call.verdict   # => true only if all three agree
```

## 6. Memory

**Memory** is stored conversation history that never enters the messages by itself: you decide where it goes (a prompt, a hook). → [How memory works](MEMORY.md#how-memory-works)

```ruby
class ChatPrompt
  def call
    history = @memory.to_messages.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n")
    "You are a friendly assistant.\nConversation so far:\n#{history}"     # injected by hand
  end
end

memory = ActiveHarness::Memory::JsonFile.new(file_name: "user_42")
memory.load                                                              # a bare Request does not load...
request = ChatRequest.call(input: "Hi!", memory: memory)
memory.record(request: "Hi!", response: request.result.output)           # ...or record; a Pipeline does both
```

## 7. Tool

**Tool** is a safe, declared action a model may ask for: validated input, ordered named steps that can refuse, then the real work. Default deny — a refusal or a failure goes back to the model as a message, nothing crashes. → [Tool design](TOOLS.md#2-proposed-design), [Examples](TOOLS.md#3-examples), [Security checklist](TOOLS.md#4-security-rules-to-keep-checklist)

```ruby
class LsTool < ActiveHarness::Tool
  tool_scope :os                                    # full name: os::ls
  tool_name  :ls

  description "List a directory"
  param :path, "Directory to list"

  step :inside_workspace do |input|                 # a named step; deny! refuses the call
    deny!("outside the workspace") unless input[:path].start_with?("/srv/app/")
  end

  def perform(input)
    Dir.children(input[:path])
  end
end

LsTool.call(input: { path: "/etc" }).status   # => :denied, never executed
```

## 8. Agent

**Agent** is a model that reaches an answer by using Tools in a loop, kept in bounds by limits and, optionally, a goal check. Every **turn** runs the same named steps (context → llm → tools → goal → limits) and the run ends with a **stop reason**. → [Idea and DSL](AGENT.md#1-idea), [The standard loop](AGENT.md#5-the-standard-loop)

```ruby
class FilesAgent < ActiveHarness::Agent
  max_turns 8                        # limits first

  request FilesRequest               # which Request talks to the model
  tools   LsTool                     # the only tools it may call
end

agent = FilesAgent.call(input: "What is in /srv/app/storage?")
agent.output        # the final answer
agent.stop_reason   # :final_answer
puts agent.trace    # every turn, tool call and refusal
```

Parts of an agent:
- **Goal and GoalCheck.** A check that judges the final answer: `:achieved`, or `:continue` with feedback for another turn. A block, a `GoalCheck` class, a Request or a Tribunal. Without one, "the model stopped asking for tools" ends the run. → [Data contracts](AGENT.md#4-data-contracts)
- **Limits.** Hard stops: `max_turns`, `max_cost`, `max_tool_calls`, `loop_guard`, `stop_if`. → [Completion and failure](AGENT.md#9-completion-and-failure)
- **Setup and finalize.** Optional Pipelines around the run: `setup` turns the input into a goal, `finalize` shapes the outcome. → [Full lifecycle](AGENT.md#23-full-lifecycle)

## 9. Agent loop

**Agent loop** is the repeating cycle inside an agent: ask the model → run the tools it asked for → feed the results back → decide whether to go on. One pass is a turn; the model decides *what* to do, the loop owns safety and stopping. → [The standard loop](AGENT.md#5-the-standard-loop)

```
Agent.call(input)
  ├─ setup      (optional)   turns the input into a goal
  ├─ LOOP       turns, until a stop reason fires
  └─ finalize   (optional)   shapes the outcome
```

```ruby
while running?
  stop!(:max_turns) and break if limit reached           # checked before every model call

  messages = step :context { build the history for the model }
  response = step :llm     { request.call(input: messages, tools: tool_schemas) }

  if response.tool_calls.any?
    step :tools { for each call: look the tool up (unknown → refused),
                  Tool.call(...),                          # steps, deny!, perform
                  put the result (or the refusal) into the history as a `tool` message }
  else
    step :goal  { no goal → finish!(:final_answer)
                  goal    → :achieved → finish!(:goal_reached)
                            :continue → add the feedback to the history, next turn }
  end

  step :limits { stop_if, loop_guard, max_turns, max_cost }
end
```

- A tool refusal or failure never stops the run by itself: the model reads it as text and may adjust (capped by `max_denials`, `max_tool_errors`).
- Every step is named, so traces and hooks say exactly where something happened (`turn.steps`, `on :after_step, :goal`).
- Every run ends with a **stop reason**: `:final_answer`, `:goal_reached`, `:max_turns`, `:max_cost`, `:repeating`, ... → `agent.stop_reason`

## 10. Hooks, streaming, tracing

**Hooks** are blocks that run at fixed moments (`before_call`, `after_step`, `before_tool`, ...); **streaming** delivers tokens (`token:`) and lifecycle events (`stream:`) as they happen; **tracing** turns both into logs or OpenTelemetry spans. → [Request hooks](requests/request_hooks.md), [Pipeline hooks](pipelines/pipeline_hooks.md), [Agent hooks](AGENT.md#7-hooks-events-tracing), [Streaming in a Rails app](REQUESTS.md#streaming-in-a-rails-app), [How tracing works](TRACING.md#how-it-works)

```ruby
class SupportRequest < ActiveHarness::Request
  on(:after_call) { |result| Rails.logger.info "#{result.model} #{result.usage.cost.total}$" }
end

SupportRequest.call(input: "Hi", stream: ->(source, event, *args) { puts "#{source}.#{event}" })
```
