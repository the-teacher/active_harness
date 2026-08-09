# Configuration — Plain Ruby

## Setup

After `require "active_harness"`, call `ActiveHarness.configure` once before using any agents.
If you skip `configure`, all values are read from the corresponding ENV variables automatically.

```ruby
require "active_harness"

ActiveHarness.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
end
```

---

## With dotenv

```ruby
require "dotenv/load"   # gem "dotenv"
require "active_harness"

ActiveHarness.configure do |config|
  config.openai_api_key    = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
end
```

---

## Typical project structure

```
my_project/
  Gemfile
  .env
  config.rb        ← require + configure here
  app/
    agents/
      support_agent.rb
  main.rb
```

```ruby
# config.rb
require "dotenv/load"
require "active_harness"

ActiveHarness.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
end
```

```ruby
# main.rb
require_relative "config"
require_relative "app/agents/support_agent"

result = SupportAgent.call(input: "Hello")
puts result.output
```

---

## All configuration options

```ruby
ActiveHarness.configure do |config|
  # Global
  # config.request_timeout = 30

  # OpenAI
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # config.openai_api_url = "https://api.openai.com/v1/chat/completions"

  # Anthropic
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # config.anthropic_api_url = "https://api.anthropic.com/v1/messages"

  # Google Gemini
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  # config.gemini_api_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

  # Groq
  config.groq_api_key = ENV["GROQ_API_KEY"]
  # config.groq_api_url = "https://api.groq.com/openai/v1/chat/completions"

  # OpenRouter
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
  # config.openrouter_api_url      = "https://openrouter.ai/api/v1/chat/completions"
  # config.openrouter_images_api_url = "https://openrouter.ai/api/v1/images"
  # config.openrouter_http_referer = "https://your-site.com"

  # xAI (Grok)
  config.xai_api_key = ENV["XAI_API_KEY"]
  # config.xai_api_url = "https://api.x.ai/v1/chat/completions"

  # DeepSeek
  config.deepseek_api_key = ENV["DEEPSEEK_API_KEY"]
  # config.deepseek_api_url = "https://api.deepseek.com/v1/chat/completions"

  # Mistral
  config.mistral_api_key = ENV["MISTRAL_API_KEY"]
  # config.mistral_api_url = "https://api.mistral.ai/v1/chat/completions"

  # Ollama (local — key is optional)
  # config.ollama_api_base = "http://localhost:11434"
  # config.ollama_api_key  = nil

  # Perplexity
  config.perplexity_api_key = ENV["PERPLEXITY_API_KEY"]
  # config.perplexity_api_url = "https://api.perplexity.ai/chat/completions"

  # GPUStack (self-hosted — key is optional)
  # config.gpustack_api_base = "http://my-server:80"
  # config.gpustack_api_key  = ENV["GPUSTACK_API_KEY"]

  # Azure OpenAI Service
  # Note: `model:` in agent config is the deployment name, not the model name.
  # config.azure_api_base      = ENV["AZURE_API_BASE"]
  # config.azure_api_key       = ENV["AZURE_API_KEY"]
  # config.azure_ai_auth_token = ENV["AZURE_AI_AUTH_TOKEN"]  # alternative to api_key
  # config.azure_api_version   = "2024-05-01-preview"

  # Custom providers — any OpenAI-compatible endpoint
  # Register as many as you need under arbitrary names.
  # `api_key` is optional — omit for local servers without auth.
  #
  # config.custom["MyLocal"]["url"]          = "http://localhost:8080/v1/chat/completions"
  # config.custom["MyLocal"]["api_key"]      = ENV["MYLOCAL_API_KEY"]
  #
  # config.custom["VLLMServer"]["url"]       = "http://gpu-server:8000/v1/chat/completions"
  # config.custom["VLLMServer"]["api_key"]   = ENV["VLLM_API_KEY"]
end
```

**Use in an agent:**

```ruby
model do
  use      provider: :custom, name: "MyLocal",   model: "llama3.2"
  fallback provider: :custom, name: "VLLMServer", model: "mixtral"
  fallback provider: :openai,                     model: "gpt-4o-mini"
end
```

---

## Accessing config at runtime

```ruby
ActiveHarness.config.openai_api_key   # => "sk-..."
```

## Resetting config (useful in tests)

```ruby
ActiveHarness.reset_config!
```
