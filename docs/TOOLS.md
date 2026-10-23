# Tools (design proposal)

> Status: **first iteration implemented** (`lib/active_harness/tool.rb`, `tool/path_policy.rb`; tests in `test/tool_test.rb`). The consumer of tools is [AGENT.md](AGENT.md). Goal: give an LLM agent a *safe, declared* way to touch the outside world (OS, network, DB). The model never gets a shell — it can only call tools you wrote, and every call passes through your checks first.

## 1. How others do it (short)

| Tool | Tool = | Safety model |
| --- | --- | --- |
| **RubyLLM** (`ruby_llm/lib/ruby_llm/tool.rb`) | class with `description`, `parameter`, `execute` | `requires_approval { \|tool_call\| ... }` — call pauses until a human/resolver approves. Nothing else built in |
| **OpenAI / Anthropic function calling** | JSON schema + your function | None: the API only *proposes* a call; running it (and checking it) is entirely your code |
| **Claude Code / Agent SDK** | built-in tools (`Bash`, `Read`, `Edit`...) | Layered: allow/deny **rules** (`Bash(git diff:*)`), permission **modes**, `PreToolUse` **hooks** that can allow / deny / ask, optional OS sandbox |
| **MCP** | server exposes tools over JSON-RPC | Client decides: per-tool approval, annotations (`readOnlyHint`, `destructiveHint`) are hints only |
| **LangChain / LlamaIndex** | `Tool(name, description, func)` | Mostly none; human-in-the-loop middleware / interrupt for risky ones |
| **OpenAI Agents SDK** | `@function_tool` | *Guardrails* (input/output validators) + `needs_approval` |

Patterns worth stealing:

1. **Schema the model sees** is separate from **policy the model doesn't see** (Claude Code rules, RubyLLM approval).
2. **Pre-execution hook** with clear outcomes: *allow / deny* (Claude Code).
3. **Deny returns a message to the model, not an exception** — the model can adjust and retry.
4. **Default deny**: a tool that is not registered does not exist.

## 2. Proposed design

One base class, `ActiveHarness::Tool`, same style as `Request`/`Tribunal` (class-level DSL, per-subclass isolated config via `inherited`, hooks via `Core::HookRunner`).

Lifecycle of one call: **an ordered list of named steps with one interface** — each step takes the current payload, may `deny!`, and (if `transform`) returns the next payload.

```
model proposes call (name + args)         input = raw args from the model
  → step :no_hidden_dirs   (check)         # your steps, in order; each gets the current payload (starts as `input`)
  → step :expand_path      (transform)     # may return a new payload for the next steps
  → step :allowed_host     (check)
  → perform                (built-in)      # always last; its value is the output
  → ToolResult (ok | denied | error) + trace of steps, fed back to the model
```

Rules:
- There is no built-in preparation: the tool receives `input` exactly as the loop got it from the model (a Hash parsed from JSON, symbol keys) and does whatever checking/coercion it needs in its own steps. `schema` only describes the arguments **to the model** (declared with `param`; `Tool.to_schema` builds the provider schema from it).
- One signature for steps: `|input|`.
- A step is a block (`step :name do |input| ... end`) or an instance method of the same name (`step :name` → `def name(input)`), so long checks can be normal multi-line methods.
- Checks stop the chain with `deny!("...")`; their return value is ignored. Only `transform: true` steps replace the payload (for everything after them, and for `perform`).
- Every step has a **name**, so the result and the hooks say exactly where something happened: `result.steps`, `result.failed_step.name` / `.message`, hooks `:before_step` / `:after_step` / `:before_perform` / `:after_perform` (see Hooks) — same model as `Pipeline`.

Outcomes are a `ToolResult` struct, never a raw exception to the agent loop:

```ruby
StepResult = Struct.new(:name, :status, :message, :detail, :ms)  # status: :ok | :denied | :error
# message — safe text, the ONLY thing the model may see; detail — internals (paths, policy names), trace/log only
ToolResult = Struct.new(:status, :input, :output, :failed_step, :steps, :outcome_unknown, keyword_init: true)
# status: :ok | :denied | :error
```

