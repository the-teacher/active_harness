# Audio Transcription Agents

ActiveHarness agents can transcribe audio natively via OpenRouter's speech-to-text endpoint. Enable it with `transcribe true` and use the same `model`/fallback DSL as any other agent.

```ruby
class TranscriptionAgent < ActiveHarness::Agent
  transcribe true

  model do
    use      provider: :openrouter, model: "openai/whisper-1"
    fallback provider: :openrouter, model: "deepgram/nova-3"
  end
end
```

```ruby
result = TranscriptionAgent.call(input: "/path/to/recording.mp3")

result.output      # => "Hello, this is a test recording."
result.processed   # => same as output (default format is :text)
```

`@input` is a **path to a local audio file** — not free text. The audio format is auto-detected from the file extension (`.mp3`, `.wav`, `.flac`, `.m4a`, `.ogg`, `.webm`, `.aac`), read from disk, and base64-encoded before being sent. `normalize_input` (whitespace stripping) is automatically skipped for transcription agents, since `@input` is a path, not text.

## Supported Providers

Only `:openrouter` is currently supported (`Agent::TRANSCRIPTION_PROVIDERS`). Any other provider in the model chain raises `ArgumentError: Provider ... does not support audio transcription` at call time. Example model IDs (see [OpenRouter's speech-to-text collection](https://openrouter.ai/collections/speech-to-text-models) for the full, current list): `openai/whisper-1`, `openai/whisper-large-v3`, `openai/gpt-4o-transcribe`, `deepgram/nova-3`, `google/chirp-3`, `nvidia/parakeet-tdt-0.6b-v3`, `mistralai/voxtral-mini-transcribe`, `qwen/qwen3-asr-flash-*`.

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

Unlike [image generation](image_generation.md), a `system_prompt` on a transcription agent is resolved but has no effect — OpenRouter's transcription endpoint accepts a `prompt` field for OpenAI-SDK compatibility but silently ignores it. There is currently no supported way to bias or guide the transcription output.

## Errors, Retry and Fallback

Transcription calls go through the same retry/fallback chain as text and image agents — see [Retry Policy](retry_policy.md). Error mapping is HTTP-status based: `401` → `InvalidApiKeyError`, `402`/`429` → `RateLimitError`, `500`-`504` → `ProviderUnavailableError`, anything else → `InvalidRequestError`.

## Synchronous — No Job ID / Polling

The transcription call is **synchronous**: the HTTP response contains the finished transcript directly, with no job id or polling step. However, **upstream providers time out after roughly 60 seconds of processing per request** — for recordings longer than about a minute, split the audio into shorter chunks yourself before transcribing each one; ActiveHarness does not do this automatically.

## Usage and Cost

Most transcription models are priced by audio duration, not by token count, so `result.usage.tokens` is typically all zeros. `result.usage.cost.total` is populated directly from the provider's own reported cost (OpenRouter returns a `usage.cost` field in its response), not computed from a per-token rate — this is generally accurate as long as the provider reports it.

## Known Caveat: Empty Transcripts

Some models can return a successful response with an empty `text` (and `usage.cost` of `0`) instead of raising an error, when they don't detect recognizable speech in the audio (e.g. very short, quiet, or unclear input) — observed with `google/chirp-3` during testing, while `openai/whisper-1` and `deepgram/nova-3` handled the same audio normally. Treat an empty `result.output` as "no speech detected" rather than assuming the call failed; if this matters for your use case, check `result.output.to_s.strip.empty?` and retry with a different model or ask the user to re-record.

## Notes

- `format :json` has no effect on transcription agents — `processed` always equals `output`.
- Streaming (`token:`) is not supported for transcription; it only applies to text agents.
