require "uri"

module ActiveHarness
  module Providers
    # TypeSafe — direct access to Jev, TypeSafe's "System One" evaluation model
    # (https://api.typesafe.ai/v1/systemone). Same request/response contract as
    # provider: :vercel (which reaches the same model through Vercel AI Gateway),
    # so `questions:` and everything else in Providers::Vercel apply unchanged.
    #
    # Also works with any Jev-compatible server: point `typesafe_api_url` at it.
    #
    #   model do
    #     use provider: :typesafe, model: "jev-latest", questions: {
    #       urgent: { type: "noul", instructions: "Is this urgent?" }
    #     }
    #   end
    class TypeSafe < Vercel
      private

      def provider_name
        :typesafe
      end

      def endpoint_url
        config.typesafe_api_url
      end

      def api_key
        key = config.typesafe_api_key.to_s
        raise Errors::InvalidApiKeyError, "typesafe_api_key is not configured" if key.empty?
        key
      end
    end
  end
end
