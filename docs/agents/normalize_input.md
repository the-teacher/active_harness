# Input Normalization

Before every call, ActiveHarness automatically normalizes `@input` by stripping leading and trailing whitespace and collapsing internal whitespace sequences to a single space.

```
"  Hello   world\n" → "Hello world"
```

This is enabled by default to trim unnecessary tokens and avoid subtle formatting issues.

## Disabling

To opt out for a specific agent:

```ruby
class VerbatimAgent < ActiveHarness::Agent
  normalize_input false
end
```

## How it works

Normalization runs in two places:

1. **`initialize`** — applied immediately after `@input` is set, before the `:setup` hook fires.
2. **`call(input)`** — applied when input is passed inline to `call`.

The equivalent transformation is:

```ruby
@input = @input&.strip&.gsub(/\s+/, " ")
```

## Notes

- `normalize_input false` only affects the automatic normalization. You can still normalize manually inside a `:setup` hook or `:before_call` hook if custom logic is needed.
- The option applies at the class level and is inherited by subclasses unless overridden.
- `nil` input is left as `nil` (the safe-navigation operator `&.` protects against it).
