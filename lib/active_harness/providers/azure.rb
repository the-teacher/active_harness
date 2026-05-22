require "uri"

module ActiveHarness
  module Providers
    # Azure OpenAI Service — deployment-based API.
    # https://learn.microsoft.com/en-us/azure/ai-services/openai/reference
    #
    # The `model:` parameter is treated as the **deployment name** you created
    # in the Azure portal (not the underlying model name).
    #
    # Required ENV variables:
    #   AZURE_API_BASE   — "https://my-resource.openai.azure.com"
    #   AZURE_API_KEY    — your resource API key
    #                      (alternatively: AZURE_AI_AUTH_TOKEN for OAuth bearer)
    #
    # Optional ENV variables:
    #   AZURE_API_VERSION — defaults to "2024-05-01-preview"
    #
    # Resulting endpoint:
    #   POST {AZURE_API_BASE}/openai/deployments/{deployment}/chat/completions
    #        ?api-version={AZURE_API_VERSION}
    #
    # Example agent config:
    #   model do
    #     use provider: :azure, model: "my-gpt4o-deployment", temperature: 0.7
    #   end
    class Azure < Base
      DEFAULT_API_VERSION = "2024-05-01-preview"

      def call(model:, messages:, temperature: 0.7)
        url = build_url(model)

        raw  = post_json(url,
          headers: {
            "Content-Type" => "application/json"
          }.merge(auth_header),
          body: { messages: messages, temperature: temperature }
        )
        data = parse!(raw)
        handle_error!(data)

        {
          content:  data.dig("choices", 0, "message", "content").to_s.strip,
          provider: :azure,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def build_url(deployment)
        base    = api_base
        version = ENV.fetch("AZURE_API_VERSION", DEFAULT_API_VERSION)
        URI("#{base}/openai/deployments/#{deployment}/chat/completions?api-version=#{version}")
      end

      def api_base
        base = ENV["AZURE_API_BASE"].to_s
        raise Errors::InvalidRequestError, "AZURE_API_BASE is not set" if base.empty?
        base.chomp("/")
      end

      # Azure accepts either a resource API key (header: api-key)
      # or an OAuth2 bearer token (header: Authorization).
      def auth_header
        if (key = ENV["AZURE_API_KEY"].to_s) && !key.empty?
          { "api-key" => key }
        elsif (token = ENV["AZURE_AI_AUTH_TOKEN"].to_s) && !token.empty?
          { "Authorization" => "Bearer #{token}" }
        else
          raise Errors::InvalidApiKeyError,
            "Neither AZURE_API_KEY nor AZURE_AI_AUTH_TOKEN is set"
        end
      end

      def handle_error!(data)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        type     = data.dig("error", "innererror", "code").to_s
        metadata = data["error"].reject { |k, _| %w[message code innererror].include?(k) }
        metadata = nil if metadata.empty?

        case code
        when "401", "invalid_api_key", "unauthorized", "AccessDenied"
          raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: metadata)
        when "429", "TooManyRequests"
          raise Errors::RateLimitError.new(msg,           error_code: code, metadata: metadata)
        when "ContentFilter", "content_filter"
          raise Errors::SafetyBlockedError.new(msg,       error_code: code, metadata: metadata)
        when "500", "502", "503", "504", "ServiceUnavailable"
          raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: metadata)
        else
          raise Errors::InvalidRequestError.new(msg,      error_code: code, metadata: metadata)
        end
      end
    end
  end
end
