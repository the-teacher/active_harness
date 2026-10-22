require_relative "../prompts/files_prompt"
require_relative "../concerns/request_tracing"

# The model behind FilesAgent. It must support tool calling.
class FilesRequest < ActiveHarness::Request
  include RequestTracing   # basic tracing lives in a concern — see app/ai/concerns/

  # The system prompt: a class with #call, a String or a lambda. The agent adds the
  # conversation and the tool schemas on top of it.
  system_prompt FilesPrompt

  # The model chain: `use` is tried first; on failure (after retries) the next
  # `fallback` is tried. Not every provider supports tools — one that does not is skipped.
  model do
    use      provider: :openrouter, model: "openai/gpt-4.1-mini"
    fallback provider: :openrouter, model: "google/gemini-2.0-flash-001"
  end
end
