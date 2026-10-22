require "json"

module ActiveHarness
  # One step of a tool call, as recorded in ToolResult#steps.
  #
  #   name    — step name (:perform for the action itself)
  #   status  — :ok | :denied | :error
  #   message — safe text; the ONLY thing the model may see
  #   detail  — internals (paths, policy names, exception class) for traces/logs only
  #   ms      — duration in milliseconds
  StepResult = Struct.new(:name, :status, :message, :detail, :ms, keyword_init: true)

  # Outcome of Tool.call. Never an exception for expected failures.
  #
  #   status           — :ok | :denied | :error
  #   input            — arguments as the tool received them
  #   output           — value returned by +perform+ (nil unless :ok)
  #   failed_step      — StepResult of the step that stopped the call (nil when :ok)
  #   steps            — StepResult of every step that ran
  #   outcome_unknown  — true when the tool reported that a side effect may have happened
  ToolResult = Struct.new(:status, :input, :output, :failed_step, :steps, :outcome_unknown, keyword_init: true) do
    def ok?;      status == :ok;      end
    def denied?;  status == :denied;  end
    def error?;   status == :error;   end

    # Text for the `tool` message sent back to the model.
    def model_message
      case status
      when :ok
        output.is_a?(String) ? output : JSON.generate(output)
      else
        failed_step&.message.to_s
      end
    end

    def execution_time
      (steps || []).sum { |s| s.ms.to_i } / 1000.0
    end
  end

  # A privileged action behind named, ordered steps (checks and transforms).
  # The model never gets a shell — it can only call tools you wrote, and every
  # call passes through your checks first.
  #
  #   class LsTool < ActiveHarness::Tool
  #     tool_scope  :os
  #     tool_name   "ls"
  #     description "List files in a directory"
  #     param :path, "Directory to list"
  #
  #     step :no_hidden do |input|
  #       deny!("hidden dirs are off limits") if input[:path].include?("/.")
  #     end
  #
  #     def perform(input)
  #       Dir.children(input[:path]).first(200)
  #     end
  #   end
  #
  #   LsTool.call(input: { path: "/srv" }, context: { user: current_user }) # => ToolResult
  class Tool
    # Raised (via #deny!) from any step or hook: the call is refused. +message+ is
    # safe for the model; +detail+ stays in the trace.
    class Denied < StandardError
      attr_reader :detail

      def initialize(message = nil, detail: nil)
        super(message)
        @detail = detail
      end
    end

    # Raised (via #unknown_outcome!) when a side effect may or may not have happened
    # (e.g. a timeout after a write was sent). Result: status :error, outcome_unknown: true.
    # Deliberately NOT a Denied, so it never matches `rescue Denied`.
    class UnknownOutcome < StandardError
      attr_reader :detail

      def initialize(message = nil, detail: nil)
        super(message)
        @detail = detail
      end
    end

    Step    = Struct.new(:name, :block, :transform)
    PERFORM = Step.new(:perform, nil, true)

    VALID_HOOKS      = %i[before_step after_step before_perform after_perform].freeze
    VALID_STEP_HOOKS = %i[before_step after_step].freeze

    GENERIC_ERROR_MESSAGE   = "tool failed, try another approach or finish".freeze
    UNKNOWN_OUTCOME_MESSAGE = "result unknown, verify before retrying".freeze

    # -------------------------------------------------------------------------
    # Class-level DSL
    # -------------------------------------------------------------------------
    class << self
      # --- what the model sees ---

      # Required namespace: :os, :web, :ruby ... Full name is "tool_scope::tool_name".
      # Both are explicit on purpose: the name the model sees must not change when a class is renamed.
      def tool_scope(value = nil)
        value ? @tool_scope = value.to_sym : @tool_scope
      end

      # Required: "ls", "fetch_url" ...
      def tool_name(value = nil)
        value ? @tool_name = value.to_s : @tool_name
      end

      def full_name
        raise ArgumentError, "#{name || 'Tool'} must declare a tool_scope (e.g. `tool_scope :os`)" unless tool_scope
        raise ArgumentError, "#{name || 'Tool'} must declare a tool_name (e.g. `tool_name \"ls\"`)" unless tool_name

        "#{tool_scope}::#{tool_name}"
      end

      # Name on the wire: providers allow only [a-zA-Z0-9_-] in function names.
      def wire_name
        full_name.sub("::", "__")
      end

      def description(value = nil)
        value ? @description = value : @description
      end

      # Declares one argument for the model.
      #
      #   param :path, "Directory to list"                      # type: :string, required: true
      #   param :limit, "Max entries", type: :integer, required: false
      #   param :kind, "Entry kind", enum: %w[file dir]
      def param(name, description, type: :string, required: true, enum: nil)
        params << { name: name.to_sym, description: description, type: type, required: required, enum: enum }.reject { |_, v| v.nil? }
      end

      def params
        @params ||= []
      end

      # Argument list (same data as +param+ builds); may be overridden by hand.
      def schema
        params
      end

      # Provider-neutral function schema; providers map it to their wire format.
      #   { name: "os__ls", description: "...", parameters: { type: "object", properties: {...}, required: [...] } }
      def to_schema
        props = {}
        required = []
        schema.each do |arg|
          prop = { type: (arg[:type] || :string).to_s }
          prop[:description] = arg[:description] if arg[:description]
          prop[:enum]        = arg[:enum]        if arg[:enum]
          props[arg[:name].to_s] = prop
          required << arg[:name].to_s if arg.fetch(:required, true)
        end

        {
          name:        wire_name,
          description: description.to_s,
          parameters:  { type: "object", properties: props, required: required }
        }
      end

      # Checks arguments against +schema+. Returns an error message String or nil.
      # Used by the Agent before running the tool (tools themselves get raw input).
      def validate_input(input)
        return "arguments must be an object" unless input.is_a?(Hash)

        known = schema.map { |a| a[:name].to_sym }
        extra = input.keys.map(&:to_sym) - known
        return "unknown argument: #{extra.first}" unless extra.empty?

        schema.each do |arg|
          key   = arg[:name].to_sym
          value = input.key?(key) ? input[key] : input[key.to_s]
          return "missing required argument: #{key}" if arg.fetch(:required, true) && value.nil?
          if arg[:enum] && !value.nil? && !arg[:enum].include?(value)
            return "invalid value for #{key}: expected one of #{arg[:enum].join(', ')}"
          end
        end
        nil
      end

      # --- what the model does NOT see: ordered, named steps ---

      # step :name do |input| ... end        — a block
      # step :name                           — calls the instance method of the same name
      # step :name, transform: true { ... }  — the return value replaces the payload for later steps and perform
      def step(name, transform: false, &block)
        steps << Step.new(name.to_sym, block, transform)
      end

      def steps
        @steps ||= []
      end

      def hooks
        @hooks ||= {}
      end

      def step_hooks
        @step_hooks ||= {}
      end

      # Hooks run through instance_exec on the tool instance (they see context, payload, output).
      #
      #   on :before_step,    :resolve_path do |payload| ... end   # per-step form
      #   on :before_step   do |step_name, payload| ... end
      #   on :after_step    do |step_name, step_result| ... end
      #   on :before_perform do |payload| ... end
      #   on :after_perform  do |output| ... end
      def on(event, step_name = nil, &block)
        if step_name
          raise ArgumentError, "Per-step hooks support: #{VALID_STEP_HOOKS.join(', ')}. Got :#{event}" unless VALID_STEP_HOOKS.include?(event)

          ((step_hooks[step_name.to_sym] ||= {})[event] ||= []) << block
        else
          raise ArgumentError, "Unknown Tool hook :#{event}. Valid: #{VALID_HOOKS.join(', ')}" unless VALID_HOOKS.include?(event)

          (hooks[event] ||= []) << block
        end
      end

      def before(event, step_name = nil, &block)
        on(:"before_#{event}", step_name, &block)
      end

      def after(event, step_name = nil, &block)
        on(:"after_#{event}", step_name, &block)
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@tool_scope, @tool_scope)
        subclass.instance_variable_set(:@steps, steps.dup)
        subclass.instance_variable_set(:@params, params.map(&:dup))
        subclass.instance_variable_set(:@hooks, hooks.each_with_object({}) { |(k, v), h| h[k] = v.dup })
        subclass.instance_variable_set(:@step_hooks, step_hooks.each_with_object({}) { |(k, v), h| h[k] = v.transform_values(&:dup) })
      end

      # Same style as Request.call.
      def call(input:, context: {})
        new(context: context).call(input)
      end
    end

    include Core::HookRunner

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_reader   :context
    attr_accessor :payload, :output

    def initialize(context: {})
      @context = context
    end

    # Entry point used by the Agent loop. Never raises for expected failures.
    def call(input)
      @payload = input
      @output  = nil
      steps    = []

      (self.class.steps + [PERFORM]).each do |step|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        status, message, detail, unknown = :ok, nil, nil, false

        begin
          fire(:before_step, step.name, @payload)
          fire_step(:before_step, step.name, @payload)
          fire(:before_perform, @payload) if step.name == :perform

          value = run_step(step)
          @payload = value if step.transform

          if step.name == :perform
            @output = value
            fire(:after_perform, @output)
          end
        rescue Denied => e
          status, message, detail = :denied, e.message, e.detail
        rescue UnknownOutcome => e
          status, message, detail, unknown = :error, UNKNOWN_OUTCOME_MESSAGE, e.detail || e.message, true
        rescue StandardError => e
          status, message, detail = :error, GENERIC_ERROR_MESSAGE, "#{e.class}: #{e.message}"
        end

        steps << StepResult.new(name: step.name, status: status, message: message, detail: detail, ms: elapsed_ms(started))
        fire(:after_step, step.name, steps.last)
        fire_step(:after_step, step.name, steps.last)

        next if status == :ok

        return ToolResult.new(status: status, input: input, failed_step: steps.last, steps: steps, outcome_unknown: unknown)
      end

      ToolResult.new(status: :ok, input: input, output: @output, steps: steps, outcome_unknown: false)
    end

    # The action itself. Always the last step; its return value is the output.
    def perform(_input)
      raise NotImplementedError, "#{self.class.name} must implement #perform"
    end

    # Refuse the call. +msg+ is shown to the model; +detail+ only goes to the trace.
    def deny!(msg, detail: nil)
      raise Denied.new(msg, detail: detail)
    end

    # The side effect may have happened — the model is told to verify before retrying.
    def unknown_outcome!(msg = nil, detail: nil)
      raise UnknownOutcome.new(msg || "unknown outcome", detail: detail)
    end

    private

    def run_step(step)
      if step.name == :perform
        perform(@payload)
      elsif step.block
        instance_exec(@payload, &step.block)
      else
        send(step.name, @payload)
      end
    end

    def fire(event, *args)
      run_hooks(self.class.hooks, event, *args)
    end

    # Per-step hook: receives only the data, not the step name.
    def fire_step(event, step_name, data)
      run_hooks(self.class.step_hooks[step_name] || {}, event, data)
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
  end
end

require_relative "tool/path_policy"
