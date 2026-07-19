module ActiveHarness
  class Agent
    class << self
      # Mark this agent as an audio transcription agent.
      #
      #   class TranscriptionAgent < ActiveHarness::Agent
      #     transcribe true
      #
      #     model do
      #       use      provider: :openrouter, model: "openai/whisper-1"
      #       fallback provider: :openrouter, model: "deepgram/nova-3"
      #     end
      #   end
      #
      # @input           — path to a local audio file (String), not free text
      # result.output    — transcribed text (String)
      # result.processed — same as output (format :text default)
      def transcribe(value = true)
        agent_config[:transcribe] = value
      end

      # Default ISO-639-1 language hint for all models in this agent's chain.
      # Can be overridden per-model via:  use provider: :openrouter, model: "...", language: "ja"
      def language(default_language)
        agent_config[:transcribe_language] = default_language
      end
    end

    alias_method :_model_list_before_transcribe, :model_list

    def model_list
      list = _model_list_before_transcribe
      validate_transcription_models!(list) if @config[:transcribe]
      list
    end

    private

    alias_method :_normalize_input_before_transcribe, :normalize_input!

    # @input is a file path for transcription agents, not free text —
    # stripping/collapsing whitespace could corrupt a path. Skip it.
    def normalize_input!
      return if @config[:transcribe]
      _normalize_input_before_transcribe
    end

    # Models absent from the Pricing registry are silently skipped — unknown
    # models are assumed valid to avoid false negatives on new/private models.
    def validate_transcription_models!(list)
      list.each do |entry|
        info = Pricing.find(entry[:model].to_s)
        next unless info

        unless info.categories.include?("transcription")
          raise ArgumentError,
            "#{self.class.name}: model #{entry[:model].inspect} (provider: #{entry[:provider]}) " \
            "does not support audio transcription " \
            "(output_modalities: #{info.output_modalities.inspect}). " \
            "Use a model that has 'transcription' in output_modalities."
        end
      end
    end
  end
end
