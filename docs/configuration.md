# Configuration

ActiveHarness supports a Rails-style `configure` block for setting API keys and provider URLs in one place. ENV variables are used as defaults if `configure` is not called — so existing setups keep working without changes.

- [Configuration in plain Ruby →](ruby_configuration.md)
- [Configuration in Ruby on Rails →](rails_configuration.md)

## Quick Example

```ruby
ActiveHarness.configure do |config|
  config.openai_api_key    = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.openrouter_http_referer = "https://my-app.com"

  # Retry policy (global defaults)
  config.retry_default_attempts = 3    # total attempts per model
  config.retry_default_delay    = 1.0  # seconds before 1st retry; doubles each round

  # Register any OpenAI-compatible endpoint under a custom name
  config.custom["MyLocal"]["url"]     = "http://localhost:8080/v1/chat/completions"
  config.custom["MyLocal"]["api_key"] = ENV["MYLOCAL_API_KEY"]  # omit if no auth
end
```

Use a custom provider in an agent:

```ruby
model do
  use      provider: :custom, name: "MyLocal", model: "llama3.2"
  fallback provider: :openai,                   model: "gpt-4o-mini"
end
```

## Retry Policy

When a model returns a transient error (`TimeoutError`, `RateLimitError`, `ServerError`, `ProviderUnavailableError`), ActiveHarness automatically retries the **same model** with exponential backoff before moving to the next fallback.

```
model A → retry 1 (1s) → retry 2 (2s) → FAIL → model B (fallback) → SUCCESS
```

**Global defaults** (apply to all models unless overridden):

```ruby
ActiveHarness.configure do |config|
  config.retry_default_attempts = 3    # total attempts per model (default: 3)
  config.retry_default_delay    = 1.0  # seconds before 1st retry; doubles each round (default: 1.0)
end
```

Disable retries entirely:

```ruby
config.retry_default_attempts = 1  # one attempt — fail immediately to next fallback
```

**Per-model override** — set `retry_attempts:` and `retry_delay:` in the model DSL:

```ruby
model do
  use      provider: :openai, model: "gpt-4.1",
           retry_attempts: 5, retry_delay: 2.0   # up to 5 attempts, 2s → 4s → 8s…

  fallback provider: :groq,   model: "llama3-8b-8192",
           retry_attempts: 2, retry_delay: 0.5   # fast fallback

  fallback provider: :ollama, model: "llama3.2"
  # ↑ uses global retry_default_attempts / retry_default_delay
end
```

Backoff formula: `delay × 2^(attempt − 1)` — with `retry_delay: 1.0` and 3 attempts: **1s → 2s → fail → next fallback**.

Errors that are **never** retried (stop the chain immediately): `InvalidApiKeyError`, `SafetyBlockedError`.
