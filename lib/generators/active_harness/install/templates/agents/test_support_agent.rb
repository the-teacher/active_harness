require_relative "../prompts/test_support_prompt"

class TestSupportAgent < ActiveHarness::Agent
  system_prompt TestSupportPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.1-8b-instruct"
  end
end
