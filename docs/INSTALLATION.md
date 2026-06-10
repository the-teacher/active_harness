# Installation and Configuration

## Installation

Add to your `Gemfile`:

```ruby
gem "active_harness"
```

ActiveHarness requires `concurrent-ruby` for parallel tribunal execution:

```ruby
gem "active_harness"
gem "concurrent-ruby"
```

Then run:

```
bundle install
```

---

## Rails Setup

Run the install generator to create the directory structure and a configuration initializer:

```
rails generate active_harness:install
```

This creates:

```
app/ai/
├── agents/       ← SupportAgent example
├── prompts/      ← SupportPrompt example
├── tribunals/    ← SupportGuardTribunal example
├── pipelines/    ← SupportPipeline example
└── memory/       ← AppMemory example

config/initializers/active_harness.rb
app/controllers/ai_support_controller.rb
```

Routes are also injected into `config/routes.rb`:

```ruby
post "ai/agent",        to: "ai_support#agent"
post "ai/agent_memory", to: "ai_support#agent_memory"
post "ai/tribunal",     to: "ai_support#tribunal"
post "ai/pipeline",     to: "ai_support#pipeline"
get  "ai/agent_stream", to: "ai_support#agent_stream"
```

All directories under `app/ai/` are autoloaded by Rails — no `require` needed.

---

## Plain Ruby Setup

```ruby
# Gemfile
gem "active_harness", path: "../ActiveHarness2"  # local path
# or
gem "active_harness"                              # from RubyGems
```

Configure before use:

```ruby
require "active_harness"

ActiveHarness.configure do |config|
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
end
```

---

## Configuration

All values fall back to the corresponding environment variable if not set explicitly. The simplest setup sets only the keys you need:

```ruby
# config/initializers/active_harness.rb

ActiveHarness.configure do |config|
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
end
```

Full reference with all providers:

```ruby
ActiveHarness.configure do |config|
  # ── Global ──────────────────────────────────────────────────────────────────
  config.request_timeout       = 10   # HTTP timeout per request, seconds
  config.retry_default_attempts = 3   # retries per model before moving to fallback
  config.retry_default_delay    = 1.0 # base delay for exponential backoff, seconds

  # ── OpenAI ──────────────────────────────────────────────────────────────────
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # config.openai_api_url = "https://api.openai.com/v1/chat/completions"

  # ── Anthropic ───────────────────────────────────────────────────────────────
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # config.anthropic_api_url = "https://api.anthropic.com/v1/messages"

  # ── Google Gemini ────────────────────────────────────────────────────────────
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  # config.gemini_api_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

  # ── Groq ─────────────────────────────────────────────────────────────────────
  config.groq_api_key = ENV["GROQ_API_KEY"]
  # config.groq_api_url = "https://api.groq.com/openai/v1/chat/completions"

  # ── OpenRouter ───────────────────────────────────────────────────────────────
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
  # config.openrouter_http_referer = "https://your-app.com"

  # ── xAI (Grok) ───────────────────────────────────────────────────────────────
  config.xai_api_key = ENV["XAI_API_KEY"]
  # config.xai_api_url = "https://api.x.ai/v1/chat/completions"

  # ── DeepSeek ─────────────────────────────────────────────────────────────────
  config.deepseek_api_key = ENV["DEEPSEEK_API_KEY"]
  # config.deepseek_api_url = "https://api.deepseek.com/v1/chat/completions"

  # ── Mistral ───────────────────────────────────────────────────────────────────
  config.mistral_api_key = ENV["MISTRAL_API_KEY"]
  # config.mistral_api_url = "https://api.mistral.ai/v1/chat/completions"

  # ── Perplexity ────────────────────────────────────────────────────────────────
  config.perplexity_api_key = ENV["PERPLEXITY_API_KEY"]
  # config.perplexity_api_url = "https://api.perplexity.ai/chat/completions"

  # ── Ollama (local — API key is optional) ──────────────────────────────────────
  # config.ollama_api_base = "http://localhost:11434"
  # config.ollama_api_key  = nil

  # ── GPUStack (self-hosted — API key is optional) ──────────────────────────────
  # config.gpustack_api_base = "http://my-gpustack-server:80"
  # config.gpustack_api_key  = ENV["GPUSTACK_API_KEY"]

  # ── Azure OpenAI Service ─────────────────────────────────────────────────────
  # The `model:` in your agent is the deployment name, not the model name.
  # config.azure_api_base      = ENV["AZURE_API_BASE"]         # "https://my-resource.openai.azure.com"
  # config.azure_api_key       = ENV["AZURE_API_KEY"]          # resource API key (preferred)
  # config.azure_ai_auth_token = ENV["AZURE_AI_AUTH_TOKEN"]    # OAuth bearer (alternative)
  # config.azure_api_version   = "2024-05-01-preview"

  # ── Custom providers — any OpenAI-compatible endpoint ────────────────────────
  # config.custom["MyLocal"]["url"]        = "http://localhost:8080/v1/chat/completions"
  # config.custom["MyLocal"]["api_key"]    = ENV["MYLOCAL_API_KEY"]  # omit if no auth
  #
  # config.custom["VLLMServer"]["url"]     = "http://gpu-server:8000/v1/chat/completions"
  # config.custom["VLLMServer"]["api_key"] = ENV["VLLM_API_KEY"]
end
```