```ruby
result = LsTool.call(input: { path: "/srv/app/workspace/.git" }, context: { user: current_user })
result.input                 # => { path: "/srv/app/workspace/.git" }
result.status                # => :denied
result.failed_step.name      # => :no_hidden_dirs   (nil when everything passed)
result.failed_step.message   # => "hidden dirs are off limits"   (safe text, goes to the model)
result.failed_step.detail    # => nil | "matched segment '.git' in /srv/app/workspace/.git"   (trace only)
result.model_message         # => what the agent sends back as the `tool` message
result.steps                 # => [#<StepResult :no_nul_byte :ok>, #<StepResult :no_hidden_dirs :denied>]
result.output                # => the `perform` value (nil if a step failed)
```

### Base class sketch

```ruby
module ActiveHarness
  class Tool
    class Denied < StandardError         # raise from any step → status :denied
      attr_reader :detail
      def initialize(message, detail: nil); super(message); @detail = detail; end
    end
    class UnknownOutcome < StandardError         # status :error + outcome_unknown: true (not a Denied: must not match `rescue Denied`)
      attr_reader :detail
      def initialize(message, detail: nil); super(message); @detail = detail; end
    end

    Step    = Struct.new(:name, :block, :transform) { def perform?; name == :perform; end }
    PERFORM = Step.new(:perform, nil, true)

    class << self
      # --- what the model sees ---
      def tool_scope(v = nil);  v ? @tool_scope = v.to_sym : @tool_scope; end  # required: :os, :web, :ruby ...
      def tool_name(v = nil);   v ? @tool_name = v.to_s : @tool_name; end      # required: "ls", "fetch" ...
      def full_name;            "#{tool_scope}::#{tool_name}"; end             # "os::ls", "web::fetch"
      def description(v = nil); v ? @description = v : @description; end
      # Arguments for the model — a readable DSL; a tool without `param` takes no arguments.
      #   param :path, "Directory to list"                       # type: :string, required: true by default
      #   param :limit, "Max entries", type: :integer, required: false
      #   param :kind, "Entry kind", enum: %w[file dir]
      def param(name, description, type: :string, required: true, enum: nil)
        params << { name: name, description: description, type: type, required: required, enum: enum }.compact
      end
      def params; @params ||= []; end
      def schema; params; end                      # same thing as an array of hashes; may be overridden by hand

      # --- what the model does NOT see: ordered, named steps ---
      def step(name, transform: false, &blk)          # no block → calls instance method `name`
        steps << Step.new(name, blk, transform)
      end
      def steps; @steps ||= []; end

      # Same API as Pipeline: on :before_step { |name, payload| }, on :before_step, :one_step { |payload| }
      def on(event, step_name = nil, &blk); ...; end   # events: before_step after_step before_perform after_perform

      def inherited(sub)
        super
        sub.instance_variable_set(:@steps, steps.dup)
      end
    end

    def self.call(input:, context: {}); new(context: context).call(input); end   # same style as Request

    attr_reader :context   # app-supplied: current_user, root dir, etc.

    def initialize(context: {}); @context = context; end

    attr_accessor :payload, :output   # live state of the current call; hooks may read AND replace them

    # Entry point used by the agent loop. Never raises for expected failures.
    def call(input)
      @payload, @output, steps = input, nil, []
      (self.class.steps + [PERFORM]).each do |step|
        started, status, message, detail, unknown = Time.now, :ok, nil, nil, false
        begin
          fire(:before_step, step.name, @payload)
          fire(:before_perform, @payload) if step.perform?
          value = step.block ? instance_exec(@payload, &step.block) : send(step.name, @payload)
          @payload = value if step.transform
          if step.perform?
            @output = value
            fire(:after_perform, @output)
          end
        rescue Denied => e         then status, message, detail = :denied, e.message, e.detail   # also from hooks
        rescue UnknownOutcome => e then status, message, detail, unknown = :error, "result unknown, verify before retrying", e.detail, true
        rescue StandardError => e  then status, message, detail = :error, "tool failed, try another approach or finish", "#{e.class}: #{e.message}"   # internals never reach the model
        end
        steps << StepResult.new(step.name, status, message, detail, ms(started))
        fire(:after_step, step.name, steps.last)                               # fires for failed steps too
        next if status == :ok
        return ToolResult.new(status: status, input: input, failed_step: steps.last, steps: steps, outcome_unknown: unknown)
      end
      ToolResult.new(status: :ok, input: input, output: @output, steps: steps)
    end

    def fire(event, *args); ...; end                 # runs global + per-step hooks (Core::HookRunner)
    def ms(started); ((Time.now - started) * 1000).round; end

    def perform(_input); raise NotImplementedError; end

    # Class-level: the agent/Request passes this to the provider's `tools:` field.
    # (defined as `def self.to_schema` in the real class)
    #   { name: "os__ls", description: "...", parameters: { type: "object", properties: ..., required: ... } }
    # The wire name uses `__` instead of `::` (providers allow only [a-zA-Z0-9_-]); the registry maps it back.

    def deny!(msg, detail: nil) = raise(Denied.new(msg, detail: detail))
    def unknown_outcome!(msg = nil, detail: nil)   # the side effect may have happened — the model is told to verify before retrying
      raise(UnknownOutcome.new(msg || "unknown outcome", detail: detail))
    end             # (use `def deny!(msg); raise ...; end` on Ruby < 3.0)

  end
end
```

