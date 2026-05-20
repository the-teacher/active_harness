module ActiveHarness
  class Pipeline
    class Step
      attr_reader :name, :agent_class

      def initialize(name, agent_class = nil, &block)
        @name        = name
        @agent_class = agent_class
        @stop_if     = nil
        instance_eval(&block) if block_given?
      end

      # DSL: use TranslationAgent
      def use(klass)
        @agent_class = klass
      end

      # DSL (inside block): stop_if ->(result) { ... }
      # Getter (external):   step.stop_if  → lambda or nil
      def stop_if(lam = nil)
        lam ? @stop_if = lam : @stop_if
      end

      # True if agent_class is a Tribunal subclass — tribunal steps do not update payload.
      def tribunal?
        @agent_class.is_a?(Class) && @agent_class <= ActiveHarness::Tribunal
      end

      # Transform steps update payload to result.output after execution.
      # Guard steps (stop_if present) and tribunal steps leave payload unchanged.
      def transform?
        !tribunal? && @stop_if.nil?
      end
    end
  end
end
