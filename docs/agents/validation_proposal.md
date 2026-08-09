# Pre-flight Validation & Errors (Proposal — Not Yet Implemented)

> **This is a design proposal, not a shipped feature.** Nothing described below exists in the codebase yet. Written to think through the design and get feedback before any code is written.

## The problem today

Right now, "is this agent going to work?" can only be answered by actually calling it. Validation is scattered and inconsistent:

- Unknown provider → `ArgumentError`, raised deep inside `attempt_model`, only surfaces mid-`.call`.
- Missing API key → `InvalidApiKeyError`, raised deep inside each provider's `#call`, only surfaces mid-`.call` (and only after a request is already half-built).
- `image true`/`transcribe true` model-capability checks → `ArgumentError`, raised inside `model_list`, which itself only runs once `.call` starts.
- Unsupported audio file extension (`transcribe true`, `:openai`) → `InvalidRequestError`, raised inside the provider, again only during `.call`.

There's no way to ask "would this agent's current config even work?" without triggering the real call path, and no single place to collect *everything* wrong with a config at once — you find issues one exception at a time, in whatever order the code happens to hit them.

There's also a deeper problem specific to the capability checks (`image true`/`transcribe true`, and the proposed `vision true`): they rely entirely on the `Pricing` registry knowing about the model and reporting the right category. That registry can be:
- **stale** (models.dev/OpenRouter data lags reality),
- **wrong** (categorization bugs upstream),
- **empty** (network/cache failure — `docs/agents/pricing.md` already documents that a fetch/cache failure returns an empty list, not an error),
- **missing the model entirely** (brand new or private models — today this is silently treated as "assume valid").

None of that is a reason to stop validating — but it *is* a reason a Pricing-based check should never be the only signal, and should be visibly distinguishable from checks that don't depend on external data at all.

## Proposed interface

```ruby
agent = SupportAgent.new(input: "Hello")

agent.valid?              # => true/false — runs validators, makes no network calls
agent.errors              # => ActiveHarness::Validation::Errors (empty if valid?)
agent.errors.full_messages
# => ["provider :openai is not configured (openai_api_key is missing)"]

agent.warnings            # => lower-confidence, Pricing-derived notes — never affects valid?
agent.warnings.full_messages
# => ["model \"some/new-model\" is not in the Pricing registry yet — capability unverified"]

agent.call if agent.valid?
```

`valid?`/`errors` would be **opt-in** — not called automatically inside `.call`. Existing code keeps working exactly as it does today; `.call` still raises real exceptions the moment something goes wrong at request time, same as now. This is a pre-flight *addition*, not a replacement for the exceptions that already guard the actual network call.

## `errors` vs `warnings` — this is the answer to "not 100% relying on Pricing"

Every check is tagged with where its certainty comes from:

| Tier | Depends on Pricing? | Surfaces as | Examples |
| --- | --- | --- | --- |
| **Structural** | No — pure Ruby/config facts | `errors` (blocks `valid?`) | provider symbol is registered in `PROVIDERS`/`IMAGE_PROVIDERS`/`TRANSCRIPTION_PROVIDERS`; `config.<provider>_api_key` is present; `@input` isn't blank; for `transcribe`/`vision`, the file exists on disk and its extension is in *that provider's own hardcoded format list* (e.g. `Providers::Audio::OpenAI::CONTENT_TYPES`) — this is a fact about the provider's API contract, not something `Pricing` reports |
| **Capability (Pricing-backed, known)** | Yes, and Pricing has an opinion | `errors` (blocks `valid?`) | `Pricing.find(model)` returns a real entry and its `categories` do **not** include the required one (`"imggen"`/`"transcription"`/`"vision"`) — a positive "no" from Pricing is fairly trustworthy, so this still blocks |
| **Capability (Pricing-backed, unknown)** | Yes, and Pricing has *no* opinion | `warnings` (never blocks `valid?`) | `Pricing.find(model)` returns `nil` — new/private model, or the registry itself is empty because of a fetch failure. Today this is silently "assumed valid" with zero visibility; the proposal keeps behavior identical but makes it *visible* as a warning instead of silent |

So a config that's structurally sound but uses a model Pricing doesn't recognize is still `valid?`, with a warning attached — Pricing being down or out of date can never turn a working config into a failing one, it can only ever add a note.

## Sketch of the data types

Deliberately hand-rolled, not an `ActiveModel::Errors` dependency — matches the "keep new dependencies minimal" constraint already in `CLAUDE.md`.

