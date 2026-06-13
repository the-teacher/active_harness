require "json"

module ActiveHarness
  # Pricing namespace — shared types and a facade over pricing source modules.
  #
  # Sources (in priority order):
  #   Pricing::OpenRouter  — live data from OpenRouter API  (image models, 24h cache)
  #   Pricing::ModelsDev   — live data from models.dev API  (all providers, 24h cache)
  #
  # Public facade delegates to ModelsDev (used as the general fallback):
  #   Pricing.find("gpt-4o")       → ModelPrice or nil
  #   Pricing.all                  → Array<ModelPrice>
  #   Pricing.providers.openai     → Array<ModelPrice>
  #   Pricing.update               → refreshes ModelsDev cache
  module Pricing
    # Pricing rates for a single model.
    # All *_per_million fields are in USD per 1M tokens.
    # audio_input_per_million / audio_output_per_million may represent
    # per-million audio tokens or per-unit (second/char) depending on provider.
    ModelPrice = Struct.new(
      :id,
      :name,
      :provider,
      # Primary fields (used for cost calculation, backward-compatible)
      :input_per_million,               # text tokens input
      :output_per_million,              # primary output (text or image_output for imggen)
      :cache_read_input_per_million,
      :cache_write_input_per_million,
      :context_window,
      :max_output_tokens,
      :input_modalities,
      :output_modalities,
      # Extended modality-specific pricing
      :image_input_per_million,         # image tokens accepted as input (vision models)
      :image_output_per_million,        # image generation output tokens (imggen models)
      :audio_input_per_million,         # audio tokens accepted as input
      :audio_output_per_million,        # audio output tokens (TTS models)
      :web_search_per_request,          # per web-search call in USD
      keyword_init: true
    ) do
      # Capability tags derived from modality data.
      # Possible values: "vision", "pdf", "audio", "video", "imggen", "embed",
      #                  "speech", "transcription", "rerank"
      def categories
        inp = Array(input_modalities)
        out = Array(output_modalities)
        cats = []
        cats << "vision"        if inp.include?("image")
        cats << "pdf"           if inp.include?("pdf")
        cats << "audio"         if inp.include?("audio")
        cats << "video"         if inp.include?("video") || out.include?("video")
        cats << "imggen"        if out.include?("image")
        cats << "speech"        if out.include?("speech")
        cats << "transcription" if out.include?("transcription")
        cats << "rerank"        if out.include?("rerank")
        cats << "embed"         if out.include?("embeddings")
        cats
      end

      def inspect
        parts = ["id=#{id.inspect}", "provider=#{provider.inspect}"]
        parts << "input=$#{input_per_million}/M"  if input_per_million
        parts << "output=$#{output_per_million}/M" if output_per_million
        parts << "ctx=#{context_window}"           if context_window
        parts << "cats=#{categories.join(',')}"    if categories.any?
        "#<ModelPrice #{parts.join(' ')}>"
      end
    end

    # Proxy returned by Pricing.providers — exposes providers as methods and [].
    class ProvidersProxy
      def initialize(source = nil)
        @source = source
      end

      def [](name)
        source.for_provider(name.to_s)
      end

      def list
        source.provider_names
      end

      def method_missing(name, *args, &block)
        provider = name.to_s
        if source.provider_names.include?(provider)
          source.for_provider(provider)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        source.provider_names.include?(name.to_s) || super
      end

      private

      def source
        @source || ModelsDev
      end
    end

    # ---------------------------------------------------------------------------
    # Facade — delegates to ModelsDev (general fallback source)
    # ---------------------------------------------------------------------------
    class << self
      # Eagerly fetch all pricing sources and load them into memory.
      # Called at Rails startup. Network failures are silently ignored.
      def preload!
        ModelsDev.preload!
        OpenRouter.preload!
      end

      def find(model_id)
        ModelsDev.find(model_id)
      end

      def all
        ModelsDev.all
      end

      def providers
        ModelsDev.providers
      end

      def for_provider(name)
        ModelsDev.for_provider(name)
      end

      def provider_names
        ModelsDev.provider_names
      end

      def update
        ModelsDev.update
      end

      def reload!
        ModelsDev.reload!
      end

      def cache_file
        ModelsDev.cache_file
      end

      def available_providers
        ModelsDev.available_providers
      end
    end
  end
end
