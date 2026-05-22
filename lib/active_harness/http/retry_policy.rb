module ActiveHarness
  module Http
    # Wraps a block with automatic retry on transient errors.
    # Uses exponential backoff: delay doubles after each failed attempt.
    #
    # Example:
    #   RetryPolicy.new(max_attempts: 3, base_delay: 0.5).run do
    #     http_client.post(...)
    #   end
    #
    # Disable retries entirely:
    #   RetryPolicy.new(max_attempts: 1).run { ... }
    #
    class RetryPolicy
      RETRYABLE_ERRORS = [
        Errors::TimeoutError,
        Errors::RateLimitError,
        Errors::ProviderUnavailableError,
        Errors::ServerError
      ].freeze

      # @param max_attempts [Integer]  total number of attempts (1 = no retries)
      # @param base_delay   [Float]    seconds before 1st retry; doubles each round
      # @param errors       [Array]    error classes that trigger a retry
      def initialize(max_attempts: 3, base_delay: 1.0, errors: RETRYABLE_ERRORS)
        @max_attempts = max_attempts
        @base_delay   = base_delay
        @errors       = errors
      end

      # @yieldreturn [Object] result of the block on success
      # @raise last error after all attempts are exhausted
      def run
        attempt = 0
        begin
          attempt += 1
          yield
        rescue *@errors => e
          raise if attempt >= @max_attempts

          sleep(@base_delay * (2**(attempt - 1)))
          retry
        end
      end
    end
  end
end
