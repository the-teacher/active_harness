require "test_helper"

class InputTest < Minitest::Test
  CONVERSATION = [
    { role: :user,      content: "first question" },
    { role: :assistant, content: "first answer" },
    { role: :tool,      content: "tool output", name: "os__ls" },
    { role: :user,      content: "second question" }
  ].freeze

  def build(system_prompt = nil, &block)
    script = [text("ok")]
    req, provider = scripted_request(script) do
      system_prompt(system_prompt) if system_prompt
      class_eval(&block) if block
    end
    [req, provider]
  end

  def test_string_input_is_unchanged
    req, provider = build
    r = req.call(input: "  Hello   world ").result

    assert_equal "Hello world", r.input
    assert_equal [{ role: "user", content: "Hello world" }], provider.calls.first[:messages].map { |m| { role: m[:role].to_s, content: m[:content] } }
    assert_equal [], r.warnings
  end

  def test_array_input_is_a_conversation
    req, provider = build("Be brief.")
    r = req.call(input: CONVERSATION).result

    assert_equal CONVERSATION, r.input
    assert_equal "ok", r.output
    sent = provider.calls.first[:messages]
    assert_equal %w[system user assistant tool user], sent.map { |m| m[:role].to_s }
  end

  def test_there_is_no_messages_keyword
    req, = build
    assert_raises(ArgumentError) { req.call(messages: CONVERSATION) }
    refute_respond_to req.new, :messages
  end

  def test_constructor_accepts_an_array_input
    req, = build
    request = req.new(input: CONVERSATION)

    assert_equal CONVERSATION, request.input
    assert_equal "second question", request.input_text
  end

  def test_input_text_and_transcript_helpers
    req, = build
    request = req.new(input: CONVERSATION)

    assert_equal "second question", request.input_text
    assert_equal "first question\n\nsecond question", request.input_text(roles: [:user])
    assert_equal "user: first question\nassistant: first answer\ntool(os__ls): tool output\nuser: second question", request.transcript

    plain = req.new(input: "hi")
    assert_equal "hi", plain.input_text
    assert_equal "user: hi", plain.transcript
  end

  def test_content_parts_are_joined_as_text
    req, = build
    request = req.new(input: [{ role: :user, content: [{ type: "text", text: "a" }, { type: "text", text: "b" }] }])
    assert_equal "ab", request.input_text
  end

  def test_prompt_class_gets_text_input_and_transcript
    prompt = Class.new do
      def call; "Q=#{@input}|T=#{@transcript.lines.size}"; end
    end
    req, provider = build(prompt)
    req.call(input: CONVERSATION)

    assert_equal "Q=second question|T=4", provider.calls.first[:messages].first[:content]
  end

  def test_multi_message_input_with_dynamic_prompt_warns_once_and_still_works
    events = []
    stream = ->(source, event, *args) { events << [source, event, *args] }
    req, provider = build(-> { "Answer: #{@input}" })
    r = req.call(input: CONVERSATION, stream: stream).result

    assert_equal [ActiveHarness::Request::MULTI_MESSAGE_WARNING], r.warnings
    assert_includes events, [:request, :warning, ActiveHarness::Request::MULTI_MESSAGE_WARNING]
    assert_equal "Answer: second question", provider.calls.first[:messages].first[:content]
    assert_equal "ok", r.output
  end

  def test_warning_hook
    seen = []
    req, = build(-> { @input }) { on(:warning) { |m| seen << m } }
    req.call(input: CONVERSATION)

    assert_equal [ActiveHarness::Request::MULTI_MESSAGE_WARNING], seen
  end

  def test_no_warning_for_single_message_or_static_prompt
    req, = build(-> { @input })
    assert_equal [], req.call(input: [{ role: :user, content: "one" }]).result.warnings

    req, = build("static prompt")
    assert_equal [], req.call(input: CONVERSATION).result.warnings
  end

  def test_warnings_are_reset_between_calls
    req, = scripted_request([text("one"), text("two")]) { system_prompt(-> { @input }) }
    request = req.new
    request.call(CONVERSATION)
    assert_equal 1, request.warnings.size

    request.call("just one message")
    assert_equal [], request.warnings
    assert_equal [], request.result.warnings
  end

  def test_image_and_transcription_reject_arrays
    image = Class.new(ActiveHarness::Request) do
      image true
      model { use provider: :openai, model: "dall-e-3" }
    end
    assert_raises(ArgumentError) { image.new(input: CONVERSATION).send(:attempt_image_model, { provider: :openai, model: "x" }, nil) }

    audio = Class.new(ActiveHarness::Request) do
      transcribe true
      model { use provider: :openai, model: "whisper-1" }
    end
    assert_raises(ArgumentError) { audio.new(input: CONVERSATION).send(:attempt_transcription_model, { provider: :openai, model: "x" }) }
  end
end
