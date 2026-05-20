module ActiveHarness
  module Errors
    Error = Class.new(StandardError)

    # Raised when all models in the chain fail
    AllModelsFailed = Class.new(Error)

    # Raised by Tribunal when every agent fails or times out
    AllAgentsFailed = Class.new(Error)

    # Base for all provider-level failures — carries an optional error_code and metadata
    class ProviderError < Error
      attr_reader :error_code, :metadata

      def initialize(message = nil, error_code: nil, metadata: nil)
        super(message)
        @error_code = error_code
        @metadata   = metadata
      end
    end

    TimeoutError             = Class.new(ProviderError)
    RateLimitError           = Class.new(ProviderError)
    ServerError              = Class.new(ProviderError)
    ProviderUnavailableError = Class.new(ProviderError)

    # Non-retryable failures
    InvalidRequestError = Class.new(ProviderError)
    InvalidApiKeyError  = Class.new(ProviderError)
    SafetyBlockedError  = Class.new(ProviderError)
  end
end
