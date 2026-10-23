# Terms

The few words ActiveHarness is built from. Each one is a plain Ruby class you subclass; the bigger pieces are made of the smaller ones:

```
Prompt ─┐
        ├─► Request ─┬─► Pipeline   steps in a row
Model chain ─┘       ├─► Tribunal   several at once → one verdict
                     └─► Agent      a loop ──uses──► Tool   a safe action
```

## 0. Structure

All AI code lives in `app/ai` (in Rails it is autoloaded; in plain Ruby put the files wherever you like). One directory per kind of class:

```
app/
└── ai/
    ├── prompts/      # 1. what the model is told           support_prompt.rb
    ├── requests/     # 2. one LLM call                      support_request.rb
    ├── pipelines/    # 3. steps in a row                    support_pipeline.rb
    ├── tribunals/    # 4. parallel requests, one verdict    politeness_tribunal.rb
    ├── memory/       # 5. custom conversation storage
    ├── tools/        # 6. safe actions for a model          ls_tool.rb
    ├── agents/       # 7. loops over requests and tools     files_agent.rb
    ├── goals/        #    goal checks for agents            answer_present_goal.rb
    └── concerns/     #    shared tracing / logging
```

Generators: `rails g active_harness:install` creates the tree, `rails g active_harness:request NAME` (also `prompt`, `tribunal`, `pipeline`, `memory`, `tool`, `agent`, `goal`) adds a single class.

## 1. Prompt

**Definition.** The system prompt of a Request: a plain Ruby class with `#call` that returns a string (or just a string / lambda). It can read `@input`, `@context`, `@params` and `@memory`, so it can be dynamic. → [How prompts work](PROMPTS.md#how-prompts-work)

```ruby
class SupportPrompt
  def call
    "You are a concise assistant for #{@context[:product]}. Answer in 1-2 sentences."
  end
end
```

## 2. Request

**Definition.** One logical LLM call: a prompt, a **model chain**, retries and hooks. `MyRequest.call(input: "...")` runs it; the answer is in `request.result`. → [Your first Request](REQUESTS.md#how-to-create-your-first-request-in-5-minutes)

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

## 3. Pipeline

**Definition.** Requests, tribunals, lambdas and agents run as **named steps** in a row; the output of one step is the input of the next, and a step can stop the whole pipeline. → [Your first Pipeline](PIPELINES.md#how-to-create-your-first-pipeline-in-5-minutes), [Step types](PIPELINES.md#step-types), [Stop conditions](PIPELINES.md#stop-conditions)

```ruby
class SupportPipeline < ActiveHarness::Pipeline
  step :translate, TranslationRequest     # any language → English
  step :respond,   SupportRequest         # answers the translated question
end

pipeline = SupportPipeline.new(input: "Wie geht es dir?").call
pipeline.output                            # the last step's output
```

## 4. Tribunal

**Definition.** Several requests run **in parallel** and one **verdict** is computed from their answers (`unanimous`, `majority` or your own rule). Use it when one model's opinion is not enough. → [Your first Tribunal](TRIBUNALS.md#how-to-create-your-first-tribunal-in-5-minutes), [Verdict strategies](TRIBUNALS.md#verdict-strategies)

```ruby
class PolitenessTribunal < ActiveHarness::Tribunal
  requests PolitenessByModelA, PolitenessByModelB, PolitenessByModelC   # Requests with format :json

  verdict :unanimous do |result|
    result.processed["result"] == true           # a "yes" vote
  end
end

PolitenessTribunal.new(input: "Thanks a lot!").call.verdict   # => true only if all three agree
```

## 5. Memory

**Definition.** Stored conversation history (JSON file, PostgreSQL, SQLite). It is never added to messages automatically — you decide where it goes (a prompt, a hook). A Pipeline records its turns by itself; a bare Request does not. → [How memory works](MEMORY.md#how-memory-works)

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

## 6. Tool

**Definition.** A controlled action a model may ask for: a `tool_scope` + `tool_name` (`os::ls`), a `schema` of parameters, ordered named **steps** (checks, `deny!`, `transform: true`) and a `perform`. Default deny: a refusal or a failure goes back to the model as a safe message, nothing crashes. → [Tool design](TOOLS.md#2-proposed-design), [Examples](TOOLS.md#3-examples), [Security checklist](TOOLS.md#4-security-rules-to-keep-checklist)

```ruby
class LsTool < ActiveHarness::Tool
  tool_scope  :os                                   # full name: os::ls
  tool_name   "ls"
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

## 7. Agent

**Definition.** A loop over Requests and Tools: ask the model → run the tools it asked for → feed the results back → repeat. Every **turn** runs the same named steps (context → llm → tools → goal → limits) and the run ends with a **stop reason**. → [Idea and DSL](AGENT.md#1-idea), [The standard loop](AGENT.md#5-the-standard-loop)

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

## 8. Hooks, streaming, tracing

**Definition.** *Hooks* are blocks that run at fixed moments (`before_call`, `after_step`, `before_tool`, ...) on Request, Pipeline, Tribunal, Tool and Agent. *Streaming* sends tokens (`token:`) and lifecycle events (`stream:`, with sources `:request`, `:tribunal`, `:pipeline`, `:agent`). *Tracing* turns them into logs or OpenTelemetry spans. → [Request hooks](requests/request_hooks.md), [Pipeline hooks](pipelines/pipeline_hooks.md), [Agent hooks](AGENT.md#7-hooks-events-tracing), [Streaming in a Rails app](REQUESTS.md#streaming-in-a-rails-app), [How tracing works](TRACING.md#how-it-works)

```ruby
class SupportRequest < ActiveHarness::Request
  on(:after_call) { |result| Rails.logger.info "#{result.model} #{result.usage.cost.total}$" }
end

SupportRequest.call(input: "Hi", stream: ->(source, event, *args) { puts "#{source}.#{event}" })
```
