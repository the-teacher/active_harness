require "uri"

module ActiveHarness
  module Providers
    module Audio
      class Deepgram < Base
        CONTENT_TYPES = {
          "mp3"  => "audio/mpeg",
          "mp4"  => "audio/mp4",
          "m4a"  => "audio/mp4",
          "wav"  => "audio/wav",
          "flac" => "audio/flac",
          "ogg"  => "audio/ogg",
          "opus" => "audio/ogg",
          "webm" => "audio/webm",
          "aac"  => "audio/aac"
        }.freeze

        # @param model        [String]  e.g. "nova-3", "nova-2"
        # @param audio_data   [String]  raw binary audio bytes
        # @param audio_format [String]  one of CONTENT_TYPES.keys
        # @param language     [String]  BCP-47 code, e.g. "en" (optional)
        #
        # Synchronous pre-recorded transcription: the audio bytes are the raw
        # request body (no multipart, no base64), options go in the query string.
        # Deepgram bills by audio duration and reports no token usage, so
        # `usage` is always nil.
        def call(model:, audio_data:, audio_format:, language: nil, **_)
          content_type = CONTENT_TYPES[audio_format]
          unless content_type
            raise Errors::InvalidRequestError,
              "deepgram transcription does not support .#{audio_format} — use one of: #{CONTENT_TYPES.keys.join(', ')}"
          end

          query = { "model" => model, "smart_format" => "true" }
          query["language"] = language if language

          url = URI(config.deepgram_api_url)
          url.query = URI.encode_www_form(query)

          headers = { "Content-Type" => content_type, "Authorization" => "Token #{api_key}" }

          raw  = HTTP.post(url, headers: headers, body: audio_data, timeout: 90)
          data = parse!(raw)
          handle_error!(data)

          text = data.dig("results", "channels", 0, "alternatives", 0, "transcript")
          raise Errors::ProviderError, "No transcription text in response: #{data.keys}" if text.nil?

          { content: text, provider: :deepgram, model: model, usage: nil }
        end

        private

        def api_key
          key = config.deepgram_api_key.to_s
          raise Errors::InvalidApiKeyError, "deepgram_api_key is not configured" if key.empty?
          key
        end

        # Deepgram errors look like { "err_code": "INVALID_AUTH", "err_msg": "..." }.
        def handle_error!(data)
          return unless data["err_code"] || data["err_msg"]

          msg  = data["err_msg"].to_s
          code = data["err_code"].to_s
          meta = data["request_id"] ? { request_id: data["request_id"] } : nil

          case code
          when "INVALID_AUTH", "INSUFFICIENT_PERMISSIONS"
            raise Errors::InvalidApiKeyError.new(msg, error_code: code, metadata: meta)
          when "TOO_MANY_REQUESTS", "RATE_LIMIT"
            raise Errors::RateLimitError.new(msg,     error_code: code, metadata: meta)
          else
            raise Errors::InvalidRequestError.new(msg, error_code: code, metadata: meta)
          end
        end
      end
    end
  end
end
