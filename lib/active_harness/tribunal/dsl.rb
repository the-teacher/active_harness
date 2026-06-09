module ActiveHarness
  class Tribunal
    class << self
      # Declare agents at the class level.
      #
      #   agents PolitenessAgent, ConstructivenessAgent
      #   agents [PolitenessAgent, ConstructivenessAgent]
      def agents(*list)
        tribunal_config[:agents] = list.flatten
      end

      # Class-level process block — defines how to compute the verdict from all results.
      # Receives the full results array; return value becomes #verdict.
      # Takes priority over +verdict+ strategy if both are declared.
      #
      #   process { |results| results.all? { |r| r.processed["result"] == true } }
      def process(&block)
        tribunal_config[:process] = block
      end

      # Declarative verdict — built-in aggregation strategy with a per-result evaluator.
      #
      # Strategies:
      #   :unanimous  — verdict true when every successful result evaluates to true
      #   :majority   — verdict true when more than half of successful results evaluate to true
      #
      # Options:
      #   may_fail: N — tolerate up to N agent errors before raising AllAgentsFailed
      #                 (default: nil — raise only when all agents fail, preserving legacy behavior)
      #
      # The block receives a single Result and must return a truthy/falsy value.
      #
      #   verdict :unanimous do |result|
      #     result.processed["result"] == true
      #   end
      #
      #   verdict :majority, may_fail: 1 do |result|
      #     result.processed["result"] == true
      #   end
      VALID_STRATEGIES = %i[unanimous majority].freeze

      def verdict(strategy, may_fail: nil, &block)
        unless VALID_STRATEGIES.include?(strategy)
          raise ArgumentError,
            "Unknown verdict strategy :#{strategy}. Valid strategies: #{VALID_STRATEGIES.map { |s| ":#{s}" }.join(", ")}"
        end

        tribunal_config[:strategy]       = strategy
        tribunal_config[:may_fail]       = may_fail
        tribunal_config[:evaluate_block] = block
      end
    end
  end
end
