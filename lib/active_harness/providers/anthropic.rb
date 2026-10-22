require "uri"

module ActiveHarness
  module Providers
    # Anthropic Claude — native Messages API (not OpenAI-compatible).
    # https://docs.anthropic.com/en/api/messages
    class Anthropic < Base
      ANTHROPIC_VERSION = "2023-06-01"
      DEFAULT_MAX_TOKENS = 1024

      def supports_tools?
        true
      end

      def call(model:, messages:, temperature: 0.7, stream: nil, tools: nil)
        system_msg, chat_messages = extract_system(messages)

        body = {
          model:       model,
          max_tokens:  DEFAULT_MAX_TOKENS,
          temperature: temperature,
          messages:    chat_messages
        }
        body[:system] = system_msg if system_msg
        body[:tools]  = anthropic_tools(tools) if tools && !tools.empty?

        headers = {
          "Content-Type"      => "application/json",
          "x-api-key"         => api_key,
          "anthropic-version" => ANTHROPIC_VERSION
        }

        return call_streaming(
          url: config.anthropic_api_url,
          headers: headers,
          body: body,
          stream: stream,
          provider: :anthropic,
          model: model
        ) if stream && !(tools && !tools.empty?)

        raw  = post_json(URI(config.anthropic_api_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data)

        {
          content:  Array(data["content"]).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join.strip,
          provider: :anthropic,
          model:    data["model"] || model,
          usage:    extract_usage_anthropic(data),
          **anthropic_tool_calls_entry(data)
        }
      end

      private

      # Anthropic keeps system prompt separate from the messages array.
      # Also maps the neutral tool-calling message shape to Anthropic content blocks.
      def extract_system(messages)
        role_of = ->(m) { (m[:role] || m["role"]).to_s }
        system  = messages.find { |m| role_of.call(m) == "system" }
        chat    = messages.reject { |m| role_of.call(m) == "system" }.map { |m| anthropic_message(m) }

        system_text = system && (system[:content] || system["content"])
        [system_text, merge_tool_results(chat)]
      end

      def anthropic_message(m)
        role    = (m[:role] || m["role"]).to_s
        content = m[:content] || m["content"]
        calls   = m[:tool_calls] || m["tool_calls"]

        if role == "assistant" && calls && !calls.empty?
          blocks = []
          blocks << { type: "text", text: content.to_s } unless content.to_s.empty?
          calls.each { |c| blocks << { type: "tool_use", id: c[:id], name: c[:name], input: c[:arguments] || {} } }
          { role: "assistant", content: blocks }
        elsif role == "tool"
          { role: "user", content: [{ type: "tool_result", tool_use_id: m[:tool_call_id] || m["tool_call_id"], content: content.to_s }] }
        else
          { role: role, content: content }
        end
      end

      # Consecutive tool results must live in one user message.
      def merge_tool_results(chat)
        chat.each_with_object([]) do |m, out|
          prev = out.last
          if prev && prev[:role] == "user" && m[:role] == "user" &&
             prev[:content].is_a?(Array) && m[:content].is_a?(Array) &&
             prev[:content].all? { |b| b[:type] == "tool_result" } && m[:content].all? { |b| b[:type] == "tool_result" }
            prev[:content].concat(m[:content])
          else
            out << m
          end
        end
      end

      def anthropic_tools(tools)
        Array(tools).map { |t| { name: t[:name], description: t[:description].to_s, input_schema: t[:parameters] } }
      end

      def anthropic_tool_calls_entry(data)
        calls = Array(data["content"]).select { |b| b["type"] == "tool_use" }
        return {} if calls.empty?

        { tool_calls: calls.map { |b| { id: b["id"], name: b["name"], arguments: b["input"] || {}, raw_arguments: JSON.generate(b["input"] || {}) } } }
      end

      def api_key
        key = config.anthropic_api_key.to_s
        raise Errors::InvalidApiKeyError, "anthropic_api_key is not configured" if key.empty?
        key
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        type     = data.dig("error", "type").to_s
        metadata = data["error"].reject { |k, _| %w[message type].include?(k) }
        metadata = nil if metadata.empty?

        case type
        when "authentication_error"
          raise Errors::InvalidApiKeyError.new(msg,       error_code: type, metadata: metadata)
        when "rate_limit_error"
          raise Errors::RateLimitError.new(msg,           error_code: type, metadata: metadata)
        when "overloaded_error"
          raise Errors::ProviderUnavailableError.new(msg, error_code: type, metadata: metadata)
        when "api_error"
          raise Errors::ServerError.new(msg,              error_code: type, metadata: metadata)
        else
          raise Errors::InvalidRequestError.new(msg,      error_code: type, metadata: metadata)
        end
      end

      # Anthropic streaming uses plain stream: true — no stream_options.
      def prepare_streaming_body(body)
        body.merge(stream: true)
      end

      # Anthropic SSE events:
      #   message_start       → input token count
      #   content_block_delta → text token
      #   message_delta       → output token count
      def build_streaming_chunk(parsed)
        token = if parsed["type"] == "content_block_delta" && parsed.dig("delta", "type") == "text_delta"
                  parsed.dig("delta", "text")
                end

        usage = case parsed["type"]
                when "message_start"
                  { input_tokens: parsed.dig("message", "usage", "input_tokens").to_i }
                when "message_delta"
                  { output_tokens: parsed.dig("usage", "output_tokens").to_i }
                end

        { token: token, usage: usage }
      end
    end
  end
end
