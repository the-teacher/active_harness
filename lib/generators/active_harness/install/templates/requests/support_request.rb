require_relative "../prompts/support_prompt"
require_relative "../concerns/request_tracing"

class SupportRequest < ActiveHarness::Request
  include RequestTracing   # basic tracing lives in a concern — see app/ai/concerns/

  # The system prompt: a class with #call, a String or a lambda.
  system_prompt SupportPrompt

  # The model chain: `use` is tried first; if it keeps failing (after its retries)
  # the next `fallback` is tried. When all fail: ActiveHarness::Errors::AllModelsFailed.
  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.1-8b-instruct"
  end
end
