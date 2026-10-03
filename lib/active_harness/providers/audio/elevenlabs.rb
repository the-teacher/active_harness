require "uri"
require "securerandom"

module ActiveHarness
  module Providers
    module Audio
      class ElevenLabs < Base
        CONTENT_TYPES = {
          "mp3"  => "audio/mpeg",
          "mp4"  => "audio/mp4",
          "m4a"  => "audio/mp4",
          "wav"  => "audio/wav",
          "flac" => "audio/flac",
          "ogg"  => "audio/ogg",
          "webm" => "audio/webm",
          "aac"  => "audio/aac"
        }.freeze

        # @param model        [String]  e.g. "scribe_v1", "scribe_v2"
        # @param audio_data   [String]  raw binary audio bytes
        # @param audio_format [String]  one of CONTENT_TYPES.keys
        # @param language     [String]  ISO-639-1/3 code (optional — auto-detected if omitted)
        #
        # Synchronous multipart/form-data request. ElevenLabs reports no token
        # usage for speech-to-text, so `usage` is always nil.
        def call(model:, audio_data:, audio_format:, language: nil, **_)
          content_type = CONTENT_TYPES[audio_format]
          unless content_type
            raise Errors::InvalidRequestError,
              "elevenlabs transcription does not support .#{audio_format} — use one of: #{CONTENT_TYPES.keys.join(', ')}"
          end

          boundary = SecureRandom.hex(16)
          fields   = { "model_id" => model }
          fields["language_code"] = language if language

          headers = {
            "Content-Type" => "multipart/form-data; boundary=#{boundary}",
            "xi-api-key"   => api_key
          }
          body = build_multipart_body(boundary, fields, audio_data, "audio.#{audio_format}", content_type)

          raw  = HTTP.post(URI(config.elevenlabs_api_url), headers: headers, body: body, timeout: 90)
          data = parse!(raw)
          handle_error!(data)

          text = data["text"]
          raise Errors::ProviderError, "No transcription text in response: #{data.keys}" if text.nil?

          { content: text, provider: :elevenlabs, model: model, usage: nil }
        end

        private

        def build_multipart_body(boundary, fields, file_data, filename, content_type)
          body = +""
          fields.each do |name, value|
            body << "--#{boundary}\r\n"
            body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
            body << "#{value}\r\n"
          end

          body << "--#{boundary}\r\n"
          body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
          body << "Content-Type: #{content_type}\r\n\r\n"
          body << file_data
          body << "\r\n--#{boundary}--\r\n"
          body
        end

        def api_key
          key = config.elevenlabs_api_key.to_s
          raise Errors::InvalidApiKeyError, "elevenlabs_api_key is not configured" if key.empty?
          key
        end

        # Errors are { "detail": { "status": "...", "message": "..." } }, or for
        # request-validation failures { "detail": [ { "msg": "...", ... } ] }.
        def handle_error!(data)
          detail = data["detail"]
          return unless detail

          if detail.is_a?(Hash)
            msg  = detail["message"].to_s
            code = detail["status"].to_s
          else
            msg  = Array(detail).map { |d| d.is_a?(Hash) ? d["msg"] : d }.join("; ")
            code = "validation_error"
          end

          case code
          when "invalid_api_key", "unauthorized", "needs_authorization"
            raise Errors::InvalidApiKeyError.new(msg, error_code: code)
          when "too_many_concurrent_requests", "rate_limit_exceeded", "system_busy"
            raise Errors::RateLimitError.new(msg,     error_code: code)
          else
            raise Errors::InvalidRequestError.new(msg, error_code: code)
          end
        end
      end
    end
  end
end
