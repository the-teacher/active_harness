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
  #     input:    "Is this message toxic?",
  #     context:  { user_id: 42 },
  #     requests: [ToxicityRequest, BiasRequest, SpamRequest],
  #     timeout:  7
  #   )
  #   tribunal.on(:after_request) { |result| puts result.model }
  #   tribunal.process { |results| results.all? { |r| r.processed["result"] == true } }
  #   tribunal.call
  #
  # Subclass with DSL:
  #   class ContentQualityTribunal < ActiveHarness::Tribunal
  #     requests PolitenessRequest, ConstructivenessRequest
  #     on(:after_request) { |result| puts result.model }
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
        @tribunal_config ||= { requests: [], hooks: {} }
      end

      def inherited(subclass)
        subclass.instance_variable_set(:@tribunal_config, { requests: [], hooks: {} })
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------
    attr_accessor :input,
                  :context,
                  :params,
                  :memory
    attr_reader   :results,
                  :errors,
                  :verdict,
                  :execution_time,
                  :request_execution_times,
                  :token,
                  :stream

    def initialize(
      input:    nil,
      context:  {},
      params:   {},
      memory:   nil,
      requests: nil,
      timeout:  7,
      token:    nil,
      stream:   nil,
      may_fail: :_unset
    )
      config = self.class.tribunal_config

      @input                   = input
      @context                 = context
      @params                  = params
      @memory                  = memory
      @requests                = requests || config[:requests]
      @timeout                 = timeout
      @process_block           = config[:process]
      @strategy                = config[:strategy]
      @evaluate_block          = config[:evaluate_block]
      @may_fail                = may_fail == :_unset ? config[:may_fail] : may_fail
      @hooks                   = config[:hooks].transform_values { |v| Array(v).dup }
      @token                   = token
      @stream                  = stream
      @results                 = []
      @errors                  = []
      @verdict                 = nil
      @execution_time          = nil
      @request_execution_times = []
    end

    # Returns a Result with processed: { "verdict" => @verdict } so the pipeline
    # can handle requests and tribunals through the same interface.
    def result
      Result.new(
        input:          @input,
        output:         nil,
        processed:      { "verdict" => @verdict },
        execution_time: @execution_time
      )
    end

    # Run all requests in parallel, then compute the verdict.
    # Returns self so calls can be chained: tribunal.call.verdict
    #
    # Accepts an optional input to update payload before running — matches
    # the Request#call(input) interface so tribunals work as pipeline executors.
    #
    # Behaviour on failure:
    #   - If some requests fail/timeout, their errors are in #errors and
    #     #results contains only successful results.
    #   - If ALL requests fail/timeout, raises Errors::AllRequestsFailed.
    def call(input = nil, token: nil, stream: nil)
      @input  = input  if input
      @token  = token  if token
      @stream = stream if stream
      requests = resolve_requests
      fire(:before_call)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      futures = requests.each_with_index.map do |request, index|
        fire(:before_request, request, index)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        future = Concurrent::Future.execute { request.call }
        [future, t0]
      end

      @results                 = []
      @errors                  = []
      @request_execution_times = []

      futures.each_with_index do |(future, t0), index|
        future.wait(@timeout)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(3)
        @request_execution_times << { request: requests[index].class.name, time: elapsed }

        if future.fulfilled?
          value  = future.value
          result = value.is_a?(ActiveHarness::Request) ? value.result : value
          @results << result
          fire(:after_request, result, index)
        elsif future.incomplete?
          error = Errors::TimeoutError.new(
            "Request #{requests[index].class.name} timed out after #{@timeout}s"
          )
          @errors << { request: requests[index].class.name, error: error }
          fire(:request_error, requests[index].class.name, error, index)
        else
          @errors << { request: requests[index].class.name, error: future.reason }
          fire(:request_error, requests[index].class.name, future.reason, index)
        end
      end

      @execution_time = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3)

      fire(:after_call, @results, @errors)

      # If all requests failed, raise an exception.
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
        raise Errors::AllRequestsFailed,
          "Too many requests failed (#{@errors.size} > may_fail: #{@may_fail}) — #{error_summary}"
      elsif @results.empty?
        raise Errors::AllRequestsFailed, "All requests failed — #{error_summary}"
      end
    end

    def error_summary
      @errors.map { |e| "#{e[:request]}: #{e[:error].message}" }.join("; ")
    end

    def resolve_requests
      @requests.map do |request|
        if request.is_a?(Class)
          request.new(input: @input, context: @context.dup, params: @params, token: @token, stream: @stream)
        else
          request.input = @input if @input
          request.instance_variable_set(:@token,  @token)  if @token
          request.instance_variable_set(:@stream, @stream) if @stream
          request
        end
      end
    end
  end
end

require_relative "tribunal/hooks"
require_relative "tribunal/dsl"
require_relative "tribunal/processing"
