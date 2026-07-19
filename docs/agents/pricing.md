# Cost Calculation

ActiveHarness automatically calculates the monetary cost of every LLM call and attaches it to the `Result` object.

Cost is computed from token usage and per-model pricing data bundled with the gem (sourced from [models.dev](https://models.dev)).

---

## Reading Cost from a Result

```ruby
agent = SupportAgent.call(input: "What is your return policy?")
result = agent.result

if result.usage.cost
  puts result.usage.cost.input   # => 0.00003
  puts result.usage.cost.output  # => 0.00024
  puts result.usage.cost.total   # => 0.00027
else
  puts "Cost unavailable for this model"
end
```

All values are in **USD**, rounded to 8 decimal places.

`result.usage.cost` is `nil` when:

- The model is not found in the pricing registry.
- The provider did not return usage data (some free-tier models, streaming without usage header).
- Pricing data is missing an input or output price for the model.

---

## Pricing Registry

Pricing data is provided by the separate `active_harness_pricing` gem (a runtime dependency of ActiveHarness, `require "active_harness_pricing"` — not code that lives in this repo). It fetches model data from [models.dev](https://models.dev) and caches it to `{project_root}/tmp/active_harness/models_dev_pricing.json`. The cache (and the in-memory copy) is considered fresh for 72 hours; once stale, the next lookup triggers a background refetch automatically.

**Force a refresh manually:**

```ruby
ActiveHarness::Pricing.preload!   # re-fetches from models.dev; network failures are silently ignored
```

There is no public `ActiveHarness::Pricing.update` — that method only exists on the internal `ActiveHarness::Pricing::ModelsDev` source (`ActiveHarness::Pricing::ModelsDev.update`), which raises on failure instead of swallowing it.

**Look up a model:**

```ruby
m = ActiveHarness::Pricing.find("mistralai/mistral-nemo")
puts m.input_per_million    # => 0.15   (USD per 1M input tokens)
puts m.output_per_million   # => 0.15   (USD per 1M output tokens)
```

**Browse by provider:**

```ruby
ActiveHarness::Pricing.providers.openai      # => [ModelPrice, ...]
ActiveHarness::Pricing.providers[:mistral]
ActiveHarness::Pricing.providers.list        # => ["anthropic", "gemini", "mistral", ...]

ActiveHarness::Pricing.all                   # => all models from all supported providers
```

---

## ModelPrice Fields

| Field                           | Type        | Description                       |
| ------------------------------- | ----------- | --------------------------------- |
| `id`                            | String      | Model identifier, e.g. `"gpt-4o"` |
| `name`                          | String      | Human-readable name               |
| `provider`                      | String      | Provider name, e.g. `"openai"`    |
| `input_per_million`             | Float / nil | USD per 1M input tokens           |
| `output_per_million`            | Float / nil | USD per 1M output tokens          |
| `cache_read_input_per_million`  | Float / nil | USD per 1M cache-read tokens      |
| `cache_write_input_per_million` | Float / nil | USD per 1M cache-write tokens     |

---

## Resilience

The cost module is designed to never raise or interrupt an agent call:

- There is no bundled pricing snapshot in this gem — if the cache file is missing or corrupted and `models.dev` cannot be reached, the registry is simply empty (`Pricing.all` returns `[]`, `Pricing.find` returns `nil`).
- If `models.dev` is unreachable during auto-refresh, the existing (possibly stale) cache is used silently instead.
- Any unexpected error inside `calculate_cost` returns `nil` — the agent continues normally.
