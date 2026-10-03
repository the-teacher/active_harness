require "net/http"

module ActiveHarness
  module Http
    # Thin Net::HTTP wrapper — no external dependencies.
    class Client
      METHODS = {
        get:    Net::HTTP::Get,
        post:   Net::HTTP::Post,
        put:    Net::HTTP::Put,
        patch:  Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }.freeze

      # @param method  [Symbol]   :get, :post, :put, :patch or :delete
      # @param url     [URI]      https (default) or http — TLS follows the URL scheme
      # @param headers [Hash{String => String}]
      # @param body    [String, nil] request body (usually JSON-serialized); omit for GET/DELETE
      # @param timeout [Integer]  seconds (open + read)
      # @return        [String]   raw response body; also responds to #http_status
      #                           (Integer) so providers can classify errors by
      #                           status without changing the return type
      def request(method, url, headers: {}, body: nil, timeout: 30)
        klass = METHODS[method.to_sym] or raise ArgumentError, "Unsupported HTTP method: #{method.inspect}"

        begin
          res = build_http(url, timeout).request(build_request(klass, url, headers, body))
        rescue Net::OpenTimeout, Net::ReadTimeout
          raise Errors::TimeoutError, "Request to #{url.host} timed out"
        rescue => e
          raise Errors::ProviderUnavailableError, "#{url.host} unreachable: #{e.message}"
        end

        with_http_status(res)
      end

      def post(url, headers:, body:, timeout: 30)
        request(:post, url, headers: headers, body: body, timeout: timeout)
      end

      def get(url, headers: {}, timeout: 30)
        request(:get, url, headers: headers, timeout: timeout)
      end

      def put(url, headers:, body:, timeout: 30)
        request(:put, url, headers: headers, body: body, timeout: timeout)
      end

      def patch(url, headers:, body:, timeout: 30)
        request(:patch, url, headers: headers, body: body, timeout: timeout)
      end

      def delete(url, headers: {}, timeout: 30)
        request(:delete, url, headers: headers, timeout: timeout)
      end

      private

      def build_http(url, timeout)
        http              = Net::HTTP.new(url.host, url.port)
        http.use_ssl      = url.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http
      end

      def build_request(klass, url, headers, body)
        req = klass.new(url)
        headers.each { |k, v| req[k] = v }
        req.body = body if body
        req
      end

      # Returns the response body with an #http_status accessor attached.
      def with_http_status(res)
        body = res.body
        return body if body.nil?

        body   = body.dup
        status = res.code.to_i
        body.define_singleton_method(:http_status) { status }
        body
      end
    end
  end
end
