module ActiveHarness
  class Pipeline
    class Step
      attr_reader :name, :executor

      def initialize(name, executor = nil, &block)
        @name     = name
        @executor = executor
        @stop_if  = nil
        instance_eval(&block) if block_given?
      end

      # DSL: use TranslationAgent / SafetyTribunal / NestedPipeline
      def use(klass)
        @executor = klass
      end

      # DSL (inside block): stop_if ->(result) { ... }
      # Getter (external):   step.stop_if  → lambda or nil
      def stop_if(lam = nil)
        lam ? @stop_if = lam : @stop_if
      end

      # DSL: define how to extract the new payload from a result.
      # When provided, the step always updates the payload — even if stop_if is also set.
      # The block receives the Result and must return the new payload value.
      #
      #   step :laundry do
      #     use PromptLaundryPipeline
      #     transform { |result| result.output }
      #     stop_if   ->(result) { result.processed["stopped"] == true }
      #   end
      def transform(&block)
        @transform_block = block if block
        @transform_block
      end

      def lambda?
        @executor.is_a?(Proc)
      end

      # True if the executor is a Tribunal subclass — tribunal steps do not update payload.
      def tribunal?
        @executor.is_a?(Class) && @executor <= ActiveHarness::Tribunal
      end

      # Returns true when this step should update the pipeline payload after execution.
      # A step transforms when:
      #   - an explicit transform block is defined (overrides default), OR
      #   - no stop_if and not a tribunal (legacy default)
      def transform?
        @transform_block ? true : (!tribunal? && @stop_if.nil?)
      end

      # Extract the new payload value from result.
      # Uses the user-defined transform block when present; falls back to result.output.
      def extract_payload(result)
        @transform_block ? @transform_block.call(result) : result.output
      end
    end
  end
end
