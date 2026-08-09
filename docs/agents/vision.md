# Vision Input Agents (Proposed — Not Yet Implemented)

> **This is a design proposal, not a shipped feature.** Nothing described below exists in the codebase yet — this file exists to visualize the interface before writing any code. Do not follow these examples expecting them to work.

ActiveHarness could let agents accept images as input alongside a text prompt — "look at this and tell me X" — reusing the model chain, hooks, retry/fallback, and `system_prompt` machinery that already exists for text agents.

## Proposed interface

```ruby
class ReceiptAgent < ActiveHarness::Agent
  vision true

  system_prompt "You are an expenses auditor. Flag anything that looks like a duplicate or a personal (non-business) purchase."

  model do
    use      provider: :openai,    model: "gpt-4o-mini"
    fallback provider: :anthropic, model: "claude-haiku-4-5-20251001"
  end
end

result = ReceiptAgent.call(
  input: "Does this receipt look legitimate?",
  image: "/path/to/receipt.jpg"
)

result.output # => "This looks like a standard restaurant receipt. Nothing suspicious — itemized total matches the sum."
```

- `vision true` — class-level flag, same shape as `image true`/`transcribe true`. Validates that every model in the chain has `"vision"` in its `Pricing` categories (this category already exists in the registry today — it's derived from a model's *input* modalities, the mirror image of `"imggen"`, which is derived from *output* modalities. No changes needed on the pricing side to support this validation).
- `image:` — a new keyword at the call site, alongside the existing `input:`, `context:`, `params:`, `memory:`, `models:`, `token:`, `stream:`. Accepts:
  - a single local file path (`"/path/to/photo.jpg"`)
  - an array of paths for multiple images in one message: `image: ["front.jpg", "back.jpg"]`
  - a value that already looks like an `http(s)://` URL is passed straight through as a URL reference instead of being read and base64-encoded — saves bandwidth when the image is already hosted somewhere.
- `@input` stays exactly what it already is for a normal agent: the text part of the prompt. This is the main difference from `image true`/`transcribe true`, where `@input` had to be repurposed (image prompt text, or an audio file path) because those are single-purpose, non-chat endpoints. Vision is a **chat** call with a richer message body, so `@input` keeps its normal meaning.

## Mixing with `system_prompt` — yes, no special handling needed

Unlike image generation (where `system_prompt` had to be manually prepended into a single flat prompt string, because DALL-E/image endpoints only take one prompt field) and transcription (where `system_prompt` currently has no effect at all, because the transcription endpoint ignores it), **vision input is still a normal chat completions call** — the underlying API already supports a system message plus a user message whose content mixes text and image blocks in the same request:

```jsonc
// what the provider actually receives (OpenAI/OpenRouter shape, illustrative)
{
  "messages": [
    { "role": "system", "content": "You are an expenses auditor..." },
    { "role": "user", "content": [
        { "type": "text", "text": "Does this receipt look legitimate?" },
        { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } }
      ]
    }
  ]
}
```

So `system_prompt` (string, Prompt class, or lambda — same as any text agent) would work exactly as it already does today, with zero extra plumbing. This is the opposite situation from `image true`, where getting `system_prompt` to do anything useful required deliberately splicing it into the single prompt string (see [Image Generation](image_generation.md)).

## Multiple images

```ruby
result = ReceiptAgent.call(
  input: "Do these two receipts match the same purchase?",
  image: ["/path/receipt_a.jpg", "/path/receipt_b.jpg"]
)
```

Each path becomes its own content block in the same user message, in order.

## Provider support would be broader than `image`/`transcribe`

`image true` only works with `:openai`/`:openrouter` (dedicated image-generation endpoints). `transcribe true` only works with `:openai`/`:openrouter` (dedicated transcription endpoints). Vision input, by contrast, is a capability of the **normal chat completions endpoint** that most providers already support — `:openai`, `:anthropic`, `:gemini`, `:openrouter`, `:xai` all accept image content blocks in a chat message today. So `vision true` agents could plausibly support fallback chains across most existing text providers, not just two.

## The main implementation cost — the honest tradeoff

This is also why vision is *more* work to implement correctly than it first looks, despite reusing the chat endpoint: each provider encodes an image block differently in its request body —

- OpenAI/OpenRouter: `{"type": "image_url", "image_url": {"url": "..."}}`
- Anthropic: `{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}}`
- Gemini: `{"inline_data": {"mime_type": "image/jpeg", "data": "..."}}`

`image true`/`transcribe true` only needed one or two brand-new provider files (`providers/images/*.rb`, `providers/audio/*.rb`) because they're isolated, single-purpose endpoints. Vision input instead means teaching the **existing** `build_messages`/provider `#call` methods (`providers/openai.rb`, `providers/anthropic.rb`, `providers/gemini.rb`, `providers/openrouter.rb`, ...) to emit the right per-provider content-block shape whenever `image:` is present — touching more files, each with a provider-specific format, rather than adding a couple of new ones.

## Open questions for you before this gets built

1. Keyword name: `image:` vs. `images:` (always-plural, even for one) vs. `attachments:` (leaves room for non-image files like PDFs later)?
2. Should unsupported image formats (whatever a given provider doesn't accept) raise before the network call, same as `transcribe true` does for audio extensions?
3. Is provider coverage for v1 all of OpenAI/Anthropic/Gemini/OpenRouter/xAI, or a narrower first cut (e.g. OpenAI + Anthropic only, matching whichever two you'll actually test with a real key)?
4. Out of scope for now, but worth flagging: the `Pricing` registry also has a `"pdf"` category (documents-as-input) — same mechanism, different content type. Not proposing it here, just noting it's the next-nearest capability if vision goes well.
