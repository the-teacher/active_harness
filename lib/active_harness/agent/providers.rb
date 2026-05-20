module ActiveHarness
  class Agent
    # Errors that allow retrying the next model in the chain
    RETRYABLE_ERRORS = [
      Errors::TimeoutError,
      Errors::RateLimitError,
      Errors::ServerError,
      Errors::ProviderUnavailableError
    ].freeze

    # Errors that abort the entire chain immediately
    STOP_ERRORS = [
      Errors::InvalidRequestError,
      Errors::InvalidApiKeyError,
      Errors::SafetyBlockedError
    ].freeze

    PROVIDERS = {
      openai:     -> { Providers::OpenAI.new },
      openrouter: -> { Providers::OpenRouter.new },
      groq:       -> { Providers::Groq.new },
      gemini:     -> { Providers::Gemini.new },
      anthropic:  -> { Providers::Anthropic.new }
    }.freeze

    private

    def attempt_model(entry, system_prompt)
      provider = resolve_provider(entry[:provider])
      messages = build_messages(system_prompt, @input)
      opts = { model: entry[:model], messages: messages }
      opts[:temperature] = entry[:temperature] if entry[:temperature]
      opts[:stream]      = @stream             if @stream
      provider.call(**opts)
    end

    def resolve_provider(name)
      factory = PROVIDERS[name.to_sym]
      raise ArgumentError, "Unknown provider: #{name.inspect}. Supported: #{PROVIDERS.keys.join(', ')}" unless factory

      factory.call
    end

    def build_messages(system_prompt, input)
      # Memory is NOT auto-injected here.
      # To use history in LLM context, inject it manually via a hook or prompt class.
      # See ActiveHarness::Memory for examples.
      messages = []
      messages << { role: "system", content: system_prompt } if system_prompt
      messages << { role: "user",   content: input }
      messages
    end
  end
end
