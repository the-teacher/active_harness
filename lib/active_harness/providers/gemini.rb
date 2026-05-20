require "uri"

module ActiveHarness
  module Providers
    # Google Gemini — OpenAI-compatible endpoint (beta).
    # https://ai.google.dev/gemini-api/docs/openai
    class Gemini < Base
      API_URL = URI("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")

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
          provider: :gemini,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def api_key
        key = ENV["GEMINI_API_KEY"].to_s
        raise Errors::InvalidApiKeyError, "GEMINI_API_KEY is not set" if key.empty?
        key
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        status   = data.dig("error", "status").to_s
        metadata = data["error"].reject { |k, _| %w[message code status].include?(k) }
        metadata = nil if metadata.empty?

        case status
        when "UNAUTHENTICATED"
          raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
        when "RESOURCE_EXHAUSTED"
          raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "UNAVAILABLE"
          raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        when "INTERNAL"
          raise Errors::ServerError.new(msg,              error_code: code, metadata: metadata)
        else
          raise Errors::InvalidRequestError.new(msg,      error_code: code, metadata: metadata)
        end
      end
    end
  end
end
