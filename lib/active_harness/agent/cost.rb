module ActiveHarness
  class Agent
    # Providers that have a dedicated pricing source beyond ModelsDev.
    # Consulted in tier-2 before the general ModelsDev fallback.
    # Add entries here when a new provider-specific source is available.
    PROVIDER_PRICING_SOURCES = {
      openrouter: Pricing::OpenRouter
    }.freeze

    private

    # Cost lookup — three-tier fallback:
    #   1. provider_cost in the API response  (handled in build_usage)
    #   2. provider-specific source           (e.g. Pricing::OpenRouter for :openrouter)
    #   3. Pricing::ModelsDev general fallback
    #   → nil when no data found at any tier
    def lookup_model_cost(entry)
      return nil unless entry

      model    = entry[:model].to_s
      provider = entry[:provider].to_sym

      source = PROVIDER_PRICING_SOURCES[provider]
      cost   = source&.find(model)
      return cost if cost

      Pricing::ModelsDev.find(model)
    rescue StandardError
      nil
    end

    # Builds a CostBreakdown from token counts and per-million rates.
    # Returns nil when pricing or token data is absent.
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
