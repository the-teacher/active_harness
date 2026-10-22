require_relative "../tribunals/support_guard_tribunal"
require_relative "../requests/support_request"
require_relative "../concerns/pipeline_tracing"

# Two-step pipeline: spam guard → answer.
# Add more steps between them as needed.
class SupportPipeline < ActiveHarness::Pipeline
  include PipelineTracing

  # A GUARD step: cheap checks first, so no tokens are spent on an answer that
  # should never be generated. A tribunal step only judges — it does not change
  # the text that flows to the next step.
  step :spam_guard do
    use SupportGuardTribunal
    # Stops the pipeline when true: pipeline.stopped? is set and later steps are skipped.
    stop_if ->(result) { result.processed["verdict"] == false }
  end

  # A TRANSFORM step: `step :name, SomeRequest` — its output becomes the input of the next step.
  step :respond, SupportRequest
end
