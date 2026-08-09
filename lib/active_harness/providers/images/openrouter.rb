require "uri"

module ActiveHarness
  module Providers
    module Images
      class OpenRouter < Base
        # @param model  [String]  e.g. "openai/gpt-5-image-mini", "google/gemini-2.5-flash-image"
        # @param prompt [String]  image description
        # Image-only models use OpenRouter's dedicated Images API. Models that
        # also output text retain the legacy chat-completions request path.
        # @param size   [String]  ignored by OpenRouter (passed through for future support)
        def call(model:, prompt:, size: nil, quality: nil, **_)
          headers = {
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{api_key}"
          }
          referer = config.openrouter_http_referer.to_s
          headers["HTTP-Referer"] = referer unless referer.empty?

          return call_images_api(model, prompt, size, quality, headers) if image_only_model?(model)

          call_chat_api_with_fallback(model, prompt, size, quality, headers)
        end

        private

        def call_chat_api_with_fallback(model, prompt, size, quality, headers)
          call_chat_api(model, prompt, size, quality, headers)
        rescue Errors::InvalidRequestError => error
          raise unless unsupported_output_modalities?(error)

          call_images_api(model, prompt, size, quality, headers)
        end

        def call_chat_api(model, prompt, size, quality, headers)
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

        def call_images_api(model, prompt, size, quality, headers)
          body = { model: model, prompt: prompt }
          body[:size] = size if size
          body[:quality] = quality if quality
          body[:output_format] = "png"

          raw = post_json(URI(config.openrouter_images_api_url), headers: headers, body: body, timeout: 120)
          data = parse!(raw)
          handle_error!(data)

          content = extract_images_api_image(data)
          raise Errors::ProviderError, "No image data in response: #{data.keys}" unless content

          { content: content, provider: :openrouter, model: model, usage: extract_usage_openai(data) }
        end

        def extract_images_api_image(data)
          data.dig("data", 0, "b64_json")
        end

        def extract_image(data)
          images = data.dig("choices", 0, "message", "images")
          return unless images.is_a?(Array) && images.any?

          images.first&.dig("image_url", "url")
        end

        def image_only_model?(model)
          info = Pricing::OpenRouter.find(model)
          modalities = Array(info&.output_modalities).map(&:to_s)
          modalities.include?("image") && !modalities.include?("text")
        rescue StandardError
          false
        end

        def unsupported_output_modalities?(error)
          error.message.include?("requested output modalities")
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