```ruby
module ActiveHarness
  module Validation
    Issue = Struct.new(:attribute, :type, :message, :severity, keyword_init: true)

    class Errors
      include Enumerable

      def initialize
        @issues = []
      end

      def add(attribute, type, message, severity: :error)
        @issues << Issue.new(attribute: attribute, type: type, message: message, severity: severity)
      end

      def each(&block) = issues_for(:error).each(&block)
      def empty? = issues_for(:error).empty?
      def full_messages = issues_for(:error).map(&:message)
      def [](attribute) = issues_for(:error).select { |i| i.attribute == attribute }.map(&:message)

      def warnings = issues_for(:warning)

      private

      def issues_for(severity) = @issues.select { |i| i.severity == severity }
    end
  end
end
```

(Exact method set to be refined — this is enough to show the shape: one flat list of tagged issues, `errors`/`warnings` are just filtered views over it, same object underneath.)

## Built-in validators

Each validator is a small, single-purpose class:

```ruby
module ActiveHarness
  module Validators
    class Base
      def initialize(agent) = @agent = agent
      def validate(errors) = raise NotImplementedError
    end
  end
end
```

Proposed built-ins, run automatically for every agent (no opt-in needed — same spirit as `image true` already auto-validating the model chain today):

- `ProviderRegisteredValidator` — structural
- `ApiKeyPresentValidator` — structural (skipped automatically when `custom_llm_backend` is set, since that path doesn't use `config.<provider>_api_key`)
- `InputPresentValidator` — structural
- `SupportedFormatValidator` — structural, only runs for `transcribe true`/`vision true` agents
- `ModelCapabilityValidator` — Pricing-backed, only runs for `image true`/`transcribe true`/`vision true` agents; emits `errors` on a confirmed mismatch, `warnings` when Pricing has no data

Any built-in could be turned off per-agent, for cases where it doesn't apply:

```ruby
class WeirdAgent < ActiveHarness::Agent
  skip_validation :api_key_present   # e.g. auth handled entirely inside a custom_llm_backend block
end
```

## Custom validators — the "separate validator class" idea

Matches your instinct — a validator is just a small class with a `validate(errors)` method, registered at the class level:

```ruby
class ProfanityValidator < ActiveHarness::Validators::Base
  def validate(errors)
    errors.add(:input, :profanity, "input contains banned terms") if BANNED_WORDS =~ @agent.input.to_s
  end
end

class SupportAgent < ActiveHarness::Agent
  validate ProfanityValidator
end
```

Or, for something too small to deserve its own class, an inline block form (consistent with the existing hooks DSL style — `on(:before_call) { ... }`):

```ruby
class SupportAgent < ActiveHarness::Agent
  validate do |agent, errors|
    errors.add(:input, :too_long, "input exceeds 4000 characters") if agent.input.to_s.length > 4000
  end
end
```

Multiple `validate` registrations accumulate and all run, same rule as hooks — no surprises there.

## Open questions for you

1. **Automatic vs. opt-in for the built-ins.** Proposal above runs them automatically (matching how `image true` already validates today) with a per-check `skip_validation` escape hatch. Would you rather flip it — nothing runs unless explicitly declared, Rails-`validates`-style?
2. **`valid?` inside `.call`.** Keep them fully decoupled (as sketched), or add an opt-in `validate_before_call true` class flag that makes `.call` run `valid?` first and raise a combined error listing everything wrong, instead of stopping at the first exception?
3. **Should `Tribunal`/`Pipeline` get this too?** E.g. `tribunal.valid?` aggregating each member agent's errors, `pipeline.valid?` aggregating each step's. Proposing this as a fast-follow, not part of the first cut.
4. **Severity naming.** `errors` / `warnings` (Rails-adjacent) vs. something else (`errors` / `notices`, or a single `issues` list with a `severity:` you filter yourself)? Also open to *not* exposing a separate `warnings` accessor at all and just keeping unknown-model cases silent as they are today, if you'd rather not add API surface for something that's rarely acted on.
5. **Where the `SupportedFormatValidator`'s format lists come from.** Each provider (`Providers::Audio::OpenAI::CONTENT_TYPES`, etc.) already hardcodes what it accepts — reusing those constants directly keeps this validator Pricing-independent, but it does mean the validator needs to know which provider-specific constant to check per entry in the model chain. Fine with that coupling, or would you rather each provider class expose a uniform `.supported_formats` class method instead of reaching into a provider-specific constant name?
