require_relative "tracing_log"

# Basic tracing for any Agent: turns, tool calls (with refusals), the stop
# reason and a final summary.
#
#   class FilesAgent < ActiveHarness::Agent
#     include AgentTracing
#   end
module AgentTracing
  def self.included(base)
    base.include TracingLog

    base.on(:before_turn) do |turn|
      trace_log "turn #{turn.number}"
    end

    base.on(:after_tool) do |call, result|
      if result.status == :ok
        trace_log "  tool #{call.full_name} ok #{call.input.inspect}"
      else
        step = result.failed_step
        trace_log "  tool #{call.full_name} #{result.status} at #{step.name}: #{step.message}#{" [#{step.detail}]" if step.detail}", level: :warn
      end
    end

    base.on(:stopped) do |reason|
      trace_log "stopped: #{reason}", level: :warn
    end

    base.on(:complete) do |result|
      usage = result.usage
      trace_log "#{status}/#{stop_reason} — #{turns.size} turns, #{tool_calls.size} tool calls (#{denied_calls.size} refused or failed), " \
                "#{usage&.tokens&.total.to_i} tokens#{format(", $%.6f", usage.cost.total) if usage&.cost}, #{result.execution_time}s"
    end
  end
end
