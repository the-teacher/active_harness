module ActiveHarness
  # Central configuration object.
  #
  # Usage in config/initializers/active_harness.rb:
  #
  #   ActiveHarness.configure do |config|
  #     config.openai_api_key  = ENV["OPENAI_API_KEY"]
  #     config.openai_api_url  = "https://api.openai.com/v1/chat/completions"
  #     # ...
  #   end
  #
  # If a value is not explicitly set, it is read from the corresponding
  # environment variable so all existing ENV-based setups keep working.
  class Configuration
    # -------------------------------------------------------------------------
    # Global
    # -------------------------------------------------------------------------
    attr_accessor :request_timeout

    # -------------------------------------------------------------------------
    # OpenAI
    # -------------------------------------------------------------------------
    attr_accessor :openai_api_key
    attr_accessor :openai_api_url

    # -------------------------------------------------------------------------
    # Anthropic
    # -------------------------------------------------------------------------
    attr_accessor :anthropic_api_key
    attr_accessor :anthropic_api_url

    # -------------------------------------------------------------------------
    # Google Gemini (OpenAI-compatible REST endpoint)
    # -------------------------------------------------------------------------
    attr_accessor :gemini_api_key
    attr_accessor :gemini_api_url

    # -------------------------------------------------------------------------
    # Groq
    # -------------------------------------------------------------------------
    attr_accessor :groq_api_key
    attr_accessor :groq_api_url

    # -------------------------------------------------------------------------
    # OpenRouter
    # -------------------------------------------------------------------------
    attr_accessor :openrouter_api_key
    attr_accessor :openrouter_api_url
    attr_accessor :openrouter_http_referer

    # -------------------------------------------------------------------------
    # xAI (Grok)
    # -------------------------------------------------------------------------
    attr_accessor :xai_api_key
    attr_accessor :xai_api_url

    # -------------------------------------------------------------------------
    # DeepSeek
    # -------------------------------------------------------------------------
    attr_accessor :deepseek_api_key
    attr_accessor :deepseek_api_url

    # -------------------------------------------------------------------------
    # Mistral
    # -------------------------------------------------------------------------
    attr_accessor :mistral_api_key
    attr_accessor :mistral_api_url

    # -------------------------------------------------------------------------
    # Ollama (local — key is optional)
    # -------------------------------------------------------------------------
    attr_accessor :ollama_api_key
    attr_accessor :ollama_api_base

    # -------------------------------------------------------------------------
    # Perplexity
    # -------------------------------------------------------------------------
    attr_accessor :perplexity_api_key
    attr_accessor :perplexity_api_url

    # -------------------------------------------------------------------------
    # GPUStack (self-hosted — key is optional)
    # -------------------------------------------------------------------------
    attr_accessor :gpustack_api_key
    attr_accessor :gpustack_api_base

    # -------------------------------------------------------------------------
    # Azure OpenAI Service
    # -------------------------------------------------------------------------
    attr_accessor :azure_api_key        # api-key header (preferred)
    attr_accessor :azure_ai_auth_token  # Bearer token (alternative to api-key)
    attr_accessor :azure_api_base       # e.g. "https://my-resource.openai.azure.com"
    attr_accessor :azure_api_version    # e.g. "2024-05-01-preview"

    # -------------------------------------------------------------------------
    # Defaults — all keys fall back to the corresponding ENV variable so that
    # existing ENV-based setups keep working without any changes.
    # -------------------------------------------------------------------------
    def initialize
      @request_timeout = 30

      @openai_api_key  = ENV["OPENAI_API_KEY"]
      @openai_api_url  = "https://api.openai.com/v1/chat/completions"

      @anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
      @anthropic_api_url = "https://api.anthropic.com/v1/messages"

      @gemini_api_key = ENV["GEMINI_API_KEY"]
      @gemini_api_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

      @groq_api_key = ENV["GROQ_API_KEY"]
      @groq_api_url = "https://api.groq.com/openai/v1/chat/completions"

      @openrouter_api_key      = ENV["OPENROUTER_API_KEY"]
      @openrouter_api_url      = "https://openrouter.ai/api/v1/chat/completions"
      @openrouter_http_referer = "https://github.com/the-teacher/ActiveHarness"

      @xai_api_key = ENV["XAI_API_KEY"]
      @xai_api_url = "https://api.x.ai/v1/chat/completions"

      @deepseek_api_key = ENV["DEEPSEEK_API_KEY"]
      @deepseek_api_url = "https://api.deepseek.com/v1/chat/completions"

      @mistral_api_key = ENV["MISTRAL_API_KEY"]
      @mistral_api_url = "https://api.mistral.ai/v1/chat/completions"

      @ollama_api_key  = ENV["OLLAMA_API_KEY"]   # nil if not set — key is optional
      @ollama_api_base = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434")

      @perplexity_api_key = ENV["PERPLEXITY_API_KEY"]
      @perplexity_api_url = "https://api.perplexity.ai/chat/completions"

      @gpustack_api_key  = ENV["GPUSTACK_API_KEY"]   # nil if not set — key is optional
      @gpustack_api_base = ENV["GPUSTACK_API_BASE"]

      @azure_api_key       = ENV["AZURE_API_KEY"]
      @azure_ai_auth_token = ENV["AZURE_AI_AUTH_TOKEN"]
      @azure_api_base      = ENV["AZURE_API_BASE"]
      @azure_api_version   = ENV.fetch("AZURE_API_VERSION", "2024-05-01-preview")
    end
  end
end
