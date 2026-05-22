require "json"

module ActiveHarness
  class Agent
    # -------------------------------------------------------------------------
    # Class-level DSL — core
    # -------------------------------------------------------------------------
    class << self
      # Class-level entry point.
      #
      #   SupportAgent.call(input: "Hi")
      #   SupportAgent.call(input: "Hi", context: { user_id: 42 })
      #   SupportAgent.call(input: "Hi", memory: memory)
      def call(input: nil, context: {}, models: nil, memory: nil, stream: nil)
        new(input: input, context: context, models: models, memory: memory, stream: stream).call.result
      end

      # Each subclass gets its own isolated config hash.
      def agent_config
        @agent_config ||= {}
      end

      def inherited(subclass)
        subclass.instance_variable_set(:@agent_config, {})
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_accessor :input, :context
    attr_reader :result

    def models=(list)
      @models_override = Array(list)
      @model_list_proxy = nil
    end

    def initialize(input: nil, context: {}, models: nil, memory: nil, stream: nil)
      @input           = input
      @context         = context
      @config          = self.class.agent_config
      @models_override = Array(models) if models
      @stream          = stream
      # memory: can be passed directly or via context[:memory]
      @memory = memory || @context[:memory]
      run_hook(:setup)
    end

    # Attempts each model in order, returns the first successful Result.
    # Raises Errors::AllModelsFailed if every model in the chain fails.
    #
    # Optionally accepts input and stream callback inline:
    #   agent.call("What is the capital of Japan?")
    #   agent.call("...", stream: ->(token) { print token })
    def call(input = nil, stream: nil)
      @input  = input  if input
      @stream = stream if stream
      @memory&.load
      @system_prompt = resolve_system_prompt
      run_hook(:before_call)
      attempts = []

      cfg = ActiveHarness.config

      model_list.each do |entry|
        retry_policy = Http::RetryPolicy.new(
          max_attempts: entry[:retry_attempts] || cfg.retry_default_attempts,
          base_delay:   entry[:retry_delay]    || cfg.retry_default_delay
        )
        t0       = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = retry_policy.run { attempt_model(entry, @system_prompt) }
        elapsed  = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        result   = build_result(response, entry, attempts, elapsed)
        save_to_memory(result)
        run_hook(:after_call, result)
        @result = result
        return self
      rescue *RETRYABLE_ERRORS => e
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        attempts << attempt_entry(entry, e, elapsed)
        run_hook(:retry, entry, e)
        next
      rescue *STOP_ERRORS => e
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        attempts << attempt_entry(entry, e, elapsed)
        run_hook(:retry, entry, e)
        raise
      end

      run_hook(:failure, attempts)
      raise Errors::AllModelsFailed, "All models failed. Attempts: #{attempts.inspect}"
    end

    private

    def attempt_entry(entry, error, elapsed)
      {
        provider:       entry[:provider],
        model:          entry[:model],
        error:          error.message,
        error_code:     error.respond_to?(:error_code) ? error.error_code : nil,
        execution_time: elapsed
      }
    end

    def build_result(response, entry, attempts, elapsed)
      raw    = response[:content]
      parsed = parse_output(raw)

      Result.new(
        input:          @input,
        output:         raw,
        parsed:         parsed,
        system_prompt:  @system_prompt,
        provider:       entry[:provider],
        model:          entry[:model],
        temperature:    entry[:temperature],
        model_list:     model_list,
        attempts:       attempts,
        execution_time: elapsed,
        usage:          response[:usage]
      )
    end

    # Auto-save to memory if no manual record was done in after_call hook.
    # Hooks fire after this method — if a hook calls memory.record manually,
    # the automatic save here is still the first save (hook overrides are additive).
    # To suppress auto-save, set @memory_auto_saved in the hook.
    def save_to_memory(result)
      return unless @memory

      @memory.record(
        request:  @input,
        response: result.output,
        agent:    self.class.name,
        model:    result.model
      )
    end
  end
end

require_relative "agent/prompt"
require_relative "agent/hooks"
require_relative "agent/models"
require_relative "agent/providers"
require_relative "agent/output_parser"

