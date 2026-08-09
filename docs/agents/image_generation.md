# Image Generation Agents

ActiveHarness agents can generate images natively — no `custom_llm_backend`/RubyLLM required. Enable it with `image true` and use the same `model`/fallback DSL as any other agent.

```ruby
class ImageAgent < ActiveHarness::Agent
  image true
  size  "1024x1024"

  model do
    use      provider: :openrouter, model: "openai/gpt-5-image-mini"
    fallback provider: :openai,     model: "gpt-image-1"
  end
end
```

```ruby
result = ImageAgent.call(input: "A watercolor fox in a snowy forest")

result.output      # => base64 string, "data:image/png;base64,..." or an HTTPS URL (provider-dependent)
result.processed   # => same as output (default format is :text)
```

Image APIs take a single prompt string — there's no separate system/user message split like in chat. So if the agent declares a `system_prompt`, it's **prepended** to `@input` (joined by a blank line) to form the final prompt; without one, `@input` is sent as-is.

```ruby
class ImageAgent < ActiveHarness::Agent
  image true

  # Base style guidance — applies to every request.
  system_prompt "Watercolor style, soft pastel colors, no text overlays."

  model do
    use provider: :openrouter, model: "openai/gpt-5-image-mini"
  end
end

ImageAgent.call(input: "A fox sitting in a snowy forest")
# final prompt sent to the provider:
#   "Watercolor style, soft pastel colors, no text overlays.
#
#   A fox sitting in a snowy forest"
```

`system_prompt` accepts a plain string, a Prompt class, or a lambda — same as text agents (see [Prompts](../PROMPTS.md)) — so the base style can itself be dynamic (e.g. built from `@context`/`@params`).

## Supported Providers

Only two providers currently support image generation:

| Provider     | Class                             | Example models                                            |
| ------------ | ---------------------------------- | ----------------------------------------------------------- |
| `:openai`     | `Providers::Images::OpenAI`       | `"dall-e-2"`, `"dall-e-3"`, `"gpt-image-1"`                 |
| `:openrouter` | `Providers::Images::OpenRouter`   | any image-capable OpenRouter model, e.g. `"openai/gpt-5-image-mini"`, `"google/gemini-2.5-flash-image"` |

Any other provider in the model chain raises `ArgumentError: Provider ... does not support image generation` at call time.

## Size and Quality

- `size "1024x1024"` at the class level sets the default for every model in the chain.
- Override per-model with `size:` / `quality:` in `use`/`fallback`:

```ruby
model do
  use      provider: :openai,     model: "gpt-image-1", size: "1024x1792", quality: "high"
  fallback provider: :openrouter, model: "google/gemini-2.5-flash-image"
  # OpenRouter currently ignores `size`/`quality` (passed through for future support)
end
```

Resolution order for size: per-model `size:` → class-level `size` → `"1024x1024"` default.

For OpenRouter, image-only models use the dedicated `/api/v1/images` endpoint.
Models that output both image and text continue to use the chat-completions
endpoint for backward compatibility. Configure a custom Images endpoint with
`config.openrouter_images_api_url` or `OPENROUTER_IMAGES_API_URL`. Dedicated API
responses are returned as Base64 through `result.output`.

## Model Validation

When `image true` is set, every model in the chain is checked against the `Pricing` registry: if the model is known, it must have `"imggen"` in its `categories`, otherwise `ArgumentError` is raised (with the model's `output_modalities` in the message) at model-list resolution time. Models the registry doesn't recognize (new or private models) are assumed valid and skipped — see [Pricing](pricing.md) for how the registry itself is populated.

## Errors, Retry and Fallback

Image calls go through the same retry/fallback chain as text agents — see [Retry Policy](retry_policy.md). Provider-specific error mapping:

- OpenAI: `invalid_api_key`/`unauthorized` → `InvalidApiKeyError`, `rate_limit_exceeded` → `RateLimitError`, `content_filter` → `SafetyBlockedError`, server errors → `ServerError`, anything else → `InvalidRequestError`.
- OpenRouter: HTTP-style codes `401` → `InvalidApiKeyError`, `402`/`429` → `RateLimitError`, `500`-`504` → `ProviderUnavailableError`, anything else → `InvalidRequestError`.

## Usage and Cost

- The OpenAI images provider does not return token usage (`result.usage` fields are empty) — image pricing isn't token-based, so `result.usage.cost` will typically be `nil` for `:openai`.
- The OpenRouter images provider does return a usage payload (same shape as its chat endpoint), so `result.usage.cost` may be populated if the model has token-based pricing in the registry — treat it as best-effort, not an authoritative per-image price.

## Notes

- `format :json` has no effect on image agents — `processed` always equals `output`.
- Streaming (`token:`) is not supported for image generation; it only applies to text agents.