(Ruby 2.6 compat in the real implementation: no endless `def`.)

### Hooks

Same shape as `Pipeline` hooks (`on`, plus `before`/`after` aliases; blocks run via `instance_exec` on the tool instance, so they see `context`, `payload`, `output` and helpers). Registered on the tool class, accumulate, inherited by subclasses.

| Hook | Block args | Fires |
| --- | --- | --- |
| `:before_step` | `\|step_name, payload\|` | before every step, `perform` included |
| `:after_step` | `\|step_name, step_result\|` | after every step, also a failed one (`step_result.status` / `.message`) |
| `:before_perform` | `\|payload\|` | right before `perform` (after `before_step :perform`) |
| `:after_perform` | `\|output\|` | right after a successful `perform` (before `after_step :perform`) |

Per-step form, as in `Pipeline`: `on :before_step, :resolve_path do |payload| ... end` (no `step_name` arg).

```ruby
class LsTool < ActiveHarness::Tool
  on :before_step do |step_name, payload|
    logger.debug("[#{full_name}] -> #{step_name} #{payload}")
  end

  on :after_step do |step_name, step_result|
    logger.warn("[#{full_name}] #{step_name} #{step_result.status}: #{step_result.message}") unless step_result.status == :ok
  end

  on :before_perform do |payload|
    audit!(context[:user], full_name, payload)       # last look before the real action
    deny!("read-only maintenance window") if Maintenance.on?   # a hook may stop the call
  end

  on :after_perform do |output|
    self.output = output.first(100)                   # a hook may replace what the model gets back
  end
end
```

Rules:
- Hooks may **read** everything and **replace** `payload` (in `before_*`) and `output` (in `after_perform`) via `self.payload = ...` / `self.output = ...`. Steps stay pure (`|payload|` → return value); hooks are the place for side effects and cross-cutting changes.
- `deny!` in a hook stops the call exactly like in a step; `failed_step` is the step the hook belongs to. Any other exception in a hook is an `:error` result.
- Order for `perform`: `before_step` → `before_perform` → `perform` → `after_perform` → `after_step`.
- Request/Pipeline-level `:before_tool` / `:after_tool` hooks (see below) wrap the whole `tool.call`; the hooks above are inside it.

### Reusable constraints as mixins

Path/host checks are the dangerous part — implement them **once**, correctly (resolve symlinks, `..`, trailing-slash prefix bug), and reuse:

