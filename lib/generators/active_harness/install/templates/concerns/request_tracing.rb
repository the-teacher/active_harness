require_relative "tracing_log"

# Basic tracing for any Request: one line before the call, one after it
# (model, time, tokens, cost), plus retries and total failure.
#
#   class SupportRequest < ActiveHarness::Request
#     include RequestTracing
#   end
#
# Add request-specific details by overriding #tracing_details:
#
#   def tracing_details(result)
#     " spam=#{result.processed&.dig('spam')}"
#   end
module RequestTracing
  def self.included(base)
    base.include TracingLog

    base.before(:call) do
      trace_log "▶ call"
    end

    base.after(:call) do |result|
      tokens = result.usage&.tokens&.total
      cost   = result.usage&.cost&.total
      trace_log "✓ #{result.model.name} #{result.execution_time}s" \
                "#{" tokens=#{tokens}" if tokens}#{format(" cost=$%.6f", cost) if cost}" \
                "#{tracing_details(result)}"
    end

    base.callback(:retry) do |entry, error|
      trace_log "↺ retry #{entry&.dig(:model)} — #{error&.message}", level: :warn
    end

    base.callback(:failure) do |attempts|
      trace_log "✗ all models failed (#{attempts.size} attempts)", level: :error
    end
  end

  # Override to append request-specific details to the "done" line.
  def tracing_details(_result)
    ""
  end
end
