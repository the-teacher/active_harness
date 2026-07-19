module ActiveHarness
  class Agent
    # Errors that allow retrying the next model in the chain.
    # InvalidRequestError is included here so that a bad model name (or any
    # per-model request failure) does not abort the entire chain — the next
    # fallback model will be attempted instead.
    RETRYABLE_ERRORS = [
      Errors::TimeoutError,
      Errors::RateLimitError,
      Errors::ServerError,
      Errors::ProviderUnavailableError,
      Errors::InvalidRequestError
    ].freeze

    # Errors that abort the entire chain immediately.
    # InvalidApiKeyError  — the key is wrong for every model, retrying is pointless.
    # SafetyBlockedError  — the input itself is blocked; a different model won't help.
    STOP_ERRORS = [
      Errors::InvalidApiKeyError,
      Errors::SafetyBlockedError
    ].freeze

    PROVIDERS = {
      openai:      -> { Providers::OpenAI.new },
      openrouter:  -> { Providers::OpenRouter.new },
      groq:        -> { Providers::Groq.new },
      gemini:      -> { Providers::Gemini.new },
      anthropic:   -> { Providers::Anthropic.new },
      xai:         -> { Providers::XAI.new },
      deepseek:    -> { Providers::DeepSeek.new },
      mistral:     -> { Providers::Mistral.new },
      ollama:      -> { Providers::Ollama.new },
      perplexity:  -> { Providers::Perplexity.new },
      gpustack:    -> { Providers::GPUStack.new },
      azure:       -> { Providers::Azure.new },
      bedrock:     -> { Providers::Bedrock.new },
      vertexai:    -> { Providers::VertexAI.new },
      custom:      -> { Providers::Custom.new }
    }.freeze

    IMAGE_PROVIDERS = {
      openai:      -> { Providers::Images::OpenAI.new },
      openrouter:  -> { Providers::Images::OpenRouter.new }
    }.freeze

    TRANSCRIPTION_PROVIDERS = {
      openrouter:  -> { Providers::Audio::OpenRouter.new }
    }.freeze

    private

    def attempt_model(entry, system_prompt)
      return attempt_via_custom_llm(entry, system_prompt) if @config[:custom_llm_backend]
      return attempt_image_model(entry, system_prompt)     if @config[:image]
      return attempt_transcription_model(entry)            if @config[:transcribe]

      provider = resolve_provider(entry[:provider])
      messages = build_messages(system_prompt, @input)
      opts = { model: entry[:model], messages: messages }
      opts[:temperature] = entry[:temperature] if entry[:temperature]
      opts[:stream]      = @token               if @token
      opts[:name]        = entry[:name]        if entry[:name]
      provider.call(**opts)
    end

    def attempt_image_model(entry, system_prompt)
      factory = IMAGE_PROVIDERS[entry[:provider].to_sym]
      raise ArgumentError, "Provider #{entry[:provider].inspect} does not support image generation. " \
                           "Supported image providers: #{IMAGE_PROVIDERS.keys.join(', ')}" unless factory

      size = entry[:size] || @config[:image_size] || "1024x1024"
      opts = { model: entry[:model], prompt: build_image_prompt(system_prompt, @input.to_s), size: size }
      opts[:quality] = entry[:quality] if entry[:quality]
      factory.call.call(**opts)
    end

    # Image APIs take a single prompt string (no system/user role split), so the
    # system prompt — e.g. base style/formatting guidance — is prepended to the
    # user's input rather than sent as a separate message.
    def build_image_prompt(system_prompt, input)
      return input if system_prompt.nil? || system_prompt.to_s.strip.empty?

      "#{system_prompt}\n\n#{input}"
    end

    def attempt_transcription_model(entry)
      factory = TRANSCRIPTION_PROVIDERS[entry[:provider].to_sym]
      raise ArgumentError, "Provider #{entry[:provider].inspect} does not support audio transcription. " \
                           "Supported transcription providers: #{TRANSCRIPTION_PROVIDERS.keys.join(', ')}" unless factory

      path = @input.to_s
      raise ArgumentError, "#{self.class.name}: audio file not found: #{path.inspect}" unless File.exist?(path)

      format = File.extname(path).delete_prefix(".").downcase
      raise ArgumentError, "#{self.class.name}: cannot determine audio format from #{path.inspect} " \
                           "— expected a file extension like .mp3/.wav/.flac/.m4a/.ogg/.webm/.aac" if format.empty?

      opts = { model: entry[:model], audio_data: File.binread(path), audio_format: format }
      language = entry[:language] || @config[:transcribe_language]
      opts[:language] = language if language
      factory.call.call(**opts)
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
