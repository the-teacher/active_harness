require "json"

module ActiveHarness
  # Value objects for structured result data.

  # Pricing rates for a model (per-token, from Pricing registry).
  # nil when the model is not found in the pricing registry.
  ModelPricing = Struct.new(:input, :output, keyword_init: true)

  # Static model metadata resolved at call time.
  ModelInfo = Struct.new(
    :name,
    :provider,
    :temperature,
    :context_window,
    :pricing,         # ModelPricing or nil
    keyword_init: true
  ) do
    def to_s; name.to_s; end
    def inspect
      parts = ["name=#{name.inspect}", "provider=#{provider.inspect}"]
      parts << "temperature=#{temperature}" if temperature
      parts << "context_window=#{context_window}" if context_window
      parts << "pricing=#{pricing.inspect}" if pricing
      "#<ModelInfo #{parts.join(' ')}>"
    end
  end

  # Token counts for a single call.
  TokenCounts = Struct.new(:input, :output, :total, keyword_init: true)

  # Monetary cost of a single call in USD.
  # nil when pricing data is unavailable.
  CostBreakdown = Struct.new(:input, :output, :total, keyword_init: true)

  # Combined token + cost stats for a single request call.
  # tokens is always present (raw provider data).
  # cost is nil when pricing is unavailable.
  UsageInfo = Struct.new(:tokens, :cost, keyword_init: true)

  # Result returned by Request#call (accessible via request.result).
  #
  #   result.input            — what was passed: a String, or an Array of messages
  #   result.output           — raw string from the provider
  #   result.processed        — parsed Hash/Array for :json requests, raw string for :text
  #   result.system_prompt    — resolved system prompt string
  #   result.model            — ModelInfo (name, provider, temperature, context_window, pricing)
  #   result.model_list       — full model chain proxy
  #   result.attempts         — Array of failed attempt entries before success
  #   result.execution_time   — wall-clock seconds for the successful call
  #   result.usage            — UsageInfo (tokens + cost), nil for streaming without usage
  #   result.tool_calls       — Array of { id:, name:, arguments: } the model asked for (nil when none)
  #   result.message          — the assistant message in neutral shape, ready to append to a messages list
  #   result.warnings         — Array of non-fatal remarks, e.g. a multi-message input read as plain text
  #   result.meta             — extra facts (Agent: status, stop_reason, run_id)
  Result = Struct.new(
    :input,
    :output,
    :processed,
    :system_prompt,
    :model,           # ModelInfo
    :model_list,
    :attempts,
    :execution_time,
    :usage,           # UsageInfo or nil
    :tool_calls,      # Array<Hash> or nil
    :message,         # { role: :assistant, content:, tool_calls: } or nil
    :warnings,        # Array<String> of non-fatal remarks (nil for results not built by a Request)
    :meta,            # Hash of extra facts (an Agent puts status / stop_reason / run_id here) or nil
    keyword_init: true
  )
end
