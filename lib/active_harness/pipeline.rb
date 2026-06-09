module ActiveHarness
  # Sequential pipeline that chains agents and tribunals.
  # Each step receives the current payload and can transform it or stop the pipeline.
  #
  # Usage (subclass with DSL):
  #
  #   class SupportPipeline < ActiveHarness::Pipeline
  #     step :injection_guard do
  #       use InjectionGuardAgent
  #       stop_if ->(result) { result.processed["detected"] == true }
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
      #     stop_if ->(result) { result.processed["detected"] == true }
      #   end
      def step(name, agent_class = nil, &block)
        pipeline_config[:steps] << Pipeline::Step.new(name, agent_class, &block)
      end

      def pipeline_config
        @pipeline_config ||= { steps: [], hooks: {}, step_hooks: {}, streams: {} }
      end

      # Each subclass gets its own isolated config.
      def inherited(subclass)
        subclass.instance_variable_set(
          :@pipeline_config,
          { steps: [], hooks: {}, step_hooks: {}, streams: {} }
        )
      end

      # Class-level event stream handlers — fired for every matching event from
      # any agent or tribunal executed within this pipeline (including agents
      # running inside tribunals). Multiple blocks can be registered; all fire.
      #
      # The handler receives the same (event, *args) signature that the runtime
      # streams: { agent: lambda } would receive.
      #
      #   on_agent_event do |event, result|
      #     Rails.logger.info "[Agent #{event}] #{result.model}" if event == :after_call
      #   end
      #
      #   on_tribunal_event do |event, verdict|
      #     Rails.logger.info "[Tribunal #{event}] verdict=#{verdict}" if event == :after_verdict
      #   end
      #
      #   on_pipeline_event do |event, step_name, _data|
      #     Rails.logger.info "[Pipeline #{event}] step=#{step_name}"
      #   end
      def on_agent_event(&block)
        (pipeline_config[:streams][:agent] ||= []) << block
      end

      def on_tribunal_event(&block)
        (pipeline_config[:streams][:tribunal] ||= []) << block
      end

      def on_pipeline_event(&block)
        (pipeline_config[:streams][:pipeline] ||= []) << block
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_reader   :original_input,
                  :output,
                  :stopped_at,
                  :stop_reason,
                  :execution_time,
                  :step_results,
                  :context
    attr_writer   :context
    attr_accessor :params

    def input=(value)
      @original_input = value
      @payload        = value
    end

    def initialize(
      input:,
      context: {},
      params:  {},
      memory:  nil,
      streams: {}
    )
      @original_input        = input
      @payload               = input
      @context               = context.dup
      @params                = params
      @memory                = memory
      @token_stream          = streams[:token]
      class_streams          = self.class.pipeline_config[:streams] || {}
      @agent_event_stream    = merge_stream(streams[:agent],    class_streams[:agent])
      @tribunal_event_stream = merge_stream(streams[:tribunal], class_streams[:tribunal])
      @pipeline_event_stream = merge_stream(streams[:pipeline], class_streams[:pipeline])
      @step_results          = {}
      @stopped               = false
      @stopped_at            = nil
      @stop_reason           = nil
      @execution_time        = nil
      @output                = nil
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
        fire(:before_step, step.name, @payload, config)
        fire_step(:before_step, step.name, @payload, config)

        result = execute_step(step)

        @step_results[step.name] = result
        @context[step.name]      = result
        @payload                 = result.output if step.transform?

        fire(:after_step, step.name, result, config)
        fire_step(:after_step, step.name, result, config)

        if step.stop_if && step.stop_if.call(result)
          @stopped     = true
          @stopped_at  = step.name
          @stop_reason = result
          run_hooks(config[:hooks], :stopped, step.name, result)
          @pipeline_event_stream&.call(:stopped, step.name, result)
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
        run_hooks(config[:hooks], :complete, last_result)
        @pipeline_event_stream&.call(:complete, last_result)
      end

      self
    end

    private

    # Combines a runtime-passed stream lambda with zero or more class-level handler
    # blocks registered via on_agent_event / on_tribunal_event / on_pipeline_event.
    # Returns nil when there are no handlers at all, preserving the existing
    # "no stream" fast path in agents and tribunals.
    #
    # Each class-level handler is evaluated via instance_exec so that blocks
    # written in the pipeline class body can access pipeline instance variables
    # (e.g. @otel_pipeline_span, @params) and call pipeline instance methods.
    def merge_stream(passed_in, class_handlers)
      class_handlers = Array(class_handlers).compact
      return passed_in if class_handlers.empty?

      pipeline_instance = self
      ->(event, *args) {
        class_handlers.each { |h| pipeline_instance.instance_exec(event, *args, &h) }
        passed_in&.call(event, *args)
      }
    end

    def execute_step(step)
      streams = { token: @token_stream, agent: @agent_event_stream, tribunal: @tribunal_event_stream }.compact
      step.agent_class.new(
        input:   @payload,
        context: @context.dup,
        params:  @params,
        streams: streams
      ).call.result
    end
  end
end

require_relative "pipeline/hooks"
require_relative "pipeline/step"
