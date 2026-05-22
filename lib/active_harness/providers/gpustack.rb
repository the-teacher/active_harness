require "uri"

module ActiveHarness
  module Providers
    # GPUStack — self-hosted GPU inference server, OpenAI-compatible API.
    # https://docs.gpustack.ai/latest/user-guide/inference-openai-compatible-apis/
    #
    # GPUSTACK_API_BASE is required (e.g. "http://my-gpustack-server:80").
    # GPUSTACK_API_KEY is optional (needed only if the server has auth enabled).
    #
    # Example:
    #   model do
    #     use provider: :gpustack, model: "Qwen/Qwen2.5-7B-Instruct-GGUF"
    #   end
    class GPUStack < Base
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
          provider: :gpustack,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def api_base
        base = ENV["GPUSTACK_API_BASE"].to_s
        raise Errors::InvalidRequestError, "GPUSTACK_API_BASE is not set" if base.empty?
        base.chomp("/")
      end

      def api_key
        key = ENV["GPUSTACK_API_KEY"].to_s
        key.empty? ? nil : key
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        type     = data.dig("error", "type").to_s
        metadata = data["error"].reject { |k, _| %w[message code type].include?(k) }
        metadata = nil if metadata.empty?

        case code
        when "invalid_api_key", "unauthorized", "401"
          raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
        when "429"
          raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "500", "502", "503", "504"
          raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        else
          case type
          when "server_error"
            raise Errors::ServerError.new(msg,            error_code: code, metadata: metadata)
          else
            raise Errors::InvalidRequestError.new(msg,    error_code: code, metadata: metadata)
          end
        end
      end
    end
  end
end
