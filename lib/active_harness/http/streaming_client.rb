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
        http.use_ssl      = true
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(url)
        headers.each { |k, v| req[k] = v }
        req.body = body

        buffer  = ""
        content = ""
        usage   = {}

        http.request(req) do |response|
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
      rescue => e
        raise Errors::ProviderUnavailableError, "#{url.host} unreachable: #{e.message}"
      end

      private

      def default_chunk(parsed)
        token = parsed.dig("choices", 0, "delta", "content")
        raw_u = parsed["usage"]
        usage = raw_u ? { input_tokens: raw_u["prompt_tokens"].to_i, output_tokens: raw_u["completion_tokens"].to_i } : nil
        { token: token, usage: usage }
      end
    end
  end
end
