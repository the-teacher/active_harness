module ActiveHarness
  class Agent
    # -------------------------------------------------------------------------
    # Custom LLM backend DSL
    #
    # Allows an agent to delegate HTTP calls to any LLM client (e.g. `ruby_llm`)
    # instead of ActiveHarness's built-in Net::HTTP providers.
    #
    # Usage:
    #
    #   custom_llm_backend do |params|
    #     RubyLLM.chat(
    #       model:               params.model,
    #       provider:            params.provider,
    #       assume_model_exists: true
    #     ).tap { |c| c.with_temperature(params.temperature) if params.temperature }
    #   end
    #
    # The block receives a BackendParams struct and must return a RubyLLM::Chat.
    # ActiveHarness calls chat.ask(@input) and maps the result to its Result format.
    #
    # All existing features work unchanged:
    #   - model do / use / fallback  (order of attempts)
    #   - retry_attempts / retry_delay  (per-model retry policy)
    #   - fallback chain on error
    #   - hooks (:setup, :before_call, :retry, :failure, …)
    #   - streaming via stream: lambda
    # -------------------------------------------------------------------------

    # Passed to the custom_llm_backend block for each model attempt.
    BackendParams = Struct.new(:model, :provider, :temperature, keyword_init: true)

    class << self
      # Define the custom LLM backend block for this agent class.
      def custom_llm_backend(&block)
        agent_config[:custom_llm_backend] = block
      end
    end

    private

    # Called from attempt_model when custom_llm_backend is configured.
    def attempt_via_custom_llm(entry, system_prompt)
      require "ruby_llm"

      backend = @config[:custom_llm_backend]

      params = BackendParams.new(
        model:       entry[:model],
        provider:    entry[:provider].to_s,
        temperature: entry[:temperature]
      )

      chat = backend.call(params)
      chat.with_instructions(system_prompt) if system_prompt

      if @token
        response = chat.ask(@input) { |chunk| @token.call(chunk.content) if chunk.content }
      else
        response = chat.ask(@input)
      end

      { content: response.content, usage: custom_llm_usage(response) }
    rescue ::RubyLLM::UnauthorizedError => e
      raise Errors::InvalidApiKeyError, e.message
    rescue ::RubyLLM::RateLimitError, ::RubyLLM::OverloadedError => e
      raise Errors::RateLimitError, e.message
    rescue ::RubyLLM::ServerError, ::RubyLLM::ServiceUnavailableError => e
      raise Errors::ServerError, e.message
    rescue ::RubyLLM::BadRequestError, ::RubyLLM::ContextLengthExceededError => e
      raise Errors::InvalidRequestError, e.message
    rescue ::RubyLLM::Error => e
      raise Errors::ProviderError, e.message
    rescue LoadError
      raise Errors::ProviderUnavailableError,
            "The `ruby_llm` gem is required. Add `gem \"ruby_llm\"` to your Gemfile."
    end

    def custom_llm_usage(response)
      t = response.tokens
      return nil unless t

      {
        input_tokens:  t.input,
        output_tokens: t.output,
        total_tokens:  (t.input.to_i + t.output.to_i)
      }.compact
    end
  end
end
