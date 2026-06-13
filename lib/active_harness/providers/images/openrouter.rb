require "uri"

module ActiveHarness
  module Providers
    module Images
      class OpenRouter < Base
        # @param model  [String]  e.g. "openai/gpt-5-image-mini", "google/gemini-2.5-flash-image"
        # @param prompt [String]  image description
        # @param size   [String]  ignored by OpenRouter (passed through for future support)
        def call(model:, prompt:, size: nil, quality: nil, **_)
          headers = {
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{api_key}"
          }
          referer = config.openrouter_http_referer.to_s
          headers["HTTP-Referer"] = referer unless referer.empty?

          messages = [{ role: "user", content: prompt }]
          body = { model: model, messages: messages, modalities: ["image", "text"] }
          body[:size]    = size    if size
          body[:quality] = quality if quality

          raw  = post_json(URI(config.openrouter_api_url), headers: headers, body: body, timeout: 120)
          data = parse!(raw)
          handle_error!(data)

          content = extract_image(data)
          raise Errors::ProviderError, "No image data in response: #{data.dig('choices', 0, 'message')&.keys}" unless content

          { content: content, provider: :openrouter, model: model, usage: extract_usage_openai(data) }
        end

        private

        def extract_image(data)
          images = data.dig("choices", 0, "message", "images")
          return unless images.is_a?(Array) && images.any?

          images.first&.dig("image_url", "url")
        end

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
          when "401"             then raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
          when "402", "429"      then raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
          when "500", "502",
               "503", "504"      then raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
          else                        raise Errors::InvalidRequestError.new(msg,      error_code: code, metadata: metadata)
          end
        end
      end
    end
  end
end
