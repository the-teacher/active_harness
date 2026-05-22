# Configuration — Ruby on Rails

## Setup

Run the install generator — it creates the initializer automatically:

```bash
rails generate active_harness:install
```

This creates `config/initializers/active_harness.rb` with commented examples for all providers.

---

## Initializer

```ruby
# config/initializers/active_harness.rb

ActiveHarness.configure do |config|
  config.openai_api_key    = Rails.application.credentials.openai_api_key
  config.anthropic_api_key = Rails.application.credentials.anthropic_api_key
end
```

The initializer is loaded automatically on Rails boot — no extra wiring needed.

---

## Recommended: Rails credentials

Store secrets in `config/credentials.yml.enc` (encrypted, safe to commit):

```bash
rails credentials:edit
```

```yaml
# config/credentials.yml.enc
openai_api_key: sk-...
anthropic_api_key: sk-ant-...
openrouter_api_key: sk-or-v1-...
```

```ruby
# config/initializers/active_harness.rb
ActiveHarness.configure do |config|
  config.openai_api_key    = Rails.application.credentials.openai_api_key
  config.anthropic_api_key = Rails.application.credentials.anthropic_api_key
  config.openrouter_api_key = Rails.application.credentials.openrouter_api_key
end
```

---

## Alternative: dotenv-rails

```ruby
# Gemfile
gem "dotenv-rails"
```

```bash
# .env  (add to .gitignore)
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

```ruby
# config/initializers/active_harness.rb
ActiveHarness.configure do |config|
  config.openai_api_key    = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
end
```

---

## All configuration options

```ruby
# config/initializers/active_harness.rb
ActiveHarness.configure do |config|
  # Global
  # config.request_timeout = 30

  # OpenAI
  config.openai_api_key = Rails.application.credentials.openai_api_key
  # config.openai_api_url = "https://api.openai.com/v1/chat/completions"

  # Anthropic
  config.anthropic_api_key = Rails.application.credentials.anthropic_api_key
  # config.anthropic_api_url = "https://api.anthropic.com/v1/messages"

  # Google Gemini
  config.gemini_api_key = Rails.application.credentials.gemini_api_key
  # config.gemini_api_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

  # Groq
  config.groq_api_key = Rails.application.credentials.groq_api_key
  # config.groq_api_url = "https://api.groq.com/openai/v1/chat/completions"

  # OpenRouter
  config.openrouter_api_key = Rails.application.credentials.openrouter_api_key
  # config.openrouter_api_url      = "https://openrouter.ai/api/v1/chat/completions"
  config.openrouter_http_referer   = "https://your-app.com"

  # xAI (Grok)
  config.xai_api_key = Rails.application.credentials.xai_api_key
  # config.xai_api_url = "https://api.x.ai/v1/chat/completions"

  # DeepSeek
  config.deepseek_api_key = Rails.application.credentials.deepseek_api_key
  # config.deepseek_api_url = "https://api.deepseek.com/v1/chat/completions"

  # Mistral
  config.mistral_api_key = Rails.application.credentials.mistral_api_key
  # config.mistral_api_url = "https://api.mistral.ai/v1/chat/completions"

  # Ollama (local — key is optional)
  # config.ollama_api_base = "http://localhost:11434"
  # config.ollama_api_key  = nil

  # Perplexity
  config.perplexity_api_key = Rails.application.credentials.perplexity_api_key
  # config.perplexity_api_url = "https://api.perplexity.ai/chat/completions"

  # GPUStack (self-hosted — key is optional)
  # config.gpustack_api_base = "http://my-server:80"
  # config.gpustack_api_key  = Rails.application.credentials.gpustack_api_key

  # Azure OpenAI Service
  # Note: `model:` in agent config is the deployment name, not the model name.
  # config.azure_api_base      = Rails.application.credentials.azure_api_base
  # config.azure_api_key       = Rails.application.credentials.azure_api_key
  # config.azure_ai_auth_token = Rails.application.credentials.azure_ai_auth_token
  # config.azure_api_version   = "2024-05-01-preview"
end
```

---

## Per-environment configuration

Use Rails environment-scoped credentials or ERB:

```yaml
# config/credentials/production.yml.enc
openai_api_key: sk-prod-...

# config/credentials/development.yml.enc
openai_api_key: sk-dev-...
```

Or conditionally in the initializer:

```ruby
ActiveHarness.configure do |config|
  config.openai_api_key = Rails.application.credentials.openai_api_key

  if Rails.env.test?
    # Point to a local mock server in tests
    config.openai_api_url = "http://localhost:4010/v1/chat/completions"
  end
end
```

---

## Resetting config in tests

```ruby
# spec/rails_helper.rb or test/test_helper.rb
RSpec.configure do |config|
  config.after(:each) do
    ActiveHarness.reset_config!
  end
end
```
