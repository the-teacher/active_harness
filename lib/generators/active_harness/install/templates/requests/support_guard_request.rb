require_relative "../prompts/support_guard_prompt"
require_relative "../concerns/request_tracing"

class SupportGuardRequest < ActiveHarness::Request
  include RequestTracing

  system_prompt SupportGuardPrompt

  # Parse the answer as JSON into result.processed (a Hash). Needed explicitly: the gem
  # cannot guess from the prompt that you asked for JSON. Also strips ```json fences.
  format :json

  # A small, cheap model is enough for a yes/no classifier.
  model do
    use      provider: :openrouter, model: "meta-llama/llama-3.1-8b-instruct"
    fallback provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  # Request-specific details for the shared tracing line (see RequestTracing).
  def tracing_details(result)
    " spam=#{result.processed&.dig('spam')}"
  end
end
