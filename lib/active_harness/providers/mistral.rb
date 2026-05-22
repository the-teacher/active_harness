require "uri"

module ActiveHarness
  module Providers
    # Mistral AI — OpenAI-compatible API.
    # https://docs.mistral.ai/api
    class Mistral < Base
      API_URL = URI("https://api.mistral.ai/v1/chat/completions")

      def call(model:, messages:, temperature: 0.7)
        raw  = post_json(API_URL,
          headers: {
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{api_key}"
          },
          body: { model: model, messages: messages, temperature: temperature }
        )
        data = parse!(raw)
        handle_error!(data)

        {
          content:  data.dig("choices", 0, "message", "content").to_s.strip,
          provider: :mistral,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def api_key
        key = ENV["MISTRAL_API_KEY"].to_s
        raise Errors::InvalidApiKeyError, "MISTRAL_API_KEY is not set" if key.empty?
        key
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        type     = data.dig("error", "type").to_s
        metadata = data["error"].reject { |k, _| %w[message code type].include?(k) }
        metadata = nil if metadata.empty?

        case code
        when "1901"              # unauthorized
          raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
        when "1902"              # rate limit
          raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "500", "502",
             "503", "504"
          raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        else
          case type
          when "server_error"
            raise Errors::ServerError.new(msg,            error_code: code, metadata: metadata)
          else
            raise Errors::InvalidRequestError.new(msg,    error_code: code, metadata: metadata)
          end
        end
      end
    end
  end
end
