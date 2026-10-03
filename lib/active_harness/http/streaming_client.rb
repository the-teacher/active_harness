require "net/http"
require "json"

module ActiveHarness
  module Http
    # Streaming variant of Client.
    # Calls +on_token+ for each content token as it arrives via SSE.
    # Accumulates and returns the full content string when the stream ends.
    class StreamingClient
      # @param url         [URI]
      # @param headers     [Hash{String => String}]
      # @param body        [String]  JSON-serialized body
      # @param timeout     [Integer] seconds (open + read)
      # @param on_token    [Proc]    called with each partial token string
      # @param parse_chunk [Proc, nil] receives each parsed SSE JSON hash;
      #                    must return { token: String|nil, usage: Hash|nil }.
      #                    Defaults to OpenAI-compatible format.
      # @return [Hash]  { content: String, usage: Hash|nil }
      def post(url, headers:, body:, timeout: 60, on_token:, parse_chunk: nil)
        http              = Net::HTTP.new(url.host, url.port)
        http.use_ssl      = url.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(url)
        headers.each { |k, v| req[k] = v }
        req.body = body

        buffer  = ""
        content = ""
        usage   = {}

        http.request(req) do |response|
          # Non-2xx: the body is a plain JSON error, not SSE — read it whole and
          # raise instead of silently returning an empty stream.
          raise_for_status!(response.code.to_i, response.read_body) unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            buffer += chunk
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next unless line.start_with?("data: ")

              data = line.delete_prefix("data: ")
              next if data == "[DONE]"

              parsed = JSON.parse(data) rescue next
              info   = parse_chunk ? parse_chunk.call(parsed) : default_chunk(parsed)
              token  = info[:token]
              if token && !token.empty?
                on_token.call(token)
                content += token
              end
              usage = usage.merge(info[:usage]) if info[:usage]
            end
          end
        end

        { content: content, usage: usage.empty? ? nil : usage }
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Errors::TimeoutError, "Request to #{url.host} timed out"
      rescue Errors::ProviderError
        raise
      rescue => e
        raise Errors::ProviderUnavailableError, "#{url.host} unreachable: #{e.message}"
      end

      private

      # Maps an HTTP error status + body to the same error classes the
      # non-streaming providers raise. The message is pulled from the common
      # error shapes ({error:{message}}, {message}, {detail}), else the raw body.
      def raise_for_status!(status, body)
        msg  = error_message(body)
        code = status.to_s

        case status
        when 401, 403 then raise Errors::InvalidApiKeyError.new(msg,       error_code: code)
        when 429      then raise Errors::RateLimitError.new(msg,           error_code: code)
        when 503      then raise Errors::ProviderUnavailableError.new(msg, error_code: code)
        when 500..599 then raise Errors::ServerError.new(msg,              error_code: code)
        else               raise Errors::InvalidRequestError.new(msg,      error_code: code)
        end
      end

      def error_message(body)
        data = JSON.parse(body.to_s)
        msg  = data.dig("error", "message") if data["error"].is_a?(Hash)
        msg ||= data["error"] if data["error"].is_a?(String)
        msg ||= data["message"] || data["detail"]
        (msg.is_a?(String) ? msg : data.to_json)
      rescue JSON::ParserError, NoMethodError, TypeError
        body.to_s.strip.empty? ? "HTTP error with empty body" : body.to_s.strip[0, 500]
      end

      def default_chunk(parsed)
        token = parsed.dig("choices", 0, "delta", "content")
        raw_u = parsed["usage"]
        usage = raw_u ? { input_tokens: raw_u["prompt_tokens"].to_i, output_tokens: raw_u["completion_tokens"].to_i } : nil
        { token: token, usage: usage }
      end
    end
  end
end
