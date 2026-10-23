require "securerandom"
require "time"
require_relative "agent/state"
require_relative "agent/goal_check"

module ActiveHarness
  # A loop: ask the LLM -> run the tools it asked for -> feed the results back
  # -> repeat until an answer, a goal check or a limit stops it.
  #
  # An Agent owns almost no logic. It declares which requests it may call, which
  # tools it may use and when to stop. Everything risky stays inside Tools,
  # everything model-related stays inside Requests.
  #
  #   class SearchAgent < ActiveHarness::Agent
  #     max_turns 10
  #     max_cost  0.50
  #
  #     request SearchRequest
  #     tools   WebSearchTool, FetchPageTool
  #   end
  #
  #   agent = SearchAgent.call(input: "Find 5 Ruby frameworks")
  #   agent.status       # => :done | :stopped | :failed
  #   agent.stop_reason  # => :final_answer | :goal_reached | :max_turns | ...
  #   agent.output       # => final answer text
  #
  # See docs/AGENT.md.
  class Agent
    GOAL_STATUSES = %i[achieved continue replan needs_input failed].freeze

    VALID_HOOKS = %i[
      before_setup after_setup
      before_turn after_turn
      before_step after_step
      before_llm after_llm
      before_tool after_tool tool_denied
      replan stopped
      before_finalize finalize_error complete
    ].freeze
    STEP_HOOKS = %i[before_step after_step].freeze
    TOOL_HOOKS = %i[before_tool after_tool tool_denied].freeze
    STEPS      = %i[context llm tools goal limits].freeze

    DEFAULT_LIMITS = {
      max_turns:        10,
      max_cost:         nil,
      max_tool_calls:   nil,
      max_tool_errors:  3,
      max_denials:      5,
      max_goal_retries: 2
    }.freeze

    # -------------------------------------------------------------------------
    # Class-level DSL
    # -------------------------------------------------------------------------
    class << self
      def agent_config
        @agent_config ||= new_agent_config
      end

      # Each subclass gets its own isolated config.
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@agent_config, new_agent_config)
      end

      # request SomeRequest            — the default Request
      # request :cheap, CheapRequest   — a named one (see request_for)
      def request(name_or_class, klass = nil)
        name, klass = klass ? [name_or_class.to_sym, klass] : [:default, name_or_class]
        agent_config[:requests][name] = klass
      end

      # Allowed tools (default deny: anything else is "unknown tool").
      def tools(*classes)
        agent_config[:tools].concat(classes.flatten)
      end

      DEFAULT_LIMITS.each_key do |limit|
        define_method(limit) do |value|
          agent_config[:limits][limit] = value
        end
      end

      # Pick the Request for the next turn: request_for { |turn| turn.number > 4 ? :cheap : :default }
      def request_for(&block)
        agent_config[:request_for] = block
      end

      # A goal check: an object with call(candidate:, goal:, state:) returning GoalCheckResult,
      # or a block { |candidate, goal, state| ... }.
      def goal(check = nil, &block)
        agent_config[:goal] = check || block
      end

      def setup(pipeline)
        agent_config[:setup] = pipeline
      end

      def finalize(pipeline)
        agent_config[:finalize] = pipeline
      end

      # An object with call(state:) -> messages for the model. Default: the full history.
      def context_builder(builder)
        agent_config[:context_builder] = builder
      end

      # Stop when the same tool calls with the same input repeat `times` turns in a row.
      def loop_guard(times: 3)
        agent_config[:loop_guard] = times
      end

      # Custom stop rule: stop_if(:name) { |turn| ... } — the stop_reason is :name.
      def stop_if(name, &block)
        agent_config[:stop_rules] << [name.to_sym, block]
      end

      # on :before_tool do |call| ... end
      # on :before_tool, "os::rm" do |call| ... end        (per-tool form)
      # on :after_step, :goal do |turn| ... end            (per-step form)
      def on(event, name = nil, &block)
        raise ArgumentError, "Unknown Agent hook :#{event}. Valid: #{VALID_HOOKS.join(', ')}" unless VALID_HOOKS.include?(event)

        if name.nil?
          (agent_config[:hooks][event] ||= []) << block
        elsif STEP_HOOKS.include?(event)
          ((agent_config[:step_hooks][name.to_sym] ||= {})[event] ||= []) << block
        elsif TOOL_HOOKS.include?(event)
          key = name.respond_to?(:full_name) ? name.full_name : name.to_s
          ((agent_config[:tool_hooks][key] ||= {})[event] ||= []) << block
        else
          raise ArgumentError, "Hook :#{event} has no per-name form"
        end
      end

      def before(event, name = nil, &block)
        on(:"before_#{event}", name, &block)
      end

      def after(event, name = nil, &block)
        on(:"after_#{event}", name, &block)
      end

      def callback(event, &block)
        on(event, &block)
      end

      # Same style as Request.call: returns the (already run) instance.
      def call(input:, context: {}, params: {}, memory: nil, token: nil, stream: nil)
        new(input: input, context: context, params: params, memory: memory, token: token, stream: stream).call
      end

      private

      def new_agent_config
        {
          requests:   {},
          tools:      [],
          limits:     DEFAULT_LIMITS.dup,
          hooks:      {},
          step_hooks: {},
          tool_hooks: {},
          stop_rules: []
        }
      end
    end

    include Core::HookRunner

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_accessor :input, :context, :params, :memory
    attr_reader   :state, :turns, :error, :finalize_error, :execution_time

    def initialize(input: nil, context: {}, params: {}, memory: nil, token: nil, stream: nil)
      @input   = input
      @context = context
      @params  = params
      @memory  = memory
      @token   = token
      @stream  = stream
      @config  = self.class.agent_config
      @turns   = []
      @state   = nil
      @output  = nil
    end

    # Runs the loop. Returns self (like Request#call); never raises for run-time
    # failures — see #status / #stop_reason / #error.
    def call(input = nil, token: nil, stream: nil)
      @input  = input  if input
      @token  = token  if token
      @stream = stream if stream

      raise ArgumentError, "#{self.class.name}: no request configured (use `request SomeRequest`)" if @config[:requests].empty?

      started = clock
      reset_run
      begin
        run_setup
        run_loop if running?
      rescue Errors::AllModelsFailed, Errors::ProviderError => e
        fail_run(:request_error, e)
      rescue StandardError, NotImplementedError => e # NotImplementedError is a ScriptError: a forgotten #call/#perform fails the run, not the caller
        fail_run(:runtime_error, e)
      end
      run_finalize
      @execution_time = (clock - started).round(3)

      fire(:stopped, @state.stop_reason) unless %i[final_answer goal_reached].include?(@state.stop_reason)
      fire(:complete, result)
      self
    end

    def status;      @state&.status;      end
    def stop_reason; @state&.stop_reason; end
    def output;      @output;             end
    def usage;       @state&.usage;       end
    def run_id;      @state&.run_id;      end
    def goal;        @state&.goal;        end

    def tool_calls
      @turns.flat_map(&:tool_calls)
    end

    def denied_calls
      tool_calls.select { |c| c.result && c.result.status != :ok }
    end

    # Result-compatible outcome, so an agent can be a Pipeline step.
    # processed is the last Request's processed value (parsed JSON for `format :json`).
    def result
      last = @turns.reverse.map(&:response).compact.first
      Result.new(
        input:          @input,
        output:         @output,
        processed:      @final_response ? @final_response.processed : @output,
        model:          last&.model,
        attempts:       [],
        execution_time: @execution_time,
        usage:          @state&.usage,
        warnings:       [],
        meta:           { status: status, stop_reason: stop_reason, run_id: run_id }
      )
    end

    # Human-readable trace of the whole run.
    def trace
      lines = @turns.map do |turn|
        res    = turn.response
        tokens = res&.usage&.tokens&.total
        cost   = res&.usage&.cost&.total
        head   = format("turn %-2d llm(%s) %s", turn.number, turn.request_name, res&.model&.name)
        head  += "  #{tokens} tok" if tokens
        head  += format("  $%.4f", cost) if cost
        head  += "  #{(res.execution_time * 1000).round}ms" if res&.execution_time
        body = turn.tool_calls.map do |c|
          r = c.result
          line = "        tool #{c.full_name} #{c.input.inspect}  #{r&.status}"
          line += " at #{r.failed_step.name}: #{r.failed_step.message}" if r&.failed_step
          line += " [#{r.failed_step.detail}]" if r&.failed_step&.detail
          line
        end
        body << "        answer: #{res.output.to_s[0, 80].inspect}" if turn.tool_calls.empty? && res
        ([head] + body).join("\n")
      end
      lines << format("stop    %s   %d turns, %d tool calls (%d refused or failed), $%.4f",
                      @state.stop_reason, @turns.size, tool_calls.size, denied_calls.size,
                      @state.usage&.cost&.total.to_f)
      lines.join("\n")
    end

    private

    # -------------------------------------------------------------------------
    # Run lifecycle
    # -------------------------------------------------------------------------

    def reset_run
      @turns          = []
      @error          = nil
      @finalize_error = nil
      @output         = nil
      @last_text      = nil
      @final_response = nil
      @goal_retries   = 0
      @denials        = 0
      @consecutive_errors = 0
      @signatures     = []
      @state = AgentState.new(
        run_id: SecureRandom.uuid, status: :running, input: @input,
        goal: nil, plan: nil, messages: [], events: [], artifacts: {},
        turn: 0, tool_calls_count: 0,
        usage: UsageInfo.new(tokens: TokenCounts.new(input: 0, output: 0, total: 0), cost: nil),
        stop_reason: nil
      )
    end

    def running?
      @state.status == :running
    end

    def run_setup
      pipeline_class = @config[:setup] && as_pipeline(@config[:setup])
      fire(:before_setup, @state)

      goal = nil
      if pipeline_class
        pipeline = pipeline_class.new(input: @input, context: @context.dup, params: @params, memory: @memory, stream: @stream)
        pipeline.call
        charge(:setup, pipeline)
        journal(:setup, stopped: pipeline.stopped?, stopped_at: pipeline.stopped_at)

        if pipeline.stopped?
          reject_setup(pipeline)
          fire(:after_setup, @state)
          return
        end

        last = pipeline.steps.to_a.last
        goal = Goal.from(last ? last[2].processed : pipeline.output)
        if goal.nil?
          @output = "Setup did not produce a goal (expected a Hash with :task or a String)"
          stop!(:setup_rejected)
          fire(:after_setup, @state)
          return
        end
      else
        goal = Goal.new(task: @input.to_s)
      end

      @state.goal = goal
      @state.plan = goal.plan
      @state.messages << { role: :user, content: goal.task.to_s }
      fire(:after_setup, @state)
    end

    def reject_setup(pipeline)
      refusal = pipeline.stop_reason
      text    = refusal.respond_to?(:output) ? refusal.output : nil
      text    = refusal.processed.to_s if text.to_s.empty? && refusal.respond_to?(:processed)
      @output = text.to_s.empty? ? "Rejected at setup step :#{pipeline.stopped_at}" : text.to_s
      stop!(:setup_rejected)
    end

    def run_loop
      while running?
        reason = limit_reason
        (stop!(reason); break) if reason

        turn = AgentTurn.new(number: @state.turn + 1, tool_calls: [], steps: [])
        @state.turn = turn.number
        @turns << turn
        turn_started = clock
        fire(:before_turn, turn)

        messages = step(turn, :context) { context_builder.call(state: @state) }
        response = step(turn, :llm)     { call_llm(turn, messages) }

        if response.tool_calls && !response.tool_calls.empty?
          if cost_exceeded?
            stop!(:max_cost)
          else
            step(turn, :tools) { run_tools(turn, response.tool_calls) }
          end
        else
          step(turn, :goal) { decide_goal(turn, response) }
        end

        step(turn, :limits) { check_limits(turn) } if running?

        turn.ms = ((clock - turn_started) * 1000).round
        fire(:after_turn, turn)
      end
    end

    def run_finalize
      return unless @config[:finalize]

      pipeline_class = as_pipeline(@config[:finalize])
      fire(:before_finalize, @state)
      ctx = @context.merge(state: @state, status: @state.status, stop_reason: @state.stop_reason,
                           processed: @final_response&.processed)
      pipeline = pipeline_class.new(input: @output.to_s, context: ctx, params: @params, memory: @memory, stream: @stream)
      pipeline.call
      charge(:finalize, pipeline)
      @output = pipeline.output unless pipeline.stopped? || pipeline.output.nil?
      journal(:finalize, stopped: pipeline.stopped?)
    rescue StandardError => e
      # A failure in finalization never erases the primary stop reason.
      @finalize_error = e
      journal(:finalize_error, error: "#{e.class}: #{e.message}")
      fire(:finalize_error, e)
    end

    def stop!(reason)
      @state.status      = :stopped
      @state.stop_reason = reason
      @output          ||= @last_text
      journal(:stop, reason: reason)
    end

    def finish!(reason, output)
      @state.status      = :done
      @state.stop_reason = reason
      @output            = output
      journal(:stop, reason: reason)
    end

    def fail_run(reason, error)
      @error             = error
      @state.status      = :failed
      @state.stop_reason = reason
      @output          ||= @last_text
      journal(:error, reason: reason, error: "#{error.class}: #{error.message}")
    end

    # -------------------------------------------------------------------------
    # One turn
    # -------------------------------------------------------------------------

    # Runs a named step of the turn: hooks, timing, trace.
    def step(turn, name)
      fire(:before_step, name, turn)
      fire_step(:before_step, name, turn)
      t0 = clock
      begin
        value = yield
        turn.steps << { name: name, status: :ok, ms: ((clock - t0) * 1000).round }
        value
      rescue StandardError
        turn.steps << { name: name, status: :error, ms: ((clock - t0) * 1000).round }
        raise
      ensure
        fire(:after_step, name, turn)
        fire_step(:after_step, name, turn)
      end
    end

    def call_llm(turn, messages)
      name  = request_name_for(turn)
      klass = @config[:requests][name] or raise ArgumentError, "#{self.class.name}: no request named #{name.inspect}"
      schemas = tool_schemas

      request = klass.new(
        context:  @context.merge(goal: @state.goal, agent_state: @state),
        params:   @params,
        memory:   @memory,
        token:    @token,
        stream:   @stream,
        input:    messages,
        tools:    schemas.empty? ? nil : schemas
      )
      turn.request_name = name
      turn.request      = request

      fire(:before_llm, turn, request)
      request.call
      response = request.result
      turn.response = response

      add_usage(response.usage)
      @state.messages << response.message
      @last_text = response.output unless response.output.to_s.empty?
      journal(:llm, turn: turn.number, request: name, model: response.model&.name,
                    tokens: response.usage&.tokens&.total, cost: response.usage&.cost&.total,
                    tool_calls: Array(response.tool_calls).map { |c| c[:name] }, ms: (response.execution_time.to_f * 1000).round)
      fire(:after_llm, turn, request)
      response
    end

    def request_name_for(turn)
      block = @config[:request_for]
      name  = block ? instance_exec(turn, &block) : :default
      (name || :default).to_sym
    end

    def run_tools(turn, calls)
      calls.each do |raw|
        max = limit(:max_tool_calls)
        if max && @state.tool_calls_count >= max
          stop!(:max_tool_calls)
          return
        end

        call = execute_tool_call(raw, turn)
        turn.tool_calls << call
        @state.tool_calls_count += 1
        @state.messages << { role: :tool, tool_call_id: call.id, name: call.name, content: call.result.model_message }

        track_tool_outcome(call)
        reason = tool_failure_limit
        if reason
          stop!(reason)
          return
        end
      end
    end

    def execute_tool_call(raw, turn)
      klass = tool_registry[raw[:name].to_s]
      args  = raw[:arguments]
      call  = ToolCall.new(id: raw[:id], name: raw[:name].to_s, tool: klass, input: args)
      t0    = clock

      result =
        if klass.nil?
          refusal(:lookup, "unknown tool: #{raw[:name]}")
        elsif !args.is_a?(Hash)
          refusal(:arguments, "arguments are not valid JSON", detail: raw[:raw_arguments].to_s[0, 200])
        else
          call.input = symbolize_keys(args)
          error = klass.validate_input(call.input)
          if error
            refusal(:arguments, error)
          else
            begin
              fire(:before_tool, call)
              fire_tool(:before_tool, call, call)
              klass.call(input: call.input, context: @context)
            rescue Tool::Denied => e
              refusal(:before_tool, e.message, detail: e.detail)
            end
          end
        end

      call.result = result
      fire(:after_tool, call, result)
      fire_tool(:after_tool, call, call, result)
      if result.status == :denied
        fire(:tool_denied, call, result)
        fire_tool(:tool_denied, call, call, result)
      end

      journal(:tool_call, turn: turn.number, id: call.id, tool: call.full_name, input: call.input,
                          status: result.status, message: result.failed_step&.message,
                          detail: result.failed_step&.detail, outcome_unknown: result.outcome_unknown,
                          ms: ((clock - t0) * 1000).round)
      call
    end

    def refusal(step_name, message, detail: nil)
      failed = StepResult.new(name: step_name, status: :denied, message: message, detail: detail, ms: 0)
      ToolResult.new(status: :denied, input: nil, failed_step: failed, steps: [failed], outcome_unknown: false)
    end

    def track_tool_outcome(call)
      case call.result.status
      when :ok
        @consecutive_errors = 0
      when :denied
        @denials += 1
      when :error
        @consecutive_errors += 1
      end
    end

    def tool_failure_limit
      max_denials = limit(:max_denials)
      max_errors  = limit(:max_tool_errors)
      return :too_many_denials    if max_denials && @denials >= max_denials
      return :too_many_tool_errors if max_errors && @consecutive_errors >= max_errors

      nil
    end

    # -------------------------------------------------------------------------
    # Goal
    # -------------------------------------------------------------------------

    def decide_goal(turn, response)
      candidate = response.output.to_s
      spec      = @config[:goal]

      unless spec
        @final_response = response
        return finish!(:final_answer, candidate)
      end

      verdict = GoalCheckResult.from(run_goal_check(spec, candidate))
      unless GOAL_STATUSES.include?(verdict.status)
        raise ArgumentError, "Goal check returned unknown status #{verdict.status.inspect} (expected one of #{GOAL_STATUSES.join(', ')})"
      end
      turn.verdict = verdict
      journal(:goal, turn: turn.number, status: verdict.status, feedback: verdict.feedback, evidence: verdict.evidence)

      case verdict.status
      when :achieved
        @final_response = response
        finish!(:goal_reached, candidate)
      when :continue, :replan
        fire(:replan, verdict) if verdict.status == :replan
        @goal_retries += 1
        if @goal_retries > limit(:max_goal_retries).to_i
          @output = candidate
          stop!(:goal_failed)
        else
          @state.messages << { role: :user, content: "Goal not reached: #{verdict.feedback || 'try again'}" }
        end
      when :needs_input
        @output = candidate
        stop!(:needs_input)
      when :failed
        @output = candidate
        stop!(:goal_failed)
      end
    end

    def run_goal_check(spec, candidate)
      goal = @state.goal
      case spec
      when Proc  then spec.call(candidate, goal, @state)
      when Class
        if    spec <= Tribunal then judge_with_tribunal(spec, candidate)
        elsif spec <= Request  then judge_with_request(spec, candidate)
        else                        spec.new.call(candidate: candidate, goal: goal, state: @state)
        end
      else spec.call(candidate: candidate, goal: goal, state: @state)
      end
    end

    # A Tribunal as the judge: its verdict becomes a GoalCheckResult.
    #   true               → :achieved
    #   false / nil        → :continue, feedback = the reasons of the answers that did not approve
    #   GoalCheckResult / Hash with :status → used as is
    def judge_with_tribunal(klass, candidate)
      tribunal = klass.new(input: candidate, context: judge_context, params: @params, stream: @stream)
      tribunal.call
      charge(:goal, tribunal)

      verdict = tribunal.verdict
      return verdict if verdict.is_a?(GoalCheckResult) || verdict.is_a?(Hash)
      return GoalCheckResult.new(status: :achieved, evidence: tribunal.results.map(&:output)) if verdict

      GoalCheckResult.new(status: :continue, feedback: dissent_feedback(tribunal.results), evidence: tribunal.results.map(&:output))
    end

    # A Request as the judge: it answers with a Hash ({"status" => "achieved", "feedback" => ...}),
    # or with text starting with yes / true / achieved / done.
    def judge_with_request(klass, candidate)
      request = klass.new(input: candidate, context: judge_context, params: @params, stream: @stream)
      request.call
      charge(:goal, request)

      processed = request.result.processed
      return GoalCheckResult.from(processed) if processed.is_a?(Hash)

      text = request.result.output.to_s
      if text.strip.downcase.start_with?("yes", "true", "achieved", "done")
        GoalCheckResult.new(status: :achieved, evidence: text)
      else
        GoalCheckResult.new(status: :continue, feedback: text[0, 500], evidence: text)
      end
    end

    def judge_context
      @context.merge(goal: @state.goal, agent_state: @state)
    end

    def dissent_feedback(results)
      reasons = results.map do |r|
        processed = r.processed
        reason = processed.is_a?(Hash) ? (processed["reason"] || processed[:reason] || processed["feedback"] || processed[:feedback]) : nil
        (reason || r.output).to_s[0, 200]
      end.reject(&:empty?)
      reasons.empty? ? "The independent review did not approve the answer." : reasons.uniq.join("; ")
    end

    # -------------------------------------------------------------------------
    # Limits
    # -------------------------------------------------------------------------

    def limit(name)
      @config[:limits][name]
    end

    def cost_total
      @state.usage&.cost&.total.to_f
    end

    def cost_exceeded?
      max = limit(:max_cost)
      !max.nil? && cost_total >= max
    end

    # Limits that must hold before another Request is made.
    def limit_reason
      max_turns = limit(:max_turns)
      return :max_turns if max_turns && @state.turn >= max_turns
      return :max_cost  if cost_exceeded?

      nil
    end

    # Checked at the end of a turn that did not finish the run.
    def check_limits(turn)
      @config[:stop_rules].each do |name, block|
        return stop!(name) if instance_exec(turn, &block)
      end

      times = @config[:loop_guard]
      if times && !turn.tool_calls.empty?
        @signatures << turn.tool_calls.map { |c| [c.name, c.input] }
        recent = @signatures.last(times)
        return stop!(:repeating) if recent.size == times && recent.uniq.size == 1
      end

      reason = limit_reason
      stop!(reason) if reason
    end

    # Wraps a bare Request / Tribunal in an implicit one-step Pipeline, so `setup` and
    # `finalize` accept any executor. A Pipeline class is used as is.
    def as_pipeline(executor)
      return executor if executor <= Pipeline

      @wrapped_pipelines ||= {}
      @wrapped_pipelines[executor] ||= Class.new(Pipeline) { step :run, executor }
    end

    # Adds the usage of a nested executor (Pipeline, Tribunal, Request, Agent) to the run total,
    # so that max_cost and agent.usage count every model call made on behalf of this run.
    def charge(source, executor)
      usages = usages_of(executor)
      usages.each { |u| add_usage(u) }
      return if usages.empty?

      journal(:nested_usage, source: source, tokens: usages.sum { |u| u.tokens.total.to_i },
                             cost: usages.sum { |u| u.cost&.total.to_f }.round(8))
    end

    def usages_of(executor, result = nil)
      list =
        if executor.nil?
          [result&.usage]
        elsif executor.respond_to?(:stopped?) && executor.respond_to?(:steps) # Pipeline (also nested)
          executor.steps.to_a.flat_map { |_name, ex, res| usages_of(ex, res) }
        elsif executor.respond_to?(:results)                                  # Tribunal: every member request
          executor.results.map(&:usage)
        else                                                                  # Request / Agent
          [executor.result&.usage]
        end
      list.compact
    end

    def add_usage(usage)
      return unless usage

      total = @state.usage
      total.tokens.input  += usage.tokens.input.to_i
      total.tokens.output += usage.tokens.output.to_i
      total.tokens.total  += usage.tokens.total.to_i

      return unless usage.cost&.total

      total.cost ||= CostBreakdown.new(input: 0.0, output: 0.0, total: 0.0)
      total.cost.input  += usage.cost.input.to_f
      total.cost.output += usage.cost.output.to_f
      total.cost.total  += usage.cost.total.to_f
    end

    # -------------------------------------------------------------------------
    # Tools registry, context
    # -------------------------------------------------------------------------

    def tool_registry
      @tool_registry ||= @config[:tools].each_with_object({}) { |klass, h| h[klass.wire_name] = klass }
    end

    def tool_schemas
      @config[:tools].map(&:to_schema)
    end

    def context_builder
      builder = @config[:context_builder]
      case builder
      when nil   then ContextBuilder.new
      when Class then builder.new
      else            builder
      end
    end

    def symbolize_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    end

    # -------------------------------------------------------------------------
    # Hooks, events, helpers
    # -------------------------------------------------------------------------

    # Refuse a tool call from a :before_tool hook. The message goes to the model.
    def deny!(msg, detail: nil)
      raise Tool::Denied.new(msg, detail: detail)
    end

    def fire(event, *args)
      run_hooks(@config[:hooks], event, *args)
      @stream&.call(:agent, event, *args)
    rescue ClientGone
      nil
    end

    def fire_step(event, step_name, turn)
      run_hooks(@config[:step_hooks][step_name] || {}, event, turn)
    end

    def fire_tool(event, call, *args)
      @config[:tool_hooks].each do |name, hooks|
        next unless name == call.full_name || name == call.name

        run_hooks(hooks, event, *args)
      end
    end

    def journal(type, **data)
      @state.events << { type: type, at: Time.now.utc.iso8601(3) }.merge(data)
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end


