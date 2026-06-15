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
  #       stop_if ->(result) { result.processed["verdict"] == false }
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
  #   pipeline.steps { |name, result| ... }  # iterate over completed steps
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
      def step(name, executor = nil, &block)
        pipeline_config[:steps] << Pipeline::Step.new(name, executor, &block)
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
      # The handler receives (event, *args) — already scoped to the source.
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
      token:   nil,
      stream:  nil
    )
      @original_input = input
      @payload        = input
      @context        = context.dup
      @params         = params
      @memory         = memory
      @token          = token
      class_streams   = self.class.pipeline_config[:streams] || {}
      @stream         = merge_stream(stream, class_streams)
      @executors      = build_executors
      @step_results   = {}
      @stopped        = false
      @stopped_at     = nil
      @stop_reason    = nil
      @execution_time = nil
      @output         = nil
    end

    # Returns a hash of pre-created executor instances keyed by step name.
    # Available immediately after new — before call — so instances can be
    # configured (model lists, params, etc.) before execution begins.
    #
    #   pipeline = SupportPipeline.new(input: "...")
    #   pipeline.executors[:translate].models.prepend(provider: :openai, model: "gpt-4.1")
    #   pipeline.executors[:guard].params = { strict: true }
    #   pipeline.call
    def executors
      @executors
    end

    def stopped?
      @stopped
    end

    # Iterates over completed steps as (name, executor, result) tuples.
    # Steps that did not run (pipeline stopped before reaching them) are skipped.
    # Returns an Enumerator when called without a block.
    #
    #   pipeline.steps { |name, executor, result| }
    #
    #   name     — step name symbol          (:translate, :guard, …)
    #   executor — the instance that ran     (TranslationAgent instance, …)
    #   result   — Result struct             (output, processed, usage, model, …)
    #
    #   pipeline.steps.map { |name, executor, result| [name, result.output] }
    #   pipeline.steps.to_a
    def steps
      return enum_for(:steps) unless block_given?
      self.class.pipeline_config[:steps].each do |step|
        result = @step_results[step.name]
        next unless result
        yield step.name, @executors[step.name], result
      end
      self
    end

    # Wraps pipeline outcome into a Result so a pipeline can be used as a step
    # inside another pipeline, matching the same interface as Agent and Tribunal.
    #
    # output    — final payload (nil when stopped)
    # processed — { "stopped" => bool, "stopped_at" => step_name_string_or_nil }
    def result
      Result.new(
        input:          @original_input,
        output:         @output,
        processed:      { "stopped" => @stopped, "stopped_at" => @stopped_at&.to_s },
        execution_time: @execution_time
      )
    end

    # Execute all steps sequentially. Returns self for chaining.
    # Accepts optional input, token, stream to match the Agent/Tribunal call interface.
    def call(input = nil, token: nil, stream: nil)
      if input
        @original_input = input
        @payload        = input
      end
      @token  = token  if token
      @stream = stream if stream

      config = self.class.pipeline_config
      t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @memory&.load

      config[:steps].each do |step|
        fire(:before_step, step.name, @payload, config)
        fire_step(:before_step, step.name, @payload, config)

        result = execute_step(step)

        @step_results[step.name] = result
        @context[step.name]      = result
        @payload                 = step.extract_payload(result) if step.transform?

        fire(:after_step, step.name, result, config)
        fire_step(:after_step, step.name, result, config)

        if step.stop_if && step.stop_if.call(result)
          @stopped     = true
          @stopped_at  = step.name
          @stop_reason = result
          run_hooks(config[:hooks], :stopped, step.name, result)
          @stream&.call(:pipeline, :stopped, step.name, result)
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
        @stream&.call(:pipeline, :complete, last_result)
      end

      self
    end

    private

    # Combines a runtime-passed stream lambda with class-level handler blocks
    # registered via on_agent_event / on_tribunal_event / on_pipeline_event.
    # Returns nil when there are no handlers at all.
    #
    # Class-level handlers receive (event, *args) — already scoped to source.
    # Runtime lambda receives (source, event, *args).
    # instance_exec lets class-level blocks access pipeline instance variables.
    def merge_stream(passed_in, class_handlers)
      agent_handlers    = Array(class_handlers[:agent]).compact
      tribunal_handlers = Array(class_handlers[:tribunal]).compact
      pipeline_handlers = Array(class_handlers[:pipeline]).compact

      has_class_handlers = agent_handlers.any? || tribunal_handlers.any? || pipeline_handlers.any?
      return passed_in unless has_class_handlers

      pipeline_instance = self
      ->(source, event, *args) {
        handlers = case source
                   when :agent    then agent_handlers
                   when :tribunal then tribunal_handlers
                   when :pipeline then pipeline_handlers
                   else                []
                   end
        handlers.each { |h| pipeline_instance.instance_exec(event, *args, &h) }
        passed_in&.call(source, event, *args)
      }
    end

    def execute_step(step)
      if step.lambda?
        execute_lambda_step(step)
      else
        instance         = @executors[step.name]
        instance.context = @context.dup
        instance.call(@payload).result
      end
    end

    def execute_lambda_step(step)
      lam    = step.executor
      has_kw = lam.parameters.any? { |type, _| [:key, :keyreq, :keyrest].include?(type) }
      result = has_kw ? lam.call(@payload, context: @context.dup, params: @params) : lam.call(@payload)

      unless result.is_a?(Result)
        raise ArgumentError,
          "Lambda step :#{step.name} must return ActiveHarness::Result, got #{result.class}"
      end

      result
    end

    def build_executors
      self.class.pipeline_config[:steps].each_with_object({}) do |step, hash|
        next if step.lambda?

        hash[step.name] = step.executor.new(
          input:   @payload,
          context: @context.dup,
          params:  @params,
          token:   @token,
          stream:  @stream
        )
      end
    end
  end
end

require_relative "pipeline/hooks"
require_relative "pipeline/step"
