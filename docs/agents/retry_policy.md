# Retry Policy

When a model returns a transient error (`TimeoutError`, `RateLimitError`, `ServerError`, `ProviderUnavailableError`), ActiveHarness automatically retries the **same model** with exponential backoff before moving to the next fallback.

```
model A → retry 1 (1s) → retry 2 (2s) → FAIL → model B (fallback) → SUCCESS
```

## Global Defaults

Set in `ActiveHarness.configure` — apply to all models unless overridden per-model:

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

## Per-Model Override

Set `retry_attempts:` and `retry_delay:` directly in the model DSL:

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

Per-model values take priority over global defaults. If not set, global defaults apply.

## Backoff Formula

`delay × 2^(attempt − 1)`

With `retry_delay: 1.0` and `retry_attempts: 3`:

| Attempt | Wait before            |
| ------- | ---------------------- |
| 1       | — (first try, no wait) |
| 2       | 1s                     |
| 3       | 2s                     |
| —       | fail → next fallback   |

## Retryable Errors

These errors trigger a retry on the same model:

| Error                      | Typical cause                |
| -------------------------- | ---------------------------- |
| `TimeoutError`             | Network or read timeout      |
| `RateLimitError`           | Provider rate limit hit      |
| `ServerError`              | Provider 5xx response        |
| `ProviderUnavailableError` | Provider unreachable         |
| `InvalidRequestError`      | Bad request / model overload |

## Non-Retryable Errors

These errors stop the entire chain immediately — retrying cannot help:

| Error                | Reason                                      |
| -------------------- | ------------------------------------------- |
| `InvalidApiKeyError` | Wrong API key — same for every model        |
| `SafetyBlockedError` | Input blocked — won't pass on another model |
