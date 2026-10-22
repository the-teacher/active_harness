require "test_helper"

class ProviderToolsTest < Minitest::Test
  SCHEMA = { name: "os__ls", description: "List", parameters: { type: "object", properties: { "path" => { type: "string" } }, required: ["path"] } }.freeze

  CONVERSATION = [
    { role: "system", content: "sys" },
    { role: :user, content: "list it" },
    { role: :assistant, content: "", tool_calls: [{ id: "c1", name: "os__ls", arguments: { path: "/" } }] },
    { role: :tool, tool_call_id: "c1", name: "os__ls", content: "a.txt" },
    { role: :tool, tool_call_id: "c2", name: "os__ls", content: "b.txt" }
  ].freeze

  # Capture the HTTP body instead of calling the network.
  def stub_post(provider, response)
    sent = {}
    provider.define_singleton_method(:post_json) { |url, headers:, body:, timeout: 30| sent.merge!(url: url.to_s, headers: headers, body: body); JSON.generate(response) }
    sent
  end

  def with_keys
    ActiveHarness.configure { |c| c.openai_api_key = "k"; c.anthropic_api_key = "k" }
    yield
  ensure
    ActiveHarness.reset_config!
  end

  def test_openai_sends_tools_and_maps_the_conversation
    with_keys do
      provider = ActiveHarness::Providers::OpenAI.new
      sent = stub_post(provider, {
        "model" => "gpt", "usage" => { "prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3 },
        "choices" => [{ "message" => { "content" => nil, "tool_calls" => [
          { "id" => "call_9", "type" => "function", "function" => { "name" => "os__ls", "arguments" => "{\"path\":\"/srv\"}" } },
          { "id" => "call_10", "type" => "function", "function" => { "name" => "os__ls", "arguments" => "oops" } }
        ] } }]
      })

      res = provider.call(model: "gpt", messages: CONVERSATION, tools: [SCHEMA], stream: ->(_) { flunk("must not stream with tools") })

      body = sent[:body]
      assert_equal [{ type: "function", function: { name: "os__ls", description: "List", parameters: SCHEMA[:parameters] } }], body[:tools]
      assistant = body[:messages][2]
      assert_nil assistant[:content]
      assert_equal({ id: "c1", type: "function", function: { name: "os__ls", arguments: "{\"path\":\"/\"}" } }, assistant[:tool_calls].first)
      assert_equal({ role: "tool", tool_call_id: "c1", content: "a.txt" }, body[:messages][3])
      assert_equal "sys", body[:messages][0][:content]

      assert_equal "", res[:content]
      assert_equal [{ id: "call_9", name: "os__ls", arguments: { "path" => "/srv" }, raw_arguments: "{\"path\":\"/srv\"}" },
                    { id: "call_10", name: "os__ls", arguments: nil, raw_arguments: "oops" }], res[:tool_calls]
    end
  end

  def test_openai_without_tools_is_unchanged
    with_keys do
      provider = ActiveHarness::Providers::OpenAI.new
      sent = stub_post(provider, { "model" => "gpt", "choices" => [{ "message" => { "content" => " hi " } }] })
      res = provider.call(model: "gpt", messages: [{ role: "user", content: "x" }])

      refute sent[:body].key?(:tools)
      assert_equal [{ role: "user", content: "x" }], sent[:body][:messages]
      assert_equal "hi", res[:content]
      refute res.key?(:tool_calls)
    end
  end

  def test_anthropic_maps_tool_use_and_tool_results
    with_keys do
      provider = ActiveHarness::Providers::Anthropic.new
      sent = stub_post(provider, {
        "model" => "claude", "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
        "content" => [{ "type" => "text", "text" => "Looking" }, { "type" => "tool_use", "id" => "tu_1", "name" => "os__ls", "input" => { "path" => "/" } }]
      })
      res = provider.call(model: "claude", messages: CONVERSATION, tools: [SCHEMA])

      body = sent[:body]
      assert_equal "sys", body[:system]
      assert_equal [{ name: "os__ls", description: "List", input_schema: SCHEMA[:parameters] }], body[:tools]
      assert_equal [:user, :assistant, :user].map(&:to_s), body[:messages].map { |m| m[:role].to_s }
      assert_equal [{ type: "tool_use", id: "c1", name: "os__ls", input: { path: "/" } }], body[:messages][1][:content]
      # two consecutive tool results are merged into one user message
      assert_equal [%w[tool_result tool_result], %w[c1 c2]],
                   [body[:messages][2][:content].map { |b| b[:type] }, body[:messages][2][:content].map { |b| b[:tool_use_id] }]

      assert_equal "Looking", res[:content]
      assert_equal [{ id: "tu_1", name: "os__ls", arguments: { "path" => "/" }, raw_arguments: "{\"path\":\"/\"}" }], res[:tool_calls]
    end
  end

  def test_supported_providers
    %i[OpenAI OpenRouter Groq XAI DeepSeek Mistral Ollama Anthropic].each do |name|
      assert ActiveHarness::Providers.const_get(name).new.supports_tools?, "#{name} should support tools"
    end
    refute ActiveHarness::Providers::Gemini.new.supports_tools?
  end

  def test_request_skips_a_provider_without_tool_support
    unsupported = Object.new
    def unsupported.call(**); flunk("must not be called"); end
    supported = ScriptedProvider.new([{ content: "from fallback", provider: :x, model: "m" }])

    klass = Class.new(ActiveHarness::Request) do
      model do
        use      provider: :gemini, model: "a", retry_attempts: 1
        fallback provider: :openai, model: "b", retry_attempts: 1
      end
      define_method(:resolve_provider) { |name| name == :gemini ? ActiveHarness::Providers::Gemini.new : supported }
      define_method(:lookup_model_cost) { |_| nil }
      private :resolve_provider, :lookup_model_cost
    end

    req = klass.call(messages: [{ role: :user, content: "hi" }], tools: [SCHEMA])
    assert_equal "from fallback", req.result.output
    assert_equal 1, req.result.attempts.size
    assert_match(/does not support tool calling/, req.result.attempts.first[:error])
  end

  def test_request_conversation_mode
    req, provider = scripted_request([{ content: "", provider: :x, model: "m", tool_calls: [{ id: "c1", name: "os__ls", arguments: { "path" => "/" }, raw_arguments: "{}" }] }]) do
      system_prompt "You are a file assistant."
    end
    messages = [{ role: :user, content: "list" }]
    r = req.call(messages: messages, tools: [SCHEMA]).result

    sent = provider.calls.first[:messages]
    assert_equal ["system", "user"], sent.map { |m| m[:role].to_s }
    assert_equal "You are a file assistant.", sent.first[:content]
    assert_equal "list", r.input
    assert_equal [{ id: "c1", name: "os__ls", arguments: { "path" => "/" }, raw_arguments: "{}" }], r.tool_calls
    assert_equal :assistant, r.message[:role]
    assert_equal r.tool_calls, r.message[:tool_calls]
  end

  def test_request_plain_input_still_works
    req, provider = scripted_request([{ content: "pong", provider: :x, model: "m" }])
    r = req.call(input: "  ping  ").result

    assert_equal [{ role: "user", content: "ping" }], provider.calls.first[:messages]
    assert_equal "pong", r.output
    assert_nil r.tool_calls
    assert_nil r.message
  end
end
