begin
  require "concurrent"
rescue LoadError
  raise LoadError,
    "ActiveHarness::Tribunal requires the 'concurrent-ruby' gem. " \
    "Add `gem 'concurrent-ruby'` to your Gemfile."
end

module ActiveHarness
  # Can be used directly or subclassed with a class-level DSL.
  #
  # Direct usage:
  #   tribunal = ActiveHarness::Tribunal.new(
  #     input:   "Is this message toxic?",
  #     context: { user_id: 42 },
  #     agents:  [ToxicityAgent, BiasAgent, SpamAgent],
  #     timeout: 7
  #   )
  #   tribunal.on(:after_agent) { |result| puts result.model }
  #   tribunal.process { |results| results.all? { |r| r.processed["result"] == true } }
  #   tribunal.call
  #
  # Subclass with DSL:
  #   class ContentQualityTribunal < ActiveHarness::Tribunal
  #     agents PolitenessAgent, ConstructivenessAgent
  #     on(:after_agent) { |result| puts result.model }
  #     process { |results| results.all? { |r| r.processed["result"] == true } }
  #   end
  #   ContentQualityTribunal.new(input: "...").call
  #
  class Tribunal
    # -------------------------------------------------------------------------
    # Class-level DSL — core
    # -------------------------------------------------------------------------
    class << self
      # Each subclass gets its own isolated config hash.
      def tribunal_config
        @tribunal_config ||= { agents: [], hooks: {} }
      end

      def inherited(subclass)
        subclass.instance_variable_set(:@tribunal_config, { agents: [], hooks: {} })
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_accessor :input,
                  :context,
                  :params
    attr_reader   :results,
                  :errors,
                  :verdict,
                  :execution_time,
                  :agent_execution_times,
                  :token_stream,
                  :agent_event_stream,
                  :tribunal_event_stream

    def initialize(
      input:    nil,
      context:  {},
      params:   {},
      agents:   nil,
      timeout:  7,
      streams:  {},
      may_fail: :_unset
    )
      config = self.class.tribunal_config

      @input                 = input
      @context               = context
      @params                = params
      @agents                = agents || config[:agents]
      @timeout               = timeout
      @process_block         = config[:process]
      @strategy              = config[:strategy]
      @evaluate_block        = config[:evaluate_block]
      @may_fail              = may_fail == :_unset ? config[:may_fail] : may_fail
      @hooks                 = config[:hooks].transform_values { |v| Array(v).dup }
      @token_stream          = streams[:token]
      @agent_event_stream    = streams[:agent]
      @tribunal_event_stream = streams[:tribunal]
      @results               = []
      @errors                = []
      @verdict               = nil
      @execution_time        = nil
      @agent_execution_times = []
    end

    # Returns a Result with processed: { "verdict" => @verdict } so the pipeline
    # can handle agents and tribunals through the same interface.
    def result
      Result.new(
        input:          @input,
        output:         nil,
        processed:      { "verdict" => @verdict },
        execution_time: @execution_time
      )
    end

    # Run all agents in parallel, then compute the verdict.
    # Returns self so calls can be chained: tribunal.call.verdict
    #
    # Behaviour on failure:
    #   - If some agents fail/timeout, their errors are in #errors and
    #     #results contains only successful results.
    #   - If ALL agents fail/timeout, raises Errors::AllAgentsFailed.
    def call
      agents = resolve_agents
      fire(:before_call)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      futures = agents.each_with_index.map do |agent, index|
        fire(:before_agent, agent, index)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        future = Concurrent::Future.execute { agent.call }
        [future, t0]
      end

      @results               = []
      @errors                = []
      @agent_execution_times = []

      futures.each_with_index do |(future, t0), index|
        future.wait(@timeout)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        @agent_execution_times << { agent: agents[index].class.name, time: elapsed }

        if future.fulfilled?
          value  = future.value
          result = value.is_a?(ActiveHarness::Agent) ? value.result : value
          @results << result
          fire(:after_agent, result, index)
        elsif future.incomplete?
          error = Errors::TimeoutError.new(
            "Agent #{agents[index].class.name} timed out after #{@timeout}s"
          )
          @errors << { agent: agents[index].class.name, error: error }
          fire(:agent_error, agents[index].class.name, error, index)
        else
          @errors << { agent: agents[index].class.name, error: future.reason }
          fire(:agent_error, agents[index].class.name, future.reason, index)
        end
      end

      @execution_time = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)

      fire(:after_call, @results, @errors)

      # If all agents failed, raise an exception.
      # Otherwise, compute the verdict based on successful results.
      check_failure_threshold!

      verdict_input = transform_hook(:before_verdict, @results)
      @verdict      = compute_verdict(verdict_input)

      fire(:after_verdict, @verdict)

      self
    end

    private

    def check_failure_threshold!
      if !@may_fail.nil? && @errors.size > @may_fail
        raise Errors::AllAgentsFailed,
          "Too many agents failed (#{@errors.size} > may_fail: #{@may_fail}) — #{error_summary}"
      elsif @results.empty?
        raise Errors::AllAgentsFailed, "All agents failed — #{error_summary}"
      end
    end

    def error_summary
      @errors.map { |e| "#{e[:agent]}: #{e[:error].message}" }.join("; ")
    end

    def resolve_agents
      agent_streams = { token: @token_stream, agent: @agent_event_stream }.compact
      @agents.map do |agent|
        if agent.is_a?(Class)
          agent.new(input: @input, context: @context.dup, params: @params, streams: agent_streams)
        else
          agent.input = @input if @input
          agent.instance_variable_set(:@token_stream, @token_stream) if @token_stream
          agent.instance_variable_set(:@event_stream, @agent_event_stream) if @agent_event_stream
          agent
        end
      end
    end
  end
end

require_relative "tribunal/hooks"
require_relative "tribunal/dsl"
require_relative "tribunal/processing"