```ruby
module ActiveHarness::Tool::PathPolicy
  # The including tool must define ALLOWED_PATHS (a missing constant raises NameError = fail closed).

  # Returns a safe absolute path or raises Denied.
  def safe_path!(path)
    real = File.realpath(File.expand_path(path))      # follows symlinks
    roots = self.class::ALLOWED_PATHS.map { |r| File.realpath(r) }
    ok = roots.any? { |r| real == r || real.start_with?(r + File::SEPARATOR) }
    deny!("#{path} is outside allowed directories") unless ok
    real
  rescue Errno::ENOENT
    deny!("#{path} does not exist")
  end
end
# Same idea: HostPolicy (ALLOWED_HOSTS, block private IPs / metadata endpoint → SSRF), CommandPolicy (fixed argv, no shell).
```

### Scopes

Every tool **must** declare a `tool_scope` (`:os`, `:web`, `:ruby`, ...) and a `tool_name`; the full name is `tool_scope::tool_name`: `os::ls`, `os::rm`, `web::fetch`, `ruby::fetch`. This gives namespacing (two `fetch` tools don't clash) and a coarse policy handle: allow/deny a whole scope or log by scope. Validation (required scope, allowed scope list, name format) — to be designed later.

Note: provider APIs usually allow only `[a-zA-Z0-9_-]` in function names, so `to_schema` should send `os__ls` and the loop maps it back to `os::ls`.

## 3. Examples

### `os::ls` — safe directory listing

```ruby
class LsTool < ActiveHarness::Tool
  include ActiveHarness::Tool::PathPolicy

  tool_scope :os
  tool_name  :ls

  description "List files in a directory"

  param :path, "Directory to list"

  ALLOWED_PATHS = %w[/srv/app/workspace /tmp/agent].freeze

  step :no_nul_byte do |input|
    deny!("path must not contain NUL") if input[:path].include?("\0")
  end

  step :resolve_path, transform: true do |input|
    # returns a NEW payload: path becomes a canonical absolute path inside ALLOWED_PATHS
    # (or the chain stops with deny!). Everything after this step, incl. perform, sees only this path.
    input.merge(path: safe_path!(input[:path]))
  end

  step :no_hidden_dirs do |input|
    hidden = input[:path].split("/").any? do |segment|
      segment.start_with?(".")
    end

    deny!("hidden dirs are off limits") if hidden
  end

  def perform(input)
    Dir.children(input[:path]).first(200)      # path is already safe here; also cap the output size
  end
end
```

### `web::fetch` — internet access with a host allowlist

```ruby
class FetchUrlTool < ActiveHarness::Tool
  tool_scope :web
  tool_name  :fetch

  description "HTTP GET a public URL"

  param :url, "Public http(s) URL"

  ALLOWED_HOSTS = %w[docs.ruby-lang.org api.github.com].freeze

  step :allowed_host do |input|
    host = URI(input[:url]).host
    deny!("host #{host} is not allowed") unless ALLOWED_HOSTS.include?(host)
    deny!("private address") if private_ip?(host)
  end

  def perform(input)
    Net::HTTP.get(URI(input[:url]))[0, 20_000]
  end
end
```

### `os::rm` — destructive, depends on who is asking

```ruby
class RmTool < ActiveHarness::Tool
  include ActiveHarness::Tool::PathPolicy

  tool_scope :os
  tool_name  :rm

  description "Delete a file"

  param :path, "File to delete"

  ALLOWED_PATHS = %w[/srv/app/workspace].freeze

  step :admin_only do |_input|
    deny!("admins only") unless context[:user]&.admin?
  end

  def perform(input)
    File.delete(safe_path!(input[:path])); "deleted"
  end
end
```

### How tools reach the model

`Tool` itself knows nothing about LLMs. The loop that connects them lives in **`ActiveHarness::Agent`** ([AGENT.md](AGENT.md)); `Request` stays a single logical LLM call and gets two extensions:

```ruby
request = SomeRequest.call(
  input: [{ role: :user, content: "What is in the workspace?" }],
  tools:    [LsTool.to_schema, FetchUrlTool.to_schema]      # schemas only — nothing is executed here
)
request.result.tool_calls   # => [{ id: "call_1", name: "os__ls", arguments: { "path" => "/srv/app/workspace" } }]
```

The agent then, for each `tool_call`:

1. looks the name up in its registry (`os__ls` → `LsTool`); **unknown name → never executed**, a refusal goes back to the model;
2. runs `LsTool.call(input: arguments, context: context)` — the steps, checks and hooks above;
3. appends `result.model_message` as a `tool` message bound to the original call `id` (success → `output`; denied → `failed_step.message`; error → generic "tool failed, try another approach or finish"; unknown outcome → "result unknown, verify before retrying");
4. keeps the whole `ToolResult` (with `detail`) in the agent's trace.

`Request.call(input: "...")` keeps working unchanged; an Array `input:` and `tools:` are additive.

## 4. Security rules to keep (checklist)

- Default deny; tools are explicit classes, never `eval`/`system` with model-built strings. If you must run a binary: `Open3.capture3("git", "log", arg)` — argv array, **no shell**.
- Validate **after** canonicalizing (`File.realpath`), not before. Check prefix with a separator.
- Treat all args — and everything returned by tools (web pages, file contents) — as untrusted input; tool output can contain prompt injection. Don't let a read tool's output authorize a write tool.
- Cap output size, time (`Timeout`), and calls per run.
- Log every call + decision (agent hooks `:before_tool` / `:after_tool`, tool hooks above) — fits the existing TRACING setup.
- The model sees only the **safe message** (`deny!("...")`); internals go to `detail:` and the trace. Never put paths, policy names or secrets into `message`.
- **Side effects are never retried automatically.** A failed Request is retried by the Request itself, never by re-running tool calls. Write-tools should be idempotent or verify the outcome; if the outcome is unknown, no unconditional retry.
- Every call has a unique `id`; the `tool` result message is bound to it.
- **A tool failure does not stop the agent**: `:denied` / `:error` go back to the model, which may try another tool or finish; the agent only counts them (`max_tool_errors`, `:too_many_denials`).
- **Unknown outcome of a side effect** (e.g. a timeout after a write was sent): the tool reports it with `unknown_outcome!`, the model is told "result unknown, verify before retrying", and the call is never retried automatically.
- Real isolation (container, separate OS user) is still stronger than any Ruby-level check; this layer is defense in depth.

## 5. Decisions

> First iteration: decisions taken as the most likely ones and consistent with the rest of the system; to be revisited after practice.

- The loop is **not** in `Request` and not a RubyLLM adapter: it is `Agent` ([AGENT.md](AGENT.md)). `Request` accepts a message Array as `input:` and `tools:`, and returns `tool_calls`.
- `Tool.call(input:, context:)` → `ToolResult`; the agent never gets an exception for expected failures. `ToolResult` is a separate type from `Result` (shared only: `status`, `execution_time`/`ms`, `input`).
- **Arguments are declared with the `param` macro** (`type:` defaults to `:string`, `required:` to `true`, `enum:`); `self.schema` is the same list of hashes, `Tool.to_schema` is the provider JSON schema; wire name `scope__name`. Nested objects later.
- **`tool_scope` and `tool_name` are always explicit** — there is no default derived from the class name, so renaming a class never changes the name the model sees (and every tool reads the same).
- Refusals: the model gets the safe `deny!("...")` message, details (`detail:`) stay in the trace.
- **Unexpected `:error` does not stop the agent**: the model gets "tool failed, try another approach or finish" and decides; the agent caps consecutive errors.
- **Unknown side-effect outcome is `unknown_outcome!("...")`**, a sibling of `deny!`: an `:error` result with `outcome_unknown: true`; the model is told to verify before retrying; no automatic retry.
- Layout: `lib/active_harness/tool.rb`, `tool/path_policy.rb`; Rails: `app/ai/tools/` + `rails g active_harness:tool NAME`.
- Postponed: parallel tool calls, human approval, sub-agents, Tribunal as a gate (an idea in AGENT.md).
