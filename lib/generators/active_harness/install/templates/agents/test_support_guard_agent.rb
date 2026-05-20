require_relative "../prompts/test_support_guard_prompt"

class TestSupportGuardAgent < ActiveHarness::Agent
  system_prompt TestSupportGuardPrompt
  format :json

  model do
    use      provider: :openrouter, model: "meta-llama/llama-3.1-8b-instruct"
    fallback provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
