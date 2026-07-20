require "uri"
require "securerandom"

module ActiveHarness
  module Providers
    module Audio
      class OpenAI < Base
        ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"

        # OpenAI's transcription endpoint only accepts these formats — notably
        # no flac/ogg/aac, unlike OpenRouter's version of this endpoint.
        CONTENT_TYPES = {
          "mp3"  => "audio/mpeg",
          "mp4"  => "audio/mp4",
          "mpeg" => "audio/mpeg",
          "mpga" => "audio/mpeg",
          "m4a"  => "audio/mp4",
          "wav"  => "audio/wav",
          "webm" => "audio/webm"
        }.freeze

        # @param model        [String]  e.g. "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"
        # @param audio_data   [String]  raw binary audio bytes
        # @param audio_format [String]  one of CONTENT_TYPES.keys
        # @param language     [String]  ISO-639-1 code, e.g. "en" (optional — auto-detected if omitted)
        #
        # Synchronous — this endpoint has no job/polling API. Unlike OpenRouter's
        # transcription endpoint, OpenAI's is multipart/form-data only (no
        # base64/JSON request mode).
        def call(model:, audio_data:, audio_format:, language: nil, **_)
          content_type = CONTENT_TYPES[audio_format]
          unless content_type
            raise Errors::InvalidRequestError,
              "openai transcription does not support .#{audio_format} — use one of: #{CONTENT_TYPES.keys.join(', ')}"
          end

          boundary = SecureRandom.hex(16)
          fields   = { "model" => model }
          fields["language"] = language if language

          body = build_multipart_body(boundary, fields, audio_data, "audio.#{audio_format}", content_type)
          headers = {
            "Content-Type"  => "multipart/form-data; boundary=#{boundary}",
            "Authorization" => "Bearer #{api_key}"
          }

          raw  = HTTP.post(URI(ENDPOINT), headers: headers, body: body, timeout: 90)
          data = parse!(raw)
          handle_error!(data)

          text = data["text"]
          raise Errors::ProviderError, "No transcription text in response: #{data.keys}" if text.nil?

          { content: text, provider: :openai, model: model, usage: extract_transcription_usage(data) }
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

        # whisper-1 reports usage as { type: "duration", seconds: N } — no token
        # counts, so there's nothing to map to input_tokens/output_tokens. Newer
        # models (gpt-4o-transcribe, gpt-4o-mini-transcribe) report
        # { type: "tokens", input_tokens:, output_tokens:, total_tokens:, ... }.
        # Neither reports a direct dollar cost like OpenRouter does — cost is left
        # to the normal per-token Pricing lookup, which returns nil for
        # duration-billed models since it has no token counts to work with.
        def extract_transcription_usage(data)
          u = data["usage"]
          return nil unless u && u["type"] == "tokens"

          {
            input_tokens:  u["input_tokens"].to_i,
            output_tokens: u["output_tokens"].to_i,
            total_tokens:  u["total_tokens"].to_i
          }
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
