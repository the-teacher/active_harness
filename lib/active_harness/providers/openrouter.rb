require "uri"

module ActiveHarness
  module Providers
    # OpenRouter — OpenAI-compatible API that proxies many models.
    class OpenRouter < Base
      # @param model    [String]
      # @param messages [Array<Hash>]  [{role:, content:}, ...]
      # @param temperature [Float]
      # @param stream   [Proc, nil]  if given, called with each token as it arrives
      # @return [Hash]  { content:, provider:, model: }
      def call(model:, messages:, temperature: 0.7, stream: nil)
        headers = {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{api_key}",
          "HTTP-Referer"  => config.openrouter_http_referer
        }
        body = { model: model, messages: messages, temperature: temperature }

        if stream
          body[:stream] = true
          content = post_json_stream(URI(config.openrouter_api_url), headers: headers, body: body, on_token: stream)
          return { content: content, provider: :openrouter, model: model }
        end

        raw  = post_json(URI(config.openrouter_api_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data)

        {
          content:  data.dig("choices", 0, "message", "content").to_s.strip,
          provider: :openrouter,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def api_key
        key = config.openrouter_api_key.to_s
        raise Errors::InvalidApiKeyError, "openrouter_api_key is not configured" if key.empty?
        key
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        metadata = data.dig("error", "metadata")

        case code
        when "401"        then raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
        when "402"        then raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "429"        then raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "500", "502",
             "503", "504" then raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        else                   raise Errors::InvalidRequestError.new(msg,      error_code: code, metadata: metadata)
        end
      end
    end
  end
end
