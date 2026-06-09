# Tribunal Verdict Strategies

A tribunal collects results from all agents and then computes a single verdict.
There are three ways to define how that computation works:

1. **`verdict :strategy`** — declarative, built-in aggregation
2. **`process do`** — full custom block, receives the whole results array
3. **Constructor override** — pass `may_fail:` at call time

All three are equivalent in power. The `verdict` DSL is just a named shortcut
for the most common patterns.

---

## Built-in Strategies

### `:unanimous` — every agent must agree

Verdict is `true` only when **all** successful results evaluate to `true`.

```ruby
# with evaluator
verdict :unanimous do |result|
  result.processed["result"] == true
end

# without evaluator — true when all agents completed
verdict :unanimous
```

Equivalent `process` block:

```ruby
process do |results|
  results.all? { |r| r.processed["result"] == true }
end
```

---

### `:majority` — more than half must agree

Verdict is `true` when **more than 50%** of successful results evaluate to `true`.

```ruby
# with evaluator
verdict :majority do |result|
  result.processed["result"] == true
end

# without evaluator — true when >50% of agents completed
verdict :majority
```

Equivalent `process` block:

```ruby
process do |results|
  positive = results.count { |r| r.processed["result"] == true }
  positive > results.size / 2.0
end
```

With 3 agents: 2 positive → true, 1 positive → false.
With 4 agents: 3 positive → true, 2 positive → false.

---

## `may_fail:` — tolerate agent errors

By default, the tribunal raises `AllAgentsFailed` only when every agent errors out.
`may_fail: N` lowers that threshold: raise as soon as more than N agents fail.

```ruby
# with a custom evaluator block
verdict :majority, may_fail: 1 do |result|
  result.processed["result"] == true
end

# without a block — every successful result counts as a positive vote
verdict :majority, may_fail: 1
```

Without a block the evaluator defaults to "did this agent return any result?":

- `verdict :unanimous` → true if all agents completed without error
- `verdict :majority, may_fail: 1` → true if >50% completed, up to 1 error tolerated

The same can be expressed with a `process` block, but `may_fail:` still needs to be
passed separately because the threshold check happens before `process` runs:

```ruby
class MyTribunal < ActiveHarness::Tribunal
  def initialize(input:)
    super(input: input, agents: [...], may_fail: 1)
  end

  process do |results|
    positive = results.count { |r| r.processed["result"] == true }
    positive > results.size / 2.0
  end
end
```

Or inline when constructing a tribunal directly:

```ruby
tribunal = ActiveHarness::Tribunal.new(input: input, agents: agents, may_fail: 1)
tribunal.process { |results| results.count { |r| r.processed["result"] == true } > 1 }
tribunal.call
```

---

## Priority

When both `verdict` and `process` are declared on the same class, `process` wins:

```ruby
class MyTribunal < ActiveHarness::Tribunal
  verdict :majority do |r| r.processed["ok"] end   # ignored
  process { |results| results.length > 1 }       # used
end
```

---

## Comparison Table

|                       | `:unanimous`         | `:majority`    | `process do`              |
| --------------------- | -------------------- | -------------- | ------------------------- |
| Evaluates on          | one result           | one result     | full results array        |
| Logic                 | all positive         | >50% positive  | fully custom              |
| Block required        | no                   | no             | yes                       |
| Default (no block)    | all agents completed | >50% completed | —                         |
| `may_fail:`           | ✓ via option         | ✓ via option   | ✓ via constructor / super |
| Custom threshold      | —                    | —              | ✓                         |
| Named for readability | ✓                    | ✓              | —                         |

---

## Complete Examples

```ruby
# All 3 agents must agree — use for high-stakes decisions
class StrictTribunal < ActiveHarness::Tribunal
  verdict :unanimous do |result|
    result.processed["safe"] == true
  end
end

# 2 of 3 is enough — 1 error is tolerated
class LenientTribunal < ActiveHarness::Tribunal
  verdict :majority, may_fail: 1 do |result|
    result.processed["ok"] == true
  end
end

# Custom logic: at least 2 high-confidence positives
class CustomTribunal < ActiveHarness::Tribunal
  process do |results|
    high_confidence = results.select { |r| r.processed["confidence"].to_i >= 80 }
    high_confidence.count { |r| r.processed["result"] == true } >= 2
  end
end
```
