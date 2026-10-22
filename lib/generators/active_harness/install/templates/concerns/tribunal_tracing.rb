require_relative "tracing_log"

# Basic tracing for any Tribunal: start, each finished request, request errors, verdict.
#
#   class SupportGuardTribunal < ActiveHarness::Tribunal
#     include TribunalTracing
#   end
module TribunalTracing
  def self.included(base)
    base.include TracingLog

    base.on(:before_call) do
      trace_log "▶ tribunal started"
    end

    base.on(:after_request) do |result, index|
      trace_log "✓ request #{index + 1} done (#{result.execution_time}s) — #{result.processed}"
    end

    base.on(:request_error) do |name, error, _index|
      trace_log "✗ #{name} failed — #{error&.message}", level: :warn
    end

    base.on(:after_verdict) do |verdict|
      trace_log "verdict: #{verdict.inspect} (#{execution_time}s)", level: verdict ? :info : :warn
    end
  end
end
