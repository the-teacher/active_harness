# Pipeline Hooks

Pipelines support two kinds of hooks: **global** (fire on every step) and **per-step** (fire only for a named step).

```ruby
class MyPipeline < ActiveHarness::Pipeline
  step :translate, TranslationAgent
  step :respond,   SupportAgent

  # ~~~ Global hooks ~~~

  before :step do |step_name, payload|
    puts "→ :#{step_name}"
  end

  after :step do |step_name, result|
    puts "✓ :#{step_name} (#{result.execution_time}s)"
  end

  callback :stopped do |step_name, result|
    puts "STOPPED at :#{step_name}"
  end

  callback :complete do |last_result|
    puts "complete"
  end

  # ~~~ Per-step hooks ~~~

  after :step, :translate do |result|
    puts "translated: #{result.output}"
  end
end
```

---

## Events

### Global hooks — fire on every step

| Event          | Alias                | Block arguments      | When it fires                                                                                               |
| -------------- | -------------------- | -------------------- | ----------------------------------------------------------------------------------------------------------- |
| `:before_step` | `before :step`       | `step_name, payload` | Before each step runs. `step_name` is a Symbol, `payload` is the current input string.                      |
| `:after_step`  | `after :step`        | `step_name, result`  | After each step completes (including steps that trigger a stop). `result` is a `Result` or Tribunal object. |
| `:stopped`     | `callback :stopped`  | `step_name, result`  | When a `stop_if` condition is met and the pipeline halts. Fires instead of continuing to the next step.     |
| `:complete`    | `callback :complete` | `last_result`        | After the final step completes successfully (pipeline was not stopped).                                     |

### Per-step hooks — fire only for the named step

| Event          | Alias                 | Block arguments | When it fires                                                       |
| -------------- | --------------------- | --------------- | ------------------------------------------------------------------- |
| `:before_step` | `before :step, :name` | `payload`       | Before this specific step. No `step_name` argument — it's implicit. |
| `:after_step`  | `after :step, :name`  | `result`        | After this specific step.                                           |

Per-step hooks fire **in addition to** global hooks, not instead of them.

---

## Registration syntax

```ruby
# Global
on       :before_step   do |step_name, payload| ... end
on       :after_step    do |step_name, result|  ... end
on       :stopped       do |step_name, result|  ... end
on       :complete      do |last_result|        ... end

# Rails-style aliases (global)
before   :step          do |step_name, payload| ... end
after    :step          do |step_name, result|  ... end
callback :stopped       do |step_name, result|  ... end
callback :complete      do |last_result|        ... end

# Per-step
on       :before_step, :step_name  do |payload| ... end
on       :after_step,  :step_name  do |result|  ... end

# Rails-style aliases (per-step)
before   :step, :step_name  do |payload| ... end
after    :step, :step_name  do |result|  ... end
```

---

## Execution order (per step)

```
:before_step  (global, with step_name)
:before_step  (per-step, without step_name)
  → step runs
:after_step   (global, with step_name)
:after_step   (per-step, without step_name)
  → if stop_if fires:
    :stopped  (global)
    [pipeline halts]
  → if last step:
    :complete (global)
```

---

## Notes

- `:stopped` and `:complete` are mutually exclusive — only one fires per pipeline run.
- `pipeline.stopped?`, `pipeline.stopped_at`, and `pipeline.output` are available after `call`.
- `pipeline.steps` is an enumerator yielding `(step_name, executor, result)` for every step that ran — use `.each`, `.map`, `.find`, or `.to_a`.
- `pipeline.execution_time` is the total wall time across all steps that ran.