---

## Providers Reference

| Provider key    | ENV variable             | Notes                                    |
| --------------- | ------------------------ | ---------------------------------------- |
| `:openai`       | `OPENAI_API_KEY`         |                                          |
| `:anthropic`    | `ANTHROPIC_API_KEY`      |                                          |
| `:gemini`       | `GEMINI_API_KEY`         |                                          |
| `:groq`         | `GROQ_API_KEY`           |                                          |
| `:openrouter`   | `OPENROUTER_API_KEY`     | Aggregator — access 100+ models          |
| `:xai`          | `XAI_API_KEY`            | Grok models                              |
| `:deepseek`     | `DEEPSEEK_API_KEY`       |                                          |
| `:mistral`      | `MISTRAL_API_KEY`        |                                          |
| `:perplexity`   | `PERPLEXITY_API_KEY`     |                                          |
| `:ollama`       | `OLLAMA_API_BASE`        | Local — key optional                     |
| `:gpustack`     | `GPUSTACK_API_BASE`      | Self-hosted — key optional               |
| `:azure`        | `AZURE_API_BASE`         | `model:` is the deployment name          |
| `:bedrock`      | AWS credentials          | AWS SDK required                         |
| `:vertexai`     | GCP credentials          | Google Cloud SDK required                |
| `:custom`       | —                        | Any OpenAI-compatible endpoint, requires `name:` |

---

## Global Settings

| Setting                  | Default | Description                                          |
| ------------------------ | ------- | ---------------------------------------------------- |
| `request_timeout`        | `10`    | HTTP timeout per request in seconds                  |
| `retry_default_attempts` | `3`     | Retries per model before moving to the next fallback |
| `retry_default_delay`    | `1.0`   | Base delay in seconds for exponential backoff        |

Per-model values set via `retry_attempts:` and `retry_delay:` in the agent DSL override these globals.

Set `retry_default_attempts` to `1` to disable retries entirely.

---

## Generators

| Command                                   | What it creates                                           |
| ----------------------------------------- | --------------------------------------------------------- |
| `rails g active_harness:install`          | Full `app/ai/` structure, initializer, controller, routes |
| `rails g active_harness:agent NAME`       | `app/ai/agents/name_agent.rb`                             |
| `rails g active_harness:prompt NAME`      | `app/ai/prompts/name_prompt.rb`                           |
| `rails g active_harness:tribunal NAME`    | `app/ai/tribunals/name_tribunal.rb`                       |
| `rails g active_harness:pipeline NAME`    | `app/ai/pipelines/name_pipeline.rb`                       |
| `rails g active_harness:memory NAME`      | `app/ai/memory/name_memory.rb`                            |
| `rails g active_harness:memory_sqlite`    | SQLite migration for conversation memory                  |
| `rails g active_harness:memory_postgresql`| PostgreSQL migration for conversation memory              |
