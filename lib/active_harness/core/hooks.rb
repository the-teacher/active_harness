module ActiveHarness
  module Core
    # Shared hook execution logic included by Agent, Tribunal, and Pipeline.
    #
    # Hooks are stored in arrays so multiple +on+/+before+/+after+/+callback+
    # calls with the same event name accumulate — later registrations append
    # rather than overwrite. This lets modules register default hooks without
    # blocking user-defined hooks on the same event.
    #
    #   class MyAgent < ActiveHarness::Agent
    #     include SomeTracingConcern   # registers before(:call) internally
    #     before(:call) { ... }        # appends — both hooks run in order
    #   end
    module HookRunner
      private

      # Execute every block registered for +event+, passing +args+ to each.
      # Blocks run in the receiver's instance context (instance_exec / instance_eval).
      def run_hooks(hooks_hash, event, *args)
        Array(hooks_hash[event]).each do |blk|
          args.any? ? instance_exec(*args, &blk) : instance_eval(&blk)
        end
      end
    end
  end
end
