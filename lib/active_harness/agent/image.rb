module ActiveHarness
  class Agent
    class << self
      # Mark this agent as an image generation agent.
      #
      #   class ImageAgent < ActiveHarness::Agent
      #     image true
      #     size  "1024x1024"
      #
      #     model do
      #       use      provider: :openrouter, model: "openai/gpt-5-image-mini"
      #       fallback provider: :openai,     model: "gpt-image-1"
      #     end
      #   end
      #
      # result.output   — base64 string or data-URI (provider-dependent)
      # result.processed — same as output (format :text default)
      def image(value = true)
        agent_config[:image] = value
      end

      # Default image size for all models in this agent's chain.
      # Can be overridden per-model via:  use provider: :openai, model: "...", size: "1024x1792"
      def size(default_size)
        agent_config[:image_size] = default_size
      end
    end

    alias_method :_model_list_base, :model_list

    def model_list
      list = _model_list_base
      validate_image_models!(list) if @config[:image]
      list
    end

    private

    # Models absent from the Pricing registry are silently skipped — unknown
    # models are assumed valid to avoid false negatives on new/private models.
    def validate_image_models!(list)
      list.each do |entry|
        info = Pricing.find(entry[:model].to_s)
        next unless info

        unless info.categories.include?("imggen")
          raise ArgumentError,
            "#{self.class.name}: model #{entry[:model].inspect} (provider: #{entry[:provider]}) " \
            "does not support image generation " \
            "(output_modalities: #{info.output_modalities.inspect}). " \
            "Use a model that has 'image' in output_modalities."
        end
      end
    end
  end
end
