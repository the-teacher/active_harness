require "json"

module ActiveHarness
  # Minimal result wrapper returned by Agent#call.
  #
  # output — raw string from the provider
  # parsed — for format :json: a Ruby Hash/Array; for format :text: same as output
  # usage  — token counts: { input_tokens:, output_tokens:, total_tokens: } or nil for streaming
  # cost   — { input_cost:, output_cost:, total_cost: } in USD, or nil if pricing unavailable
  Result = Struct.new(:input, :output, :parsed, :system_prompt, :provider, :model, :temperature, :model_list, :attempts, :execution_time, :usage, :cost, keyword_init: true)
end
