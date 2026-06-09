require "json"

module ActiveHarness
  # Minimal result wrapper returned by Agent#call.
  #
  # output — raw string from the provider
  # processed — for format :json: a Ruby Hash/Array; for format :text: same as output
  # usage  — token counts: { input_tokens:, output_tokens:, total_tokens: } or nil for streaming
  # cost   — { input_cost:, output_cost:, total_cost: } in USD, or nil if pricing unavailable
  Result = Struct.new(
    :input,
    :output,
    :processed,
    :system_prompt,
    :provider, :model,
    :temperature,
    :model_list,
    :attempts,
    :execution_time,
    :usage,
    :cost,
    :context_window,
    keyword_init: true)
end
