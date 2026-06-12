module ActiveHarness
  class Agent
    private

    # Builds a CostBreakdown for a single request from token usage and
    # pricing data from ActiveHarness::Costs.
    #
    # Returns CostBreakdown (input, output, total in USD),
    # or nil if usage is absent or the model is not found in the pricing registry.
    def calculate_cost(pricing, tokens)
      return nil unless pricing && tokens
      return nil unless pricing.input_per_million && pricing.output_per_million

      input_cost  = (tokens.input.to_f  / 1_000_000) * pricing.input_per_million
      output_cost = (tokens.output.to_f / 1_000_000) * pricing.output_per_million

      CostBreakdown.new(
        input:  input_cost.round(8),
        output: output_cost.round(8),
        total:  (input_cost + output_cost).round(8)
      )
    rescue StandardError
      nil
    end
  end
end
