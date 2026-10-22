# Run all tests:  ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require "./#{f}" }'
# (needs the concurrent-ruby and active_harness_pricing gems, or a sibling ../ActiveHarnessPricing checkout)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
sibling_pricing = File.expand_path("../../ActiveHarnessPricing/lib", __dir__)
$LOAD_PATH.unshift sibling_pricing if File.directory?(sibling_pricing)

require "minitest/autorun"
require "active_harness"

# A scripted LLM: every Request built by .scripted_request pops the next canned response.
class ScriptedProvider
  attr_reader :calls

  def initialize(script)
    @script = script
    @calls  = []
  end

  def supports_tools?
    true
  end

  def call(model:, messages:, temperature: nil, stream: nil, tools: nil)
    @calls << { messages: messages.map(&:dup), tools: tools }
    response = @script.shift or raise "ScriptedProvider: script exhausted"
    response = response.call(messages) if response.respond_to?(:call)
    raise response if response.is_a?(Exception)

    response
  end
end

module ScriptedLLM
  def text(content, cost: nil)
    { content: content, provider: :scripted, model: "scripted",
      usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }.merge(cost ? { provider_cost: cost } : {}) }
  end

  def tool_call(name, arguments = {}, id: nil, cost: nil)
    calls = name.is_a?(Array) ? name : [[name, arguments, id]]
    list  = calls.each_with_index.map do |(n, a, i), idx|
      { id: i || "call_#{idx + 1}", name: n, arguments: a, raw_arguments: a.is_a?(Hash) ? JSON.generate(a) : a.to_s }
    end
    text("", cost: cost).merge(tool_calls: list)
  end

  # A Request class wired to a scripted provider. Returns [request_class, provider].
  def scripted_request(script, &block)
    provider = ScriptedProvider.new(script)
    klass = Class.new(ActiveHarness::Request) do
      model { use provider: :openai, model: "scripted" }
      define_method(:resolve_provider) { |_name| provider }
      define_method(:lookup_model_cost) { |_entry| nil }
      private :resolve_provider, :lookup_model_cost
    end
    klass.class_eval(&block) if block
    [klass, provider]
  end
end

Minitest::Test.include(ScriptedLLM)

# Tools used across tests.
class EchoTool < ActiveHarness::Tool
  tool_scope  :test
  tool_name   "echo"
  description "Echo the text back"
  param :text, "Text to echo"
  def perform(input); "echo: #{input[:text]}"; end
end

class BoomTool < ActiveHarness::Tool
  tool_scope  :test
  tool_name   "boom"
  description "Always fails"
  param :why, "Reason", required: false
  def perform(_input); raise("kaboom: secret internals"); end
end
