# Agent Error Processing

ActiveHarness divides errors into two categories: **retryable** and **non-retryable**.
Retryable errors trigger automatic retries with exponential backoff, then move to the next
fallback model. Non-retryable errors abort the entire chain immediately.

---

## Error Hierarchy

```
ActiveHarness::Errors::Error (base)
  ├── AllModelsFailed           # raised when every model in the chain fails
  └── ProviderError             # base for all provider-level failures
        ├── TimeoutError
        ├── RateLimitError
        ├── ServerError
        ├── ProviderUnavailableError
        ├── InvalidRequestError
        ├── InvalidApiKeyError
        └── SafetyBlockedError
```

`ProviderError` carries optional metadata:

```ruby
error.error_code   # => "model_not_found" (provider-specific code, or nil)
error.metadata     # => Hash with raw provider response fields, or nil
```

---

## Retryable vs Non-Retryable

| Error                      | Retryable | Behaviour                                          |
| -------------------------- | --------- | -------------------------------------------------- |
| `TimeoutError`             | ✓         | Retry same model, then next fallback               |
| `RateLimitError`           | ✓         | Retry same model, then next fallback               |
| `ServerError`              | ✓         | Retry same model, then next fallback               |
| `ProviderUnavailableError` | ✓         | Retry same model, then next fallback               |
| `InvalidRequestError`      | ✓         | Treated as retryable — next fallback will be tried |
| `InvalidApiKeyError`       | ✗         | Stops the entire chain immediately                 |
| `SafetyBlockedError`       | ✗         | Stops the entire chain immediately                 |

---

## Handling AllModelsFailed

Raised when every model in the fallback chain has been exhausted.
Use a standard `rescue` block around `call`:

```ruby
begin
  agent = SupportAgent.call(input: "Hello")
  puts agent.result.output
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "All models failed: #{e.message}"
  # e.message contains the full list of attempted models and their errors
end
```

---

## Inspecting Failures with Hooks

The `:retry` hook fires after each failed attempt before moving to the next fallback.
The `:failure` hook fires after all models are exhausted (just before `AllModelsFailed` is raised).

```ruby
class SupportAgent < ActiveHarness::Agent
  callback :retry do |entry, error|
    Rails.logger.warn "[#{entry[:model]}] #{error.class.name}: #{error.message}"
  end

  callback :failure do |attempts|
    attempts.each do |a|
      Rails.logger.error "FAILED #{a[:model]}: #{a[:error]}"
    end
  end
end
```

`attempts` passed to `:failure` is an array of hashes:

```ruby
[
  {
    provider:       :openrouter,
    model:          "mistralai/mistral-nemo",
    error:          "Provider returned error",
    error_code:     "model_error",
    execution_time: 1.24
  },
  ...
]
```

---

## Non-Retryable Errors — Stop Errors

`InvalidApiKeyError` and `SafetyBlockedError` bypass the retry loop entirely.
They skip `:failure` and propagate directly to the caller:

```ruby
begin
  SupportAgent.call(input: "Hello")
rescue ActiveHarness::Errors::InvalidApiKeyError => e
  puts "Check your API key: #{e.message}"
rescue ActiveHarness::Errors::SafetyBlockedError => e
  puts "Input blocked by provider safety filter"
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "All fallbacks exhausted"
end
```

---

## Checking the Result After Success

When a successful result is returned after retries, the `attempts` field in the result
records every failed attempt that occurred before the successful one:

```ruby
result = SupportAgent.call(input: "Hello").result

puts result.model      # => "meta-llama/llama-3.1-8b-instruct"  (the model that succeeded)
puts result.attempts   # => [{provider:, model:, error:, ...}, ...]  (everything that failed before)
```

This lets you audit which models were tried even when the final call succeeds.
