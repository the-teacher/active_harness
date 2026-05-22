require "uri"

module ActiveHarness
  module Providers
    # Azure OpenAI Service — deployment-based API.
    # https://learn.microsoft.com/en-us/azure/ai-services/openai/reference
    #
    # The `model:` parameter is treated as the **deployment name** you created
    # in the Azure portal (not the underlying model name).
    #
    # Required config (or ENV fallback):
    #   config.azure_api_base    — "https://my-resource.openai.azure.com"
    #   config.azure_api_key     — your resource API key
    #                              (alternatively: config.azure_ai_auth_token for OAuth bearer)
    #
    # Optional config:
    #   config.azure_api_version — defaults to "2024-05-01-preview"
    #
    # Resulting endpoint:
    #   POST {azure_api_base}/openai/deployments/{deployment}/chat/completions
    #        ?api-version={azure_api_version}
    #
    # Example agent config:
    #   model do
    #     use provider: :azure, model: "my-gpt4o-deployment", temperature: 0.7
    #   end
    class Azure < Base
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
        URI("#{api_base}/openai/deployments/#{deployment}/chat/completions?api-version=#{config.azure_api_version}")
      end

      def api_base
        base = config.azure_api_base.to_s
        raise Errors::InvalidRequestError, "azure_api_base is not configured" if base.empty?
        base.chomp("/")
      end

      # Azure accepts either a resource API key (header: api-key)
      # or an OAuth2 bearer token (header: Authorization).
      def auth_header
        if (key = config.azure_api_key.to_s) && !key.empty?
          { "api-key" => key }
        elsif (token = config.azure_ai_auth_token.to_s) && !token.empty?
          { "Authorization" => "Bearer #{token}" }
        else
          raise Errors::InvalidApiKeyError,
            "Neither azure_api_key nor azure_ai_auth_token is configured"
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
