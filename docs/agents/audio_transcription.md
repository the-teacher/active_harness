# Audio Transcription Agents

ActiveHarness agents can transcribe audio natively via OpenAI's or OpenRouter's speech-to-text endpoints. Enable it with `transcribe true` and use the same `model`/fallback DSL as any other agent.

```ruby
class TranscriptionAgent < ActiveHarness::Agent
  transcribe true

  model do
    use      provider: :openai,     model: "whisper-1"
    fallback provider: :openrouter, model: "deepgram/nova-3"
  end
end
```

```ruby
result = TranscriptionAgent.call(input: "/path/to/recording.mp3")

result.output      # => "Hello, this is a test recording."
result.processed   # => same as output (default format is :text)
```

`@input` is a **path to a local audio file** — not free text. The audio format is auto-detected from the file extension, read from disk, and sent to the provider. `normalize_input` (whitespace stripping) is automatically skipped for transcription agents, since `@input` is a path, not text.

## Supported Providers

`:openai` and `:openrouter` are supported (`Agent::TRANSCRIPTION_PROVIDERS`). Any other provider in the model chain raises `ArgumentError: Provider ... does not support audio transcription` at call time.

| Provider     | Class                       | Request format                          | Accepted extensions                                    | Example models |
| ------------ | ---------------------------- | ---------------------------------------- | -------------------------------------------------------- | --------------- |
| `:openai`     | `Providers::Audio::OpenAI`   | `multipart/form-data` (only mode)        | `.mp3`, `.mp4`, `.mpeg`, `.mpga`, `.m4a`, `.wav`, `.webm` | `"whisper-1"`, `"gpt-4o-transcribe"`, `"gpt-4o-mini-transcribe"` |
| `:openrouter` | `Providers::Audio::OpenRouter` | base64-encoded JSON                    | `.mp3`, `.wav`, `.flac`, `.m4a`, `.ogg`, `.webm`, `.aac`  | `"openai/whisper-1"`, `"deepgram/nova-3"`, `"google/chirp-3"`, `"nvidia/parakeet-tdt-0.6b-v3"`, `"mistralai/voxtral-mini-transcribe"`, `"qwen/qwen3-asr-flash-*"` — see [OpenRouter's speech-to-text collection](https://openrouter.ai/collections/speech-to-text-models) for the full, current list |

Note the two providers use genuinely different HTTP request formats (multipart vs. base64 JSON) — this is handled internally per-provider, you don't need to do anything differently in the DSL. `:openai` also accepts a narrower set of file extensions than `:openrouter`; a file extension `:openai` doesn't support raises `InvalidRequestError` (retryable — the chain moves to the next fallback) before any network call is made.

**Testing status:** both providers have been verified end-to-end with real audio and a real API key. `:openrouter` — successful transcription with correct cost. `:openai` — successful transcription with `whisper-1` (duration-billed, `result.usage` is `nil` as documented above) and with `gpt-4o-mini-transcribe` (token-billed, `result.usage.tokens` populated correctly, `result.usage.cost` `nil` since the `Pricing` registry has no rate for this model) — both matching the behavior documented in this file. Error paths were also verified against real OpenAI responses: an invalid key produced `InvalidApiKeyError`, and an account with no billing enabled produced `InvalidRequestError` (`insufficient_quota`).

## Language Hint

`language "en"` at the class level sets an ISO-639-1 hint for every model in the chain (auto-detected if omitted). Override per-model with `language:` in `use`/`fallback`:

```ruby
class TranscriptionAgent < ActiveHarness::Agent
  transcribe true
  language "ja"

  model do
    use provider: :openrouter, model: "openai/whisper-1", language: "en"
  end
end
```

There is no `size`/`quality`-style option for transcription — the only per-model override is `language:`.

## Model Validation

When `transcribe true` is set, every model in the chain is checked against the `Pricing` registry: if the model is known, it must have `"transcription"` in its `categories`, otherwise `ArgumentError` is raised (with the model's `output_modalities` in the message) at model-list resolution time. Models the registry doesn't recognize (new or private models) are assumed valid and skipped — see [Pricing](pricing.md).

## No `system_prompt` Support

Unlike [image generation](image_generation.md), a `system_prompt` on a transcription agent is currently resolved but **not sent to either provider** — there is no supported way yet to bias or guide the transcription output through ActiveHarness. Note the two providers differ here at the API level: OpenAI's native endpoint has a real, functional `prompt` parameter (useful for biasing spelling of names/terms); OpenRouter's transcription endpoint accepts a `prompt` field for OpenAI-SDK compatibility but silently ignores it. Wiring `system_prompt` through to OpenAI's `prompt` parameter would be a reasonable future addition, but isn't implemented today.

## Errors, Retry and Fallback

Transcription calls go through the same retry/fallback chain as text and image agents — see [Retry Policy](retry_policy.md). Error mapping is HTTP-status/error-code based and differs slightly per provider (matching each provider's own error payload shape):

- `:openai` — `invalid_api_key`/`unauthorized` → `InvalidApiKeyError`, `rate_limit_exceeded` → `RateLimitError`, `content_filter` → `SafetyBlockedError`, server errors → `ServerError`, anything else → `InvalidRequestError`.
- `:openrouter` — HTTP-style codes `401` → `InvalidApiKeyError`, `402`/`429` → `RateLimitError`, `500`-`504` → `ProviderUnavailableError`, anything else → `InvalidRequestError`.

## Synchronous — No Job ID / Polling

The transcription call is **synchronous**: the HTTP response contains the finished transcript directly, with no job id or polling step. However, **upstream providers time out after roughly 60 seconds of processing per request** — for recordings longer than about a minute, split the audio into shorter chunks yourself before transcribing each one; ActiveHarness does not do this automatically.

## Usage and Cost

Most transcription models are priced by audio duration, not by token count, so `result.usage.tokens` is typically all zeros. Cost reporting differs by provider:

- `:openrouter` returns a `usage.cost` field directly in its response, and `result.usage.cost.total` is populated from that — generally accurate as long as the provider reports it.
- `:openai` does **not** return a dollar cost in its response. `whisper-1` reports `{type: "duration", seconds: N}` (no tokens at all); `gpt-4o-transcribe`/`gpt-4o-mini-transcribe` report `{type: "tokens", input_tokens:, output_tokens:, total_tokens:}`. ActiveHarness maps the token-based shape into `result.usage.tokens`, but `result.usage.cost` will be `nil` for `:openai` transcription unless the model has a token-based rate in the `Pricing` registry — for `whisper-1` specifically (duration-billed), cost is not computed at all.

## Known Caveat: Empty Transcripts

Some models can return a successful response with an empty `text` (and `usage.cost` of `0`) instead of raising an error, when they don't detect recognizable speech in the audio (e.g. very short, quiet, or unclear input) — observed with `google/chirp-3` during testing, while `openai/whisper-1` and `deepgram/nova-3` handled the same audio normally. Treat an empty `result.output` as "no speech detected" rather than assuming the call failed; if this matters for your use case, check `result.output.to_s.strip.empty?` and retry with a different model or ask the user to re-record.

## Notes

- `format :json` has no effect on transcription agents — `processed` always equals `output`.
- Streaming (`token:`) is not supported for transcription; it only applies to text agents.
