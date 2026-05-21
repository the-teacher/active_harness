module ActiveHarness
  # Sequential pipeline that chains agents and tribunals.
  # Each step receives the current payload and can transform it or stop the pipeline.
  #
  # Usage (subclass with DSL):
  #
  #   class SupportPipeline < ActiveHarness::Pipeline
  #     step :injection_guard do
  #       use InjectionGuardAgent
  #       stop_if ->(result) { result.parsed["detected"] == true }
  #     end
  #
  #     step :translate, TranslationAgent   # shorthand — no stop_if
  #
  #     step :safety_tribunal do
  #       use SafetyTribunal
  #       stop_if ->(result) { result.verdict == false }
  #     end
  #
  #     on :before_step do |step_name, payload| ... end
  #     on :after_step  do |step_name, result|  ... end
  #     on :before_step, :translate do |payload| ... end
  #     on :after_step,  :translate do |result|  ... end
  #     on :stopped  do |step_name, result| ... end
  #     on :complete do |last_result|       ... end
  #   end
  #
  #   pipeline = SupportPipeline.new(input: "...", context: { user_id: 1 })
  #   pipeline.call
  #   pipeline.output       # => final payload string (nil if stopped)
  #   pipeline.stopped?     # => false
  #   pipeline.step_results # => { translate: <Result>, ... }
  #
  class Pipeline
    VALID_HOOKS      = %i[before_step after_step stopped complete].freeze
    VALID_STEP_HOOKS = %i[before_step after_step].freeze

    # -------------------------------------------------------------------------
    # Class-level DSL
    # -------------------------------------------------------------------------
    class << self
      # Define a step in the pipeline.
      #
      # Shorthand (agent only, no stop_if):
      #   step :translate, TranslationAgent
      #
      # Full block form:
      #   step :injection_guard do
      #     use InjectionGuardAgent
      #     stop_if ->(result) { result.parsed["detected"] == true }
      #   end
      def step(name, agent_class = nil, &block)
        pipeline_config[:steps] << Pipeline::Step.new(name, agent_class, &block)
      end

      # Register a global or per-step hook.
      #
      # Global hooks fire on every step:
      #   on :before_step do |step_name, payload| ... end
      #   on :after_step  do |step_name, result|  ... end
      #   on :stopped     do |step_name, result|  ... end
      #   on :complete    do |last_result|         ... end
      #
      # Per-step hooks fire only for the named step (no step_name passed):
      #   on :before_step, :translate do |payload| ... end
      #   on :after_step,  :translate do |result|  ... end
      def on(event, step_name = nil, &block)
        if step_name
          unless VALID_STEP_HOOKS.include?(event)
            raise ArgumentError,
              "Per-step hooks support: #{VALID_STEP_HOOKS.join(", ")}. Got :#{event}"
          end
          pipeline_config[:step_hooks][step_name] ||= {}
          pipeline_config[:step_hooks][step_name][event] = block
        else
          unless VALID_HOOKS.include?(event)
            raise ArgumentError,
              "Unknown Pipeline hook :#{event}. Valid: #{VALID_HOOKS.join(", ")}"
          end
          pipeline_config[:hooks][event] = block
        end
      end

      # Rails-style aliases for +on+:
      #
      # Global:
      #   before :step                          do |name, payload| end  # → on :before_step
      #   after  :step                          do |name, result|  end  # → on :after_step
      #   callback :stopped                     do |name, result|  end  # → on :stopped
      #   callback :complete                    do |result|        end  # → on :complete
      #
      # Per-step:
      #   after  :step, :translate              do |result| end
      #   before :step, :translate              do |payload| end
      def before(event, step_name = nil, &block)
        on(:"before_#{event}", step_name, &block)
      end

      def after(event, step_name = nil, &block)
        on(:"after_#{event}", step_name, &block)
      end

      def callback(event, &block)
        on(event, &block)
      end

      def pipeline_config
        @pipeline_config ||= { steps: [], hooks: {}, step_hooks: {} }
      end

      # Each subclass gets its own isolated config.
      def inherited(subclass)
        subclass.instance_variable_set(
          :@pipeline_config,
          { steps: [], hooks: {}, step_hooks: {} }
        )
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_reader :original_input, :output, :stopped_at, :stop_reason,
                :execution_time, :step_results, :context
    attr_writer :context

    def input=(value)
      @original_input = value
      @payload        = value
    end

    def initialize(input:, context: {}, memory: nil)
      @original_input = input
      @payload        = input
      @context        = context.dup
      @memory         = memory
      @step_results   = {}
      @stopped        = false
      @stopped_at     = nil
      @stop_reason    = nil
      @execution_time = nil
      @output         = nil
    end

    def stopped?
      @stopped
    end

    # Execute all steps sequentially. Returns self for chaining.
    def call
      config = self.class.pipeline_config
      t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @memory&.load

      config[:steps].each do |step|
        fire_global(:before_step, step.name, @payload, config)
        fire_step(:before_step, step.name, @payload, config)

        result = execute_step(step)

        @step_results[step.name] = result
        @context[step.name]      = result
        @payload                 = result.output if step.transform?

        fire_global(:after_step, step.name, result, config)
        fire_step(:after_step, step.name, result, config)

        if step.stop_if && step.stop_if.call(result)
          @stopped     = true
          @stopped_at  = step.name
          @stop_reason = result
          config[:hooks][:stopped]&.call(step.name, result)
          break
        end
      end

      @execution_time = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
      @output         = @payload unless @stopped

      unless @stopped
        @memory&.record(
          request:  @original_input,
          response: @output,
          pipeline: self.class.name
        )

        last_result = @step_results[@step_results.keys.last]
        config[:hooks][:complete]&.call(last_result)
      end

      self
    end

    private

    def execute_step(step)
      step.agent_class.new(input: @payload, context: @context.dup).call
    end

    # Global hook: receives (step_name, data)
    def fire_global(event, step_name, data, config)
      config[:hooks][event]&.call(step_name, data)
    end

    # Per-step hook: receives (data) only
    def fire_step(event, step_name, data, config)
      config[:step_hooks][step_name]&.dig(event)&.call(data)
    end
  end
end

require_relative "pipeline/step"
