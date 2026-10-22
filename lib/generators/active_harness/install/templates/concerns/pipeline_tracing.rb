require_relative "tracing_log"

# Basic tracing for any Pipeline: every step, a stop, completion.
#
#   class SupportPipeline < ActiveHarness::Pipeline
#     include PipelineTracing
#   end
module PipelineTracing
  def self.included(base)
    base.include TracingLog

    base.before(:step) do |step_name, _payload|
      trace_log "→ :#{step_name}"
    end

    base.after(:step) do |step_name, result|
      trace_log "✓ :#{step_name} (#{result.execution_time}s)"
    end

    base.callback(:stopped) do |step_name, _result|
      trace_log "✗ stopped at :#{step_name}", level: :warn
    end

    base.callback(:complete) do |_last_result|
      trace_log "✓ complete (#{execution_time}s)"
    end
  end
end
