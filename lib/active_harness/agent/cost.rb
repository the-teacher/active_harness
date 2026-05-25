module ActiveHarness
  class Agent
    private

    # Calculates the monetary cost of a single request based on token usage
    # and pricing data from ActiveHarness::Costs.
    #
    # Returns a hash { input_cost:, output_cost:, total_cost: } in USD,
    # or nil if usage is absent or the model is not found in the pricing registry.
    def calculate_cost(model_id, usage)
      return nil if model_id.nil? || usage.nil?

      pricing = ActiveHarness::Costs.find(model_id.to_s)
      return nil unless pricing&.input_per_million && pricing&.output_per_million

      input_cost  = (usage[:input_tokens].to_f  / 1_000_000) * pricing.input_per_million
      output_cost = (usage[:output_tokens].to_f / 1_000_000) * pricing.output_per_million

      {
        input_cost:  input_cost.round(8),
        output_cost: output_cost.round(8),
        total_cost:  (input_cost + output_cost).round(8)
      }
    rescue StandardError
      nil
    end
  end
end
