require "uri"

module ActiveHarness
  module Providers
    # Anthropic Claude — native Messages API (not OpenAI-compatible).
    # https://docs.anthropic.com/en/api/messages
    class Anthropic < Base
      API_URL         = URI("https://api.anthropic.com/v1/messages")
      ANTHROPIC_VERSION = "2023-06-01"
      DEFAULT_MAX_TOKENS = 1024

      def call(model:, messages:, temperature: 0.7)
        system_msg, chat_messages = extract_system(messages)

        body = {
          model:      model,
          max_tokens: DEFAULT_MAX_TOKENS,
          temperature: temperature,
          messages:   chat_messages
        }
        body[:system] = system_msg if system_msg

        raw  = post_json(API_URL,
          headers: {
            "Content-Type"      => "application/json",
            "x-api-key"         => api_key,
            "anthropic-version" => ANTHROPIC_VERSION
          },
          body: body
        )
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
        key = ENV["ANTHROPIC_API_KEY"].to_s
        raise Errors::InvalidApiKeyError, "ANTHROPIC_API_KEY is not set" if key.empty?
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
    end
  end
end
