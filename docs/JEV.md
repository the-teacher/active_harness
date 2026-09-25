# Jev (TypeSafe AI)

## What it is

**Jev** is a proprietary model from **TypeSafe AI** (San Francisco, founded 2024), released in limited early access on 2026-09-15. TypeSafe calls it the first of a new model class it dubs **"System One models"** — named after Kahneman's fast, intuitive "System 1" thinking.

Unlike a conventional LLM, Jev does **not generate natural-language text**. It returns **typed values with probability estimates and confidence scores** instead. TypeSafe claims this makes it up to 100x faster and 100x cheaper than conventional LLMs for tasks that fit this shape, while staying competitive on intelligence.

Founded by Diogo Almeida, Erik Gafni, and Sasha Sheng (Almeida previously spent ~4 years at OpenAI on RLHF/InstructGPT/ChatGPT/GPT-4). Announced alongside a $40M seed round led by DCVC.

## Pricing

- Input: $0.042 / MTok
- Output: $0 / MTok

## API

- Single endpoint: `POST https://api.typesafe.ai/v1/systemone`
- Base URL (`https://api.typesafe.ai`) is overridable.
- Auth: `Authorization: Bearer <token>` header — either a TypeSafe API key or a Vercel OIDC token.

## Getting access

- Still in **limited early access** (as of this writing, ~10 days old) — direct signup likely gated by a waitlist via the TypeSafe dashboard.
- API key goes in the `TYPESAFE_AI_API_KEY` env var.
- Alternative path with no waitlist mentioned: the model is also available through **Vercel AI Gateway**, authenticated with a Vercel AI Gateway key instead of a TypeSafe key directly.

## Request shape

A `systemone`/`evaluate` call always has the same three top-level fields:

| Field | Type | Meaning |
|---|---|---|
| `model` | string | e.g. `"typesafe-ai/jev"` |
| `state` | string \| object \| array | The thing being evaluated. Accepts raw structured data (an object, an array, a message history) directly — no need to serialize it yourself. |
| `questions` | object | A map of `question_name => question definition`. Multiple questions can be asked against the same `state` in one round trip. |

Each entry in `questions` is itself an object shaped by its `type`:

| Type | Required fields | `criteria` shape | What it answers |
|---|---|---|---|
| `noul` (TypeSafe-native name) / `boolean` (AI SDK / generic `/v1/evaluate` name) | `instructions` | Optional. `{ true: "...", false: "..." }` — describes what each outcome means. Works fine with no `criteria` at all. | A single probability that the state satisfies the instruction. |
| `choice` | `instructions`, `criteria` (required) | `{ optionName: "description", ... }` — a hash, one entry per option. | Which single option best fits the state, plus a probability per option. |
| `score` | `instructions`, `criteria` (required) | `[ "lowest label", ..., "highest label" ]` — an **ordered array** of at least 2 labels. | Where the state falls on that ordered scale, interpolated as a float. |

Sending `score` or `choice` without `criteria` fails validation (`error_type: "invalid_request"`, message like `questions.answer.criteria: Invalid input: expected array, received undefined`) — confirmed directly against the live API while building the ActiveHarness provider. `noul`/`boolean` is the only type that works with zero extra setup.

## Response shape

```json
{
  "model": "typesafe-ai/jev",
  "answers": {
    "<question_name>": { "type": "noul",   "noul": 0.97 },
    "<question_name>": { "type": "choice", "choice": "billing", "probabilities": { "billing": 1, "shipping": 0, "technical": 0 } },
    "<question_name>": { "type": "score",  "score": 2.97, "probabilities": { "0": 0, "1": 0, "2": 0.02, "3": 0.98 } }
  },
  "usage": { "input_tokens": 275, "output_tokens": 20 },
  "provider_metadata": {
    "gateway": {
      "routing": { "originalModelId": "...", "resolvedProvider": "typesafe-ai", "finalProvider": "typesafe-ai" },
      "cost": "0.00001155", "marketCost": "0.00001155", "surchargeCost": "0", "gatewayCost": "0.00001155",
      "generationId": "gen_..."
    }
  }
}
```

