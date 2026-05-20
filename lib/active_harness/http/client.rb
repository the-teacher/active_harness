require "net/http"

module ActiveHarness
  module Http
    # Thin Net::HTTP wrapper — no external dependencies.
    class Client
      # @param url     [URI]
      # @param headers [Hash{String => String}]
      # @param body    [String]   JSON-serialized body
      # @param timeout [Integer]  seconds (open + read)
      # @return        [String]   raw response body
      def post(url, headers:, body:, timeout: 30)
        http              = Net::HTTP.new(url.host, url.port)
        http.use_ssl      = true
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(url)
        headers.each { |k, v| req[k] = v }
        req.body = body

        http.request(req).body
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise Errors::TimeoutError, "Request to #{url.host} timed out"
      rescue => e
        raise Errors::ProviderUnavailableError, "#{url.host} unreachable: #{e.message}"
      end
    end
  end
end
