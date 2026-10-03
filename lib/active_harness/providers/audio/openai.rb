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
        # @param response_format [String] "json" (default, plain text) or,
        #   for gpt-4o-transcribe-diarize, "diarized_json" — returns per-segment
        #   speaker/text/start/end instead of just plain text.
        # @param chunking_strategy [String, Hash] required by
        #   gpt-4o-transcribe-diarize for any audio over 30 seconds; "auto" is
        #   the simple/common value, or a voice-activity-detection config hash.
        # @param known_speaker_names [Array<String>] up to 4 labels, paired
        #   positionally with known_speaker_references, for gpt-4o-transcribe-diarize.
        # @param known_speaker_references [Array<String>] up to 4 short (2-10s)
        #   reference clips as base64 data URLs, e.g. "data:audio/wav;base64,...".
        def call(model:, audio_data:, audio_format:, language: nil, response_format: nil,
                 chunking_strategy: nil, known_speaker_names: nil, known_speaker_references: nil, **_)
          content_type = CONTENT_TYPES[audio_format]
          unless content_type
            raise Errors::InvalidRequestError,
              "openai transcription does not support .#{audio_format} — use one of: #{CONTENT_TYPES.keys.join(', ')}"
          end

          boundary = SecureRandom.hex(16)
          fields   = { "model" => model }
          fields["language"]          = language if language
          fields["response_format"]   = response_format if response_format
          fields["chunking_strategy"] = chunking_strategy if chunking_strategy

          array_fields = {
            "known_speaker_names[]"      => known_speaker_names,
            "known_speaker_references[]" => known_speaker_references
          }

          body = build_multipart_body(boundary, fields, audio_data, "audio.#{audio_format}", content_type, array_fields: array_fields)
          headers = {
            "Content-Type"  => "multipart/form-data; boundary=#{boundary}",
            "Authorization" => "Bearer #{api_key}"
          }

          raw  = HTTP.post(URI(ENDPOINT), headers: headers, body: body, timeout: 90)
          data = parse!(raw)
          handle_error!(data)

          # diarized_json returns a structured { segments: [...] } shape (each
          # with speaker/text/start/end) — hand the whole thing back as JSON
          # text so `format :json` on the Request subclass parses it into a
          # Hash. Plain "json"/unset keeps the existing behavior: just the
          # flat text.
          content =
            if response_format == "diarized_json"
              data.to_json
            else
              data["text"].tap { |t| raise Errors::ProviderError, "No transcription text in response: #{data.keys}" if t.nil? }
            end

          { content: content, provider: :openai, model: model, usage: extract_transcription_usage(data) }
        end

        private

        def build_multipart_body(boundary, fields, file_data, filename, content_type, array_fields: {})
          body = +""
          fields.each do |name, value|
            body << "--#{boundary}\r\n"
            body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
            body << "#{value}\r\n"
          end

          array_fields.each do |name, values|
            Array(values).each do |value|
              body << "--#{boundary}\r\n"
              body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
              body << "#{value}\r\n"
            end
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
