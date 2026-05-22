module ActiveHarness
  module Providers
    # Google Vertex AI — stub provider.
    #
    # Vertex AI requires Google Cloud OAuth2 authentication via Service Account
    # credentials (googleauth gem) or Application Default Credentials.
    # This stub raises a clear error so that the agent falls through to the
    # next model in its fallback chain.
    #
    # To use Vertex AI in production, please look for a dedicated gem, for example:
    #   gem "active_harness-vertexai"  (not yet released — contributions welcome)
    #
    # For most use cases, consider using the built-in :gemini provider instead:
    # it accesses Google's Gemini models via a simple API key (no OAuth needed).
    #
    # Example agent config (will fall through to the next fallback):
    #   model do
    #     use      provider: :vertexai, model: "gemini-2.0-flash"
    #     fallback provider: :gemini,   model: "gemini-2.0-flash"
    #   end
    class VertexAI < Base
      STUB_MESSAGE = <<~MSG.strip
        ActiveHarness: Google Vertex AI provider is not built-in.
        Vertex AI requires Google Cloud OAuth2 credentials (googleauth gem) — please use a dedicated gem.
        Consider using the built-in :gemini provider instead (simple API key, same models).
        Falling through to the next model in the fallback chain.
      MSG

      def call(model:, messages:, temperature: 0.7) # rubocop:disable Lint/UnusedMethodArgument
        raise Errors::ProviderUnavailableError, STUB_MESSAGE
      end
    end
  end
end
