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
  #   tribunal.process { |results| results.all? { |r| r.parsed["result"] == true } }
  #   tribunal.call
  #
  # Subclass with DSL:
  #   class ContentQualityTribunal < ActiveHarness::Tribunal
  #     agents PolitenessAgent, ConstructivenessAgent
  #     on(:after_agent) { |result| puts result.model }
  #     process { |results| results.all? { |r| r.parsed["result"] == true } }
  #   end
  #   ContentQualityTribunal.new(input: "...").call
  #
  class Tribunal
    VALID_HOOKS = %i[
      before_call
      after_agent
      agent_error
      after_call
      before_verdict
      after_verdict
    ].freeze

    # -------------------------------------------------------------------------
    # Class-level DSL — used when subclassing ActiveHarness::Tribunal
    # -------------------------------------------------------------------------
    class << self
      # Declare agents at the class level.
      #   agents PolitenessAgent, ConstructivenessAgent
      def agents(*list)
        tribunal_config[:agents] = list.flatten
      end

      # Class-level hook registration.
      #   on(:after_agent) { |result| puts result.model }
      def on(event, &block)
        unless VALID_HOOKS.include?(event)
          raise ArgumentError, "Unknown Tribunal hook :#{event}. Valid hooks: #{VALID_HOOKS.join(", ")}"
        end

        tribunal_config[:hooks][event] = block
      end

      # Rails-style aliases for +on+:
      #
      #   before :call                     do ... end   # → on :before_call
      #   before :agent                    do ... end   # → on :before_agent (not used yet)
      #   before :verdict                  do |r| end   # → on :before_verdict
      #   after  :call                     do ... end   # → on :after_call
      #   after  :agent                    do |r| end   # → on :after_agent
      #   after  :verdict                  do |v| end   # → on :after_verdict
      #   callback :agent_error            do |n,e| end # → on :agent_error
      def before(event, &block)
        on(:"before_#{event}", &block)
      end

      def after(event, &block)
        on(:"after_#{event}", &block)
      end

      def callback(event, &block)
        on(event, &block)
      end

      # Class-level process block.
      #   process { |results| results.all? { |r| r.parsed["result"] == true } }
      def process(&block)
        tribunal_config[:process] = block
      end

      def tribunal_config
        @tribunal_config ||= { agents: [], hooks: {} }
      end

      def inherited(subclass)
        subclass.instance_variable_set(:@tribunal_config, { agents: [], hooks: {} })
      end
    end

    attr_accessor :input, :context
    attr_reader :results, :errors, :verdict, :execution_time, :agent_execution_times

    def initialize(input: nil, context: {}, agents: nil, timeout: 7)
      config = self.class.tribunal_config

      @input         = input
      @context       = context
      @agents        = agents || config[:agents]
      @timeout       = timeout
      @process_block = config[:process]
      @hooks         = config[:hooks].dup
      @results       = []
      @errors        = []
      @verdict       = nil
      @execution_time       = nil
      @agent_execution_times = []
    end

    # Instance-level hook registration — overrides class-level hooks.
    # :before_verdict is a transform hook: its return value replaces the results array.
    def on(event, &block)
      unless VALID_HOOKS.include?(event)
        raise ArgumentError, "Unknown Tribunal hook :#{event}. Valid hooks: #{VALID_HOOKS.join(", ")}"
      end

      @hooks[event] = block
      self
    end

    # Instance-level process block — overrides class-level block.
    def process(&block)
      @process_block = block
      self
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
      run_hook(:before_call)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      futures = agents.map do |agent|
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        future = Concurrent::Future.execute { agent.call }
        [future, t0]
      end

      @results              = []
      @errors               = []
      @agent_execution_times = []

      futures.each_with_index do |(future, t0), index|
        future.wait(@timeout)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        @agent_execution_times << { agent: agents[index].class.name, time: elapsed }

        if future.fulfilled?
          value = future.value
          result = value.is_a?(ActiveHarness::Agent) ? value.result : value
          @results << result
          run_hook(:after_agent, result)
        elsif future.incomplete?
          error = Errors::TimeoutError.new(
            "Agent #{agents[index].class.name} timed out after #{@timeout}s"
          )
          @errors << { agent: agents[index].class.name, error: error }
          run_hook(:agent_error, agents[index].class.name, error)
        else
          @errors << { agent: agents[index].class.name, error: future.reason }
          run_hook(:agent_error, agents[index].class.name, future.reason)
        end
      end

      @execution_time = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)

      run_hook(:after_call, @results, @errors)

      if @results.empty?
        messages = @errors.map { |e| "#{e[:agent]}: #{e[:error].message}" }.join("; ")
        raise Errors::AllAgentsFailed, "All agents failed — #{messages}"
      end

      verdict_input = transform_hook(:before_verdict, @results)
      @verdict = @process_block ? @process_block.call(verdict_input) : nil
      run_hook(:after_verdict, @verdict)

      self
    end

    private

    def run_hook(event, *args)
      @hooks[event]&.call(*args)
    end

    # Like run_hook but uses the return value to replace the passed value.
    def transform_hook(event, value)
      return value unless @hooks[event]

      @hooks[event].call(value)
    end

    def resolve_agents
      @agents.map do |agent|
        if agent.is_a?(Class)
          agent.new(input: @input, context: @context.dup)
        else
          agent.input = @input if @input
          agent
        end
      end
    end
  end
end
