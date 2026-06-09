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
      def call(
        input:   nil,
        context: {},
        params:  {},
        memory:  nil,
        models:  nil,
        streams: {}
      )
        new(
          input:   input,
          context: context,
          params:  params,
          memory:  memory,
          models:  models,
          streams: streams
        ).call
      end

      # Each subclass gets its own isolated config hash.
      def agent_config
        @agent_config ||= {}
      end

      def inherited(subclass)
        subclass.instance_variable_set(:@agent_config, {})
      end

      # Automatically strip and collapse whitespace in @input before each call.
      # Enabled by default. Disable with:
      #
      #   normalize_input false
      def normalize_input(value = true)
        agent_config[:normalize_input] = value
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_accessor :input,
                  :context,
                  :params,
                  :memory
    attr_reader   :result,
                  :token_stream,
                  :event_stream

    def models=(list)
      @models_override = Array(list)
      @model_list_proxy = nil
    end

    def initialize(
      input:   nil,
      context: {},
      params:  {},
      memory:  nil,
      models:  nil,
      streams: {}
    )
      @input           = input
      @config          = self.class.agent_config
      normalize_input!
      @context         = context
      @params          = params
      @memory          = memory
      @models_override = Array(models) if models
      @token_stream    = streams[:token]
      @event_stream    = streams[:agent]
      fire(:setup)
    end

    # Attempts each model in order, returns the first successful Result.
    # Raises Errors::AllModelsFailed if every model in the chain fails.
    #
    # Optionally accepts input and stream callback inline:
    #   agent.call("What is the capital of Japan?")
    #   agent.call("...", stream: ->(token) { print token })
    def call(input = nil, streams: nil)
      if input
        @input = input
        normalize_input!
      end
      if streams
        @token_stream = streams[:token] if streams.key?(:token)
        @event_stream = streams[:agent] if streams.key?(:agent)
      end
      fire(:before_call)
      @system_prompt = resolve_system_prompt
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
        fire(:after_call, result)
        @result = result
        return self
      rescue *RETRYABLE_ERRORS => e
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        attempts << attempt_entry(entry, e, elapsed)
        fire(:retry, entry, e)
        next
      rescue *STOP_ERRORS => e
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        attempts << attempt_entry(entry, e, elapsed)
        fire(:retry, entry, e)
        raise
      end

      fire(:failure, attempts)
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
      processed = parse_output(raw)
      usage  = response[:usage]

      Result.new(
        input:          @input,
        output:         raw,
        processed:      processed,
        system_prompt:  @system_prompt,
        provider:       entry[:provider],
        model:          entry[:model],
        temperature:    entry[:temperature],
        model_list:     model_list,
        attempts:       attempts,
        execution_time: elapsed,
        usage:          usage,
        cost:           calculate_cost(entry[:model], usage)
      )
    end

    def normalize_input!
      return if @config.fetch(:normalize_input, true) == false
      @input = @input&.strip&.gsub(/\s+/, " ")
    end
  end
end

require_relative "agent/prompt"
require_relative "agent/hooks"
require_relative "agent/models"
require_relative "agent/providers"
require_relative "agent/output_parser"
require_relative "agent/custom_llm_backend"
require_relative "agent/cost"

