module ActiveHarness
  class Tribunal
    # Instance-level process block — overrides class-level block.
    #
    #   tribunal.process { |results| results.count { |r| r.processed["ok"] } >= 2 }
    def process(&block)
      @process_block = block
      self
    end

    private

    # Selects and executes the verdict computation in order of priority:
    #   1. Instance-level process block (set via tribunal.process { ... })
    #   2. Class-level process block    (set via `process do ... end` in subclass)
    #   3. Class-level strategy         (set via `verdict :unanimous/:majority`)
    #   4. nil                          (no verdict computation declared)
    def compute_verdict(results)
      if @process_block
        @process_block.call(results)
      elsif @strategy
        apply_strategy(@strategy, results)
      end
    end

    # Built-in aggregation strategies.
    #
    # Without an evaluate_block every successful result is treated as a positive vote.
    # With an evaluate_block the block decides whether each result counts as positive.
    #
    # :unanimous — all positive votes required
    # :majority  — more than 50% positive votes required
    def apply_strategy(strategy, results)
      evaluate = @evaluate_block || ->(r) { r }
      votes    = results.map { |r| evaluate.call(r) ? true : false }
      positive = votes.count(true)

      case strategy
      when :unanimous then positive == votes.size
      when :majority  then positive > votes.size / 2.0
      end
    end
  end
end
