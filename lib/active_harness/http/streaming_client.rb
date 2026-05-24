require "net/http"
require "json"

module ActiveHarness
  module Http
    # Streaming variant of Client.
    # Calls +on_token+ for each content token as it arrives via SSE.
    # Accumulates and returns the full content string when the stream ends.
    class StreamingClient
      # @param url      [URI]
      # @param headers  [Hash{String => String}]
      # @param body     [String]  JSON-serialized body
      # @param timeout  [Integer] seconds (open + read)
      # @param on_token [Proc]    called with each partial token string
      # @return         [String]  full accumulated content
      def post(url, headers:, body:, timeout: 60, on_token:)
        http              = Net::HTTP.new(url.host, url.port)
        http.use_ssl      = true
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(url)
        headers.each { |k, v| req[k] = v }
        req.body = body

        buffer  = ""
        content = ""
        usage   = nil

        http.request(req) do |response|
          response.read_body do |chunk|
            buffer += chunk
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next unless line.start_with?("data: ")

              data = line.delete_prefix("data: ")
              next if data == "[DONE]"

              parsed = JSON.parse(data)
              token  = parsed.dig("choices", 0, "delta", "content")
              if token && !token.empty?
                on_token.call(token)
                content += token
              end
              usage ||= parsed["usage"] if parsed.key?("usage")
            end
          end
        end

        { content: content, raw_usage: usage }
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Errors::TimeoutError, "Request to #{url.host} timed out"
      rescue JSON::ParserError
        # ignore malformed SSE chunks
        content
      rescue => e
        raise Errors::ProviderUnavailableError, "#{url.host} unreachable: #{e.message}"
      end
    end
  end
end