- `answers.<name>.type` always echoes the question's own type back.
- The value field is named **after the type**: `noul` questions answer under a `noul` key (0..1 float), `choice` questions answer under `choice` (the winning option's name) plus a `probabilities` hash across every option, `score` questions answer under `score` (interpolated float) plus a `probabilities` hash across every rung index.
- `usage` is input/output token counts only — no pricing/cost field of its own; the per-request dollar cost lives under `provider_metadata.gateway.cost` (Gateway's own accounting), not in `usage`.
- Going through the AI SDK's generic `/v1/evaluate` instead of the TypeSafe-branded `/typesafe/v1/systemone` endpoint renames a few fields camelCase-style (`inputTokens`/`outputTokens`, `providerMetadata`, `type: "boolean"`/`probability` instead of `type: "noul"`/`noul`) — same data, different casing/naming convention depending on which endpoint you call.
- **Observed live but not documented anywhere above**: real `choice`/`score` answers also include a `confidence` field (how concentrated the probability distribution is — separate from the winning option's own probability), and `score` answers include a `legend` object mapping each probability-distribution index to its original `criteria` label (e.g. `{"0": "very negative", ..., "4": "very positive"}`), so a consumer doesn't have to remember the `criteria` array it sent to interpret the index keys in `probabilities`. Confirmed via a live call while building the ActiveHarness demo (`app/ai/requests/jev_request.rb` in the `rails7-startkit` playground) — the official docs' example JSON just doesn't show these fields, they aren't undocumented/unstable per se.
- Errors come in two shapes depending on failure class: request-validation errors are flat (`{ "message": "...", "error_type": "invalid_request" }`), while account/billing-level errors (e.g. no payment method on file) come back nested, OpenAI-style (`{ "error": { "message": "...", "type": "customer_verification_required" } }`). ActiveHarness's provider (see below) handles both.

## Use cases

Real applications combine several question types against the same `state` in one call:

- **Support ticket triage** — `choice` picks the destination team (billing/technical/account/other), a `score` rates severity, a `boolean` flags whether a refund was requested. Low-confidence or high-severity results escalate to a human instead of auto-routing.
- **Refund/action detection** — a single `boolean` question ("Was a refund issued?") with `criteria` spelling out what counts as true vs. false, run against a support transcript.
- **Agent tool-call risk gating** — `boolean` questions for destructive intent / production-system access, plus a `choice` question to categorize the command, used to auto-approve routine tool calls and pause risky ones for human confirmation. Jev only classifies risk here; the calling application still owns the actual authorization decision.
- **Content moderation** — a `choice` question for topic/category, a `score` for sentiment, `boolean` questions for spam or leaked personal information — run together to decide whether a submission (e.g. a product review) auto-publishes or goes to a human review queue.

The common pattern: Jev's job stops at "classify/score/flag this text," never at "take the action" — the branching logic (auto-approve vs. escalate, publish vs. hold) always lives in the calling application, not in the model call itself.

## Relevance to ActiveHarness

**Implemented.** `ActiveHarness::Providers::Vercel` (`lib/active_harness/providers/vercel.rb`), registered as `provider: :vercel`, config via `vercel_api_key`/`vercel_api_url` (`ENV["VERCEL_API_KEY"]` by default).

Given the request/response mismatch described above, `Request` itself still has no typed-questions DSL — instead, `use provider: :vercel, model: "...", questions: {...}` (in the `model do ... end` block) accepts a `questions:` hash already in the API's own exact shape (added to `ModelConfig#use`/`#fallback` and threaded through in `attempt_model`, see `lib/active_harness/request/models.rb` and `request/providers.rb`). Omit `questions:` and the provider falls back to a single default `noul` question built from the system prompt (the simplest case, needs no `criteria`). Either way `@input` always becomes `state`, and the raw `answers` object goes into `content` — no interpretation of `choice`/`score`/probabilities happens inside the gem. With `format :json` on the `Request` subclass, `result.processed` is that `answers` object as a real parsed Hash.

A demo combining all three question types in one call lives in the `rails7-startkit` playground: `app/ai/requests/jev_request.rb` + `/ai/requests/jev` — shows the full raw structure and a small client-side-only "final result" summary (`app/javascript/ai_request_jev.js`) derived from it for display purposes.

Structured (non-string) `state` (object/array instead of a plain string) still isn't supported — `state` is always built from the last user message's string content — but nothing has needed it yet.

## Sources

- [Introduction - TypeSafe AI](https://docs.typesafe.ai/introduction)
- [API reference - TypeSafe AI](https://docs.typesafe.ai/api)
- [Home - TypeSafe AI](https://typesafe.ai/)
- [Introducing System One Models & Jev - TypeSafe AI Blog](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
- [Jev (AI model) - Wikipedia](https://en.wikipedia.org/wiki/Jev_(AI_model))
- [How to Get a Jev API Key (TypeSafe AI)?](https://apidog.com/blog/jev-api-key/)
- [TypeSafe API with AI Gateway - Vercel Docs](https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe) — exact request/response/error shapes for the TypeSafe-branded endpoint
- [Evaluation - Vercel AI Gateway Docs](https://vercel.com/docs/ai-gateway/modalities/evaluation) — full `noul`/`boolean`, `choice`, `score` question-type schemas and the generic `/v1/evaluate` HTTP API
- [AI Gateway Evaluation Quickstart - Vercel Docs](https://vercel.com/docs/ai-gateway/getting-started/evaluation)
- [Classify, route, and score with Jev and AI SDK - Vercel KB](https://vercel.com/kb/guide/typesafe-jev-and-ai-sdk)
- [Moderate product reviews with Jev, TanStack AI, and AI Gateway - Vercel KB](https://vercel.com/kb/guide/moderate-product-reviews-jev-tanstack-ai)
