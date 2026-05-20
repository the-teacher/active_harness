# Provider Contract

Each provider class must inherit from `Providers::Base` and implement a single public method:

```ruby
def call(model:, messages:, temperature: 0.7) → Hash
```

## Return value

A plain Hash with exactly these keys:

| Key         | Type   | Description                                        |
| ----------- | ------ | -------------------------------------------------- |
| `:content`  | String | The model's text reply (stripped)                  |
| `:provider` | Symbol | Provider identifier, e.g. `:openai`, `:openrouter` |
| `:model`    | String | Actual model name returned by the API              |

```ruby
{
  content:  "Washington, D.C.",
  provider: :openrouter,
  model:    "mistralai/mistral-nemo"
}
```

## Errors

All exceptions must be subclasses of `ActiveHarness::Errors::ProviderError` and carry:

| Attribute    | Type          | Description                                                             |
| ------------ | ------------- | ----------------------------------------------------------------------- |
| `message`    | String        | Human-readable error text from the API                                  |
| `error_code` | String or nil | Raw code from the API response (`"429"`, `"invalid_api_key"`, etc.)     |
| `metadata`   | Hash or nil   | Extra data returned by the API (rate-limit timing, provider name, etc.) |

```ruby
raise Errors::RateLimitError.new(msg, error_code: code, metadata: metadata)
```

### Error classes and retry behaviour

| Class                      | Retryable | Typical trigger                  |
| -------------------------- | --------- | -------------------------------- |
| `TimeoutError`             | yes       | Network open/read timeout        |
| `RateLimitError`           | yes       | HTTP 429 / `rate_limit_exceeded` |
| `ServerError`              | yes       | API `server_error` type          |
| `ProviderUnavailableError` | yes       | HTTP 5xx, host unreachable       |
| `InvalidRequestError`      | no        | Bad request, unknown model, etc. |
| `InvalidApiKeyError`       | no        | Missing or invalid API key       |
| `SafetyBlockedError`       | no        | Content policy violation         |

Retryable errors cause the agent to move to the next model in the chain.
Non-retryable errors abort the chain immediately and are re-raised.
