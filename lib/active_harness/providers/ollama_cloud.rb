require "uri"

module ActiveHarness
  module Providers
    # Ollama Cloud — hosted Ollama models, OpenAI-compatible API (key required).
    # https://docs.ollama.com/cloud
    #
    # For a local Ollama server use provider: :ollama instead.
    #
    # Example:
    #   model do
    #     use provider: :ollama_cloud, model: "gpt-oss:120b"
    #   end
    class OllamaCloud < Base
      def call(model:, messages:, temperature: 0.7, stream: nil)
        headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key}" }
        body    = { model: model, messages: messages, temperature: temperature }

        return call_streaming(url: config.ollama_cloud_api_url, headers: headers, body: body, stream: stream, provider: :ollama_cloud, model: model) if stream

        raw  = post_json(URI(config.ollama_cloud_api_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data)

        {
          content:  data.dig("choices", 0, "message", "content").to_s.strip,
          provider: :ollama_cloud,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def api_key
        key = config.ollama_cloud_api_key.to_s
        raise Errors::InvalidApiKeyError, "ollama_cloud_api_key is not configured" if key.empty?
        key
      end

      def handle_error!(data)
        return unless data["error"]

        err      = data["error"]
        msg      = err.is_a?(Hash) ? err["message"].to_s : err.to_s
        code     = err.is_a?(Hash) ? err["code"].to_s : ""
        metadata = err.is_a?(Hash) ? err.reject { |k, _| %w[message code].include?(k) } : {}
        metadata = nil if metadata.empty?

        case code
        when "401", "invalid_api_key", "unauthorized"
          raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
        when "429", "rate_limit_exceeded"
          raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "500", "502", "503", "504"
          raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        else
          raise Errors::InvalidRequestError.new(msg,      error_code: code, metadata: metadata)
        end
      end
    end
  end
end
