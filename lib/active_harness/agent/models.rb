module ActiveHarness
  class Agent
    class << self
      # Array-style model list:
      #
      #   models [
      #     { provider: :openai,     model: "gpt-4.1-mini" },
      #     { provider: :openrouter, model: "mistralai/mistral-nemo" }
      #   ]
      def models(list)
        agent_config[:models] = Array(list)
      end

      # Output format for this agent.
      #
      #   format :text   # default — output is returned as-is
      #   format :json   # output is parsed; result.parsed is a Ruby Hash/Array
      def format(type)
        unless %i[text json].include?(type)
          raise ArgumentError, "Unknown format :#{type}. Valid values: :text, :json"
        end

        agent_config[:format] = type
      end

      # Block-based model DSL:
      #
      #   model do
      #     use      provider: :openrouter, model: "mistralai/mistral-nemo"
      #     fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
      #   end
      def model(&block)
        config = ModelConfig.new
        config.instance_eval(&block)
        agent_config[:model] = config.to_h
      end
    end

    # Public instance API — returns a ModelList proxy for this agent instance.
    #
    # Allows adding models at runtime before calling the agent:
    #
    #   agent.models.prepend([{ provider: :openrouter, model: "..." }])
    #   agent.models.push([{ provider: :openrouter, model: "..." }])
    #
    # Any prepended/pushed models are combined with the class-defined chain:
    #   [prepended...] + [class chain / constructor override] + [pushed...]
    def models
      @model_list_proxy ||= begin
        base = if @models_override&.any?
                 @models_override
               elsif (m = @config[:model])
                 m[:models] || []
               else
                 @config[:models] || []
               end
        ModelList.new(base)
      end
    end

    private

    def model_list
      list = models.to_a
      raise ArgumentError, "#{self.class.name}: no models configured. Use `model do...end` or `models [...]`." if list.empty?

      list
    end
  end

  # ---------------------------------------------------------------------------
  # ModelList — mutable proxy returned by agent.models
  # ---------------------------------------------------------------------------
  class ModelList
    def initialize(base_models)
      @base      = Array(base_models)
      @prepended = []
      @appended  = []
    end

    # Add models BEFORE the existing chain. Calling multiple times keeps order
    # (last prepend ends up first).
    def prepend(models)
      @prepended = Array(models) + @prepended
      self
    end

    # Add models AFTER the existing chain.
    def push(models)
      @appended += Array(models)
      self
    end

    # Replace the entire chain, discarding prepended/appended too.
    #
    #   agent.models.replace([{ provider: :openrouter, model: "..." }])
    def replace(models)
      @base      = Array(models)
      @prepended = []
      @appended  = []
      self
    end

    # Insert a single model entry at an arbitrary position in the final chain.
    # Position 0 is the same as prepend; -1 appends after the last element.
    #
    #   agent.models.insert(0,  { provider: :openrouter, model: "fast-model" })
    #   agent.models.insert(2,  { provider: :openrouter, model: "mid-model" })
    #   agent.models.insert(-1, { provider: :openrouter, model: "last-resort" })
    def insert(position, model)
      to_a.tap { |list| list.insert(position, model) }.then do |new_list|
        @prepended = []
        @base      = new_list
        @appended  = []
      end
      self
    end

    # Return the fully assembled list: prepended + base + appended.
    def to_a
      @prepended + @base + @appended
    end

    def inspect
      "#<ModelList prepended=#{@prepended.size} base=#{@base.size} appended=#{@appended.size}>"
    end
  end

  # ---------------------------------------------------------------------------
  # DSL builder — used by Agent.model { ... }
  # ---------------------------------------------------------------------------
  class ModelConfig
    def initialize
      @models = []
    end

    def use(provider:, model:, temperature: nil, name: nil)
      @models << { provider: provider, model: model, temperature: temperature, name: name }.compact
    end

    alias fallback use

    def to_h
      { models: @models }
    end
  end
end
