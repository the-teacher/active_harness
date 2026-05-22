require "uri"

module ActiveHarness
  module Providers
    # Ollama — local model inference server, OpenAI-compatible API.
    # https://ollama.com/blog/openai-compatibility
    #
    # Set OLLAMA_API_BASE to override the default local address.
    # OLLAMA_API_KEY is optional (needed only if Ollama is behind a proxy with auth).
    #
    # Example:
    #   model do
    #     use provider: :ollama, model: "llama3.2"
    #   end
    class Ollama < Base
      DEFAULT_API_BASE = "http://localhost:11434"

      def call(model:, messages:, temperature: 0.7)
        url = URI("#{api_base}/v1/chat/completions")

        headers = { "Content-Type" => "application/json" }
        key     = api_key
        headers["Authorization"] = "Bearer #{key}" if key

        raw  = post_json(url,
          headers: headers,
          body:    { model: model, messages: messages, temperature: temperature }
        )
        data = parse!(raw)
        handle_error!(data)

        {
          content:  data.dig("choices", 0, "message", "content").to_s.strip,
          provider: :ollama,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def api_base
        ENV["OLLAMA_API_BASE"].to_s.then { |v| v.empty? ? DEFAULT_API_BASE : v.chomp("/") }
      end

      # Ollama does not require an API key by default.
      def api_key
        key = ENV["OLLAMA_API_KEY"].to_s
        key.empty? ? nil : key
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        metadata = data["error"].reject { |k, _| %w[message code].include?(k) }
        metadata = nil if metadata.empty?

        case code
        when "500", "502", "503", "504"
          raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        else
          raise Errors::InvalidRequestError.new(msg, error_code: code, metadata: metadata)
        end
      end
    end
  end
end
