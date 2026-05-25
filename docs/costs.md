# Cost Calculation

ActiveHarness automatically calculates the monetary cost of every LLM call and attaches it to the `Result` object.

Cost is computed from token usage and per-model pricing data bundled with the gem (sourced from [models.dev](https://models.dev)).

---

## Reading Cost from a Result

```ruby
agent = SupportAgent.call(input: "What is your return policy?")
result = agent.result

if result.cost
  puts result.cost[:input_cost]   # => 0.00003
  puts result.cost[:output_cost]  # => 0.00024
  puts result.cost[:total_cost]   # => 0.00027
else
  puts "Cost unavailable for this model"
end
```

All values are in **USD**, rounded to 8 decimal places.

`result.cost` is `nil` when:

- The model is not found in the pricing registry.
- The provider did not return usage data (some free-tier models, streaming without usage header).
- Pricing data is missing an input or output price for the model.

---

## Pricing Registry

ActiveHarness ships with a bundled pricing snapshot (`lib/active_harness/data/models.json`).  
The registry is refreshed automatically once per day and cached to `{project_root}/tmp/active_harness/costs.json`.

**Fetch fresh data manually:**

```ruby
ActiveHarness::Costs.update   # downloads from models.dev and saves to tmp/
```

**Look up a model:**

```ruby
m = ActiveHarness::Costs.find("mistralai/mistral-nemo")
puts m.input_per_million    # => 0.15   (USD per 1M input tokens)
puts m.output_per_million   # => 0.15   (USD per 1M output tokens)
```

**Browse by provider:**

```ruby
ActiveHarness::Costs.providers.openai      # => [ModelCost, ...]
ActiveHarness::Costs.providers[:mistral]
ActiveHarness::Costs.providers.list        # => ["anthropic", "gemini", "mistral", ...]

ActiveHarness::Costs.all                   # => all models from all supported providers
```

---

## ModelCost Fields

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

- If the cache file is corrupted, the bundled snapshot is used as fallback.
- If the bundled snapshot is also unavailable, an empty registry is returned.
- If `models.dev` is unreachable during auto-refresh, the existing cache (or bundled data) is used silently.
- Any unexpected error inside `calculate_cost` returns `nil` — the agent continues normally.
