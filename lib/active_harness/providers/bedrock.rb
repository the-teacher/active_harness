module ActiveHarness
  module Providers
    # AWS Bedrock — stub provider.
    #
    # Bedrock requires AWS Signature V4 request signing, which is non-trivial
    # to implement and carries AWS SDK dependencies. This stub raises a clear
    # error so that the agent falls through to the next model in its fallback chain.
    #
    # To use Bedrock in production, please look for a dedicated gem, for example:
    #   gem "active_harness-bedrock"  (not yet released — contributions welcome)
    #
    # Example agent config (will fall through to the next fallback):
    #   model do
    #     use      provider: :bedrock, model: "anthropic.claude-3-5-sonnet-20241022-v2:0"
    #     fallback provider: :anthropic, model: "claude-3-5-sonnet-20241022"
    #   end
    class Bedrock < Base
      STUB_MESSAGE = <<~MSG.strip
        ActiveHarness: AWS Bedrock provider is not built-in.
        Bedrock requires AWS Signature V4 signing — please use a dedicated gem.
        Falling through to the next model in the fallback chain.
      MSG

      def call(model:, messages:, temperature: 0.7) # rubocop:disable Lint/UnusedMethodArgument
        raise Errors::ProviderUnavailableError, STUB_MESSAGE
      end
    end
  end
end
