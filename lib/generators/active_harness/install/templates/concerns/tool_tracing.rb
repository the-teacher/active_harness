require_relative "tracing_log"

# Basic tracing for any Tool: every step with its status. A refused or failed
# step is logged with its internal `detail` — that text never reaches the model.
#
#   class LsTool < ActiveHarness::Tool
#     include ToolTracing
#   end
module ToolTracing
  def self.included(base)
    base.include TracingLog

    base.on(:after_step) do |step_name, step|
      if step.status == :ok
        trace_log "✓ #{step_name} (#{step.ms}ms)", level: :debug
      else
        trace_log "✗ #{step_name} #{step.status}: #{step.message}#{" [#{step.detail}]" if step.detail}", level: :warn
      end
    end
  end
end
