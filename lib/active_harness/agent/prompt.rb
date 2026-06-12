module ActiveHarness
  class Agent
    class << self
      # System prompt for this agent.
      # Accepts:
      #   - a String  → used as-is
      #   - a Class   → instantiated and resolved via #call or #text
      #   - a Proc    → called at request time (no arguments)
      #
      #   system_prompt "You are a helpful assistant."
      #   system_prompt MyPromptClass
      #   system_prompt -> { "Dynamic prompt built at #{Time.now}" }
      def system_prompt(text_or_class)
        agent_config[:system_prompt] = text_or_class
      end
      alias prompt system_prompt
    end

    private

    attr_reader :system_prompt
    public :system_prompt

    def resolve_system_prompt
      fire(:before_system_prompt)

      sp = @config[:system_prompt]

      prompt = case sp
      when String   then sp
      when NilClass then nil
      when Proc     then instance_exec(&sp)
      when Class
        instance = sp.new
        inject_agent_state(instance)
        if    instance.respond_to?(:call) then instance.call
        elsif instance.respond_to?(:text) then instance.text
        else  instance.to_s
        end
      else
        inject_agent_state(sp)
        if    sp.respond_to?(:call) then sp.call
        elsif sp.respond_to?(:text) then sp.text
        else  sp.to_s
        end
      end

      fire(:after_system_prompt, prompt)
      prompt
    end

    # Injects agent state into a prompt class instance before #call.
    # Available in prompt classes: @input, @context, @params, @memory, @context_window, @config
    def inject_agent_state(obj)
      obj.instance_variable_set(:@input,          @input)
      obj.instance_variable_set(:@context,        @context)
      obj.instance_variable_set(:@params,         @params)
      obj.instance_variable_set(:@config,         @config)
      obj.instance_variable_set(:@memory,         @memory)
      obj.instance_variable_set(:@context_window, context_window_for_prompt)
    end

    def context_window_for_prompt
      Pricing.find(model_list.to_a.first&.dig(:model).to_s)&.context_window
    rescue StandardError
      nil
    end
  end
end
