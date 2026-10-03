# config/initializers/active_harness.rb
#
# Configure ActiveHarness.
# All values fall back to the corresponding ENV variable if not set here,
# so you can use either approach — or mix both.

ActiveHarness.configure do |config|
  # ---------------------------------------------------------------------------
  # OpenAI
  # ---------------------------------------------------------------------------
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # config.openai_api_url = "https://api.openai.com/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # Anthropic
  # ---------------------------------------------------------------------------
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # config.anthropic_api_url = "https://api.anthropic.com/v1/messages"

  # ---------------------------------------------------------------------------
  # Google Gemini
  # ---------------------------------------------------------------------------
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  # config.gemini_api_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

  # ---------------------------------------------------------------------------
  # Groq
  # ---------------------------------------------------------------------------
  config.groq_api_key = ENV["GROQ_API_KEY"]
  # config.groq_api_url = "https://api.groq.com/openai/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # OpenRouter
  # ---------------------------------------------------------------------------
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
  # config.openrouter_api_url      = "https://openrouter.ai/api/v1/chat/completions"
  # config.openrouter_http_referer = "https://your-app.com"

  # ---------------------------------------------------------------------------
  # xAI (Grok)
  # ---------------------------------------------------------------------------
  config.xai_api_key = ENV["XAI_API_KEY"]
  # config.xai_api_url = "https://api.x.ai/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # DeepSeek
  # ---------------------------------------------------------------------------
  config.deepseek_api_key = ENV["DEEPSEEK_API_KEY"]
  # config.deepseek_api_url = "https://api.deepseek.com/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # Mistral
  # ---------------------------------------------------------------------------
  config.mistral_api_key = ENV["MISTRAL_API_KEY"]
  # config.mistral_api_url = "https://api.mistral.ai/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # Ollama (local — API key is optional)
  # ---------------------------------------------------------------------------
  # config.ollama_api_base = "http://localhost:11434"
  # config.ollama_api_key  = nil

  # ---------------------------------------------------------------------------
  # Perplexity
  # ---------------------------------------------------------------------------
  config.perplexity_api_key = ENV["PERPLEXITY_API_KEY"]
  # config.perplexity_api_url = "https://api.perplexity.ai/chat/completions"

  # ---------------------------------------------------------------------------
  # GPUStack (self-hosted — API key is optional)
  # ---------------------------------------------------------------------------
  # config.gpustack_api_base = "http://my-gpustack-server:80"
  # config.gpustack_api_key  = ENV["GPUSTACK_API_KEY"]

  # ---------------------------------------------------------------------------
  # Azure OpenAI Service
  # The `model:` in your request config is the deployment name, not the model name.
  # ---------------------------------------------------------------------------
  # config.azure_api_base      = ENV["AZURE_API_BASE"]    # "https://my-resource.openai.azure.com"
  # config.azure_api_key       = ENV["AZURE_API_KEY"]     # resource API key (preferred)
  # config.azure_ai_auth_token = ENV["AZURE_AI_AUTH_TOKEN"]  # OAuth bearer (alternative)
  # config.azure_api_version   = "2024-05-01-preview"

  # ---------------------------------------------------------------------------
  # Cohere (native v2 Chat API)
  # ---------------------------------------------------------------------------
  # config.cohere_api_key = ENV["COHERE_API_KEY"]
  # config.cohere_api_url = "https://api.cohere.com/v2/chat"

  # ---------------------------------------------------------------------------
  # TypeSafe — Jev (System One) evaluation model, direct API
  # ---------------------------------------------------------------------------
  # config.typesafe_api_key = ENV["TYPESAFE_API_KEY"]
  # config.typesafe_api_url = "https://api.typesafe.ai/v1/systemone"

  # ---------------------------------------------------------------------------
  # Ollama Cloud (hosted — API key required)
  # ---------------------------------------------------------------------------
  # config.ollama_cloud_api_key = ENV["OLLAMA_CLOUD_API_KEY"]
  # config.ollama_cloud_api_url = "https://ollama.com/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # Hetzner Inference
  # ---------------------------------------------------------------------------
  # config.hetzner_api_key = ENV["HETZNER_API_KEY"]
  # config.hetzner_api_url = "https://inference.hetzner.com/api/v1/chat/completions"

  # ---------------------------------------------------------------------------
  # Deepgram / ElevenLabs (audio transcription only)
  # ---------------------------------------------------------------------------
  # config.deepgram_api_key   = ENV["DEEPGRAM_API_KEY"]
  # config.elevenlabs_api_key = ENV["ELEVENLABS_API_KEY"]

  # ---------------------------------------------------------------------------
  # Custom providers — any OpenAI-compatible endpoint
  # Register as many as you need under arbitrary names.
  # `api_key` is optional — omit for local servers without auth.
  # ---------------------------------------------------------------------------
  # config.custom["MyLocal"]["url"]        = "http://localhost:8080/v1/chat/completions"
  # config.custom["MyLocal"]["api_key"]    = ENV["MYLOCAL_API_KEY"]
  #
  # config.custom["VLLMServer"]["url"]     = "http://gpu-server:8000/v1/chat/completions"
  # config.custom["VLLMServer"]["api_key"] = ENV["VLLM_API_KEY"]
  #
  # Use in a request:
  #   model do
  #     use      provider: :custom, name: "MyLocal",    model: "llama3.2"
  #     fallback provider: :custom, name: "VLLMServer", model: "mixtral"
  #     fallback provider: :openai,                     model: "gpt-4o-mini"
  #   end
end
