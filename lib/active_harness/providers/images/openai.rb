require "uri"

module ActiveHarness
  module Providers
    module Images
      class OpenAI < Base
        ENDPOINT = "https://api.openai.com/v1/images/generations"

        # @param model   [String]  "dall-e-2", "dall-e-3", "gpt-image-1"
        # @param prompt  [String]  image description
        # @param size    [String]  e.g. "1024x1024"
        # @param quality [String]  "standard"/"hd" (dall-e-3), "low"/"medium"/"high"/"auto" (gpt-image-1)
        def call(model:, prompt:, size: "1024x1024", quality: nil, **_)
          headers = {
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{api_key}"
          }

          raw  = post_json(URI(ENDPOINT), headers: headers, body: build_payload(model, prompt, size, quality), timeout: 60)
          data = parse!(raw)
          handle_error!(data)

          b64 = data.dig("data", 0, "b64_json")
          raise Errors::ProviderError, "No image data in response" unless b64

          { content: b64, provider: :openai, model: model, usage: nil }
        end

        private

        def build_payload(model, prompt, size, quality)
          payload = { model: model, prompt: prompt, n: 1, size: size }
          # gpt-image-* always returns b64_json; older models default to url
          payload[:response_format] = "b64_json" unless model.start_with?("gpt-image")
          payload[:quality] = quality if quality
          payload
        end

        def api_key
          key = config.openai_api_key.to_s
          raise Errors::InvalidApiKeyError, "openai_api_key is not configured" if key.empty?
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
          when "invalid_api_key", "unauthorized"
            raise Errors::InvalidApiKeyError.new(msg,  error_code: code, metadata: metadata)
          when "rate_limit_exceeded"
            raise Errors::RateLimitError.new(msg,      error_code: code, metadata: metadata)
          when "content_filter"
            raise Errors::SafetyBlockedError.new(msg,  error_code: code, metadata: metadata)
          else
            case type
            when "server_error"
              raise Errors::ServerError.new(msg,       error_code: code, metadata: metadata)
            else
              raise Errors::InvalidRequestError.new(msg, error_code: code, metadata: metadata)
            end
          end
        end
      end
    end
  end
end
