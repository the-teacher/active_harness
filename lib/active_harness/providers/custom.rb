require "uri"

module ActiveHarness
  module Providers
    # Custom — generic OpenAI-compatible provider for any named endpoint.
    #
    # Configured via ActiveHarness.configure:
    #
    #   ActiveHarness.configure do |config|
    #     config.custom["MyLocal"]["url"]     = "http://localhost:8080/v1/chat/completions"
    #     config.custom["MyLocal"]["api_key"] = ENV["MYLOCAL_API_KEY"]   # omit if no auth needed
    #
    #     config.custom["SecondProvider"]["url"]     = "https://second.example.com/v1/chat/completions"
    #     config.custom["SecondProvider"]["api_key"] = ENV["SECOND_API_KEY"]
    #   end
    #
    # Use in an agent:
    #
    #   model do
    #     use      provider: :custom, name: "MyLocal",        model: "llama3.2"
    #     fallback provider: :custom, name: "SecondProvider", model: "mixtral"
    #   end
    #
    class Custom < Base
      def call(model:, messages:, temperature: 0.7, name: nil)
        raise Errors::InvalidRequestError,
          "provider: :custom requires a `name:` key — e.g. `use provider: :custom, name: \"MyLocal\", model: \"...\"`" \
          if name.nil? || name.to_s.empty?

        settings = config.custom[name.to_s]

        url = settings["url"].to_s
        raise Errors::InvalidRequestError,
          "Custom provider \"#{name}\" has no url configured. " \
          "Set it with: config.custom[\"#{name}\"][\"url\"] = \"https://...\"" \
          if url.empty?

        headers = { "Content-Type" => "application/json" }
        key = settings["api_key"].to_s
        headers["Authorization"] = "Bearer #{key}" unless key.empty?

        raw  = post_json(URI(url),
          headers: headers,
          body:    { model: model, messages: messages, temperature: temperature }
        )
        data = parse!(raw)
        handle_error!(data, name: name)

        {
          content:  data.dig("choices", 0, "message", "content").to_s.strip,
          provider: :custom,
          model:    data["model"] || model,
          usage:    extract_usage_openai(data)
        }
      end

      private

      def handle_error!(data, name:)
        return unless data["error"]

        msg      = data.dig("error", "message").to_s
        code     = data.dig("error", "code").to_s
        type     = data.dig("error", "type").to_s
        metadata = data["error"].reject { |k, _| %w[message code type].include?(k) }
        metadata = nil if metadata.empty?

        case code
        when "invalid_api_key", "unauthorized", "401"
          raise Errors::InvalidApiKeyError.new(
            "[Custom:#{name}] #{msg}", error_code: code, metadata: metadata
          )
        when "429", "rate_limit_exceeded"
          raise Errors::RateLimitError.new(
            "[Custom:#{name}] #{msg}", error_code: code, metadata: metadata
          )
        when "500", "502", "503", "504"
          raise Errors::ProviderUnavailableError.new(
            "[Custom:#{name}] #{msg}", error_code: code, metadata: metadata
          )
        else
          case type
          when "server_error"
            raise Errors::ServerError.new(
              "[Custom:#{name}] #{msg}", error_code: code, metadata: metadata
            )
          else
            raise Errors::InvalidRequestError.new(
              "[Custom:#{name}] #{msg}", error_code: code, metadata: metadata
            )
          end
        end
      end
    end
  end
end
