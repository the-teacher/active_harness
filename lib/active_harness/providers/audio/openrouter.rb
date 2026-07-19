require "uri"
require "base64"

module ActiveHarness
  module Providers
    module Audio
      class OpenRouter < Base
        # Dedicated transcription endpoint — distinct from the chat completions
        # endpoint used by text/image generation on OpenRouter.
        ENDPOINT = "https://openrouter.ai/api/v1/audio/transcriptions"

        # @param model        [String]  e.g. "openai/whisper-1", "deepgram/nova-3"
        # @param audio_data   [String]  raw binary audio bytes
        # @param audio_format [String]  "wav", "mp3", "flac", "m4a", "ogg", "webm", "aac"
        # @param language     [String]  ISO-639-1 code, e.g. "en" (optional — auto-detected if omitted)
        #
        # Synchronous call — OpenRouter's transcription endpoint has no job/polling
        # API. Upstream providers time out after ~60s per request, so long audio
        # should be split into shorter chunks by the caller before transcribing.
        def call(model:, audio_data:, audio_format:, language: nil, **_)
          headers = {
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{api_key}"
          }
          referer = config.openrouter_http_referer.to_s
          headers["HTTP-Referer"] = referer unless referer.empty?

          body = {
            model: model,
            input_audio: { data: Base64.strict_encode64(audio_data), format: audio_format }
          }
          body[:language] = language if language

          raw  = post_json(URI(ENDPOINT), headers: headers, body: body, timeout: 90)
          data = parse!(raw)
          handle_error!(data)

          text = data["text"]
          raise Errors::ProviderError, "No transcription text in response: #{data.keys}" if text.nil?

          { content: text, provider: :openrouter, model: model, usage: extract_transcription_usage(data) }
        end

        private

        # OpenRouter's transcription usage shape differs from its chat/image usage
        # shape (input_tokens/output_tokens directly, not prompt_tokens/completion_tokens).
        def extract_transcription_usage(data)
          u = data["usage"]
          return nil unless u

          result = {
            input_tokens:  u["input_tokens"].to_i,
            output_tokens: u["output_tokens"].to_i,
            total_tokens:  u["total_tokens"].to_i
          }
          result[:provider_cost] = u["cost"].to_f if u.key?("cost")
          result
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
