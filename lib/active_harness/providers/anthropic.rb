require "uri"

module ActiveHarness
  module Providers
    # Anthropic Claude — native Messages API (not OpenAI-compatible).
    # https://docs.anthropic.com/en/api/messages
    class Anthropic < Base
      ANTHROPIC_VERSION = "2023-06-01"
      DEFAULT_MAX_TOKENS = 1024

      def call(model:, messages:, temperature: 0.7, stream: nil)
        system_msg, chat_messages = extract_system(messages)

        body = {
          model:       model,
          max_tokens:  DEFAULT_MAX_TOKENS,
          temperature: temperature,
          messages:    chat_messages
        }
        body[:system] = system_msg if system_msg

        headers = {
          "Content-Type"      => "application/json",
          "x-api-key"         => api_key,
          "anthropic-version" => ANTHROPIC_VERSION
        }

        return call_streaming(url: config.anthropic_api_url, headers: headers, body: body, stream: stream, provider: :anthropic, model: model) if stream

        raw  = post_json(URI(config.anthropic_api_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data)

        {
          content:  data.dig("content", 0, "text").to_s.strip,
          provider: :anthropic,
          model:    data["model"] || model,
          usage:    extract_usage_anthropic(data)
        }
      end

      private

      # Anthropic keeps system prompt separate from the messages array.
      def extract_system(messages)
        system = messages.find { |m| m[:role] == "system" || m["role"] == "system" }
        chat   = messages.reject { |m| m[:role] == "system" || m["role"] == "system" }
                         .map { |m| { role: m[:role] || m["role"], content: m[:content] || m["content"] } }

        system_text = system && (system[:content] || system["content"])
        [system_text, chat]
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
