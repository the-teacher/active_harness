module ActiveHarness
  class Pipeline
    VALID_HOOKS      = %i[before_step after_step stopped complete].freeze
    VALID_STEP_HOOKS = %i[before_step after_step].freeze

    class << self
      # Register a global or per-step hook.
      #
      # Global hooks fire on every step:
      #   on :before_step do |step_name, payload| ... end
      #   on :after_step  do |step_name, result|  ... end
      #   on :stopped     do |step_name, result|  ... end
      #   on :complete    do |last_result|         ... end
      #
      # Per-step hooks fire only for the named step (no step_name passed):
      #   on :before_step, :translate do |payload| ... end
      #   on :after_step,  :translate do |result|  ... end
      def on(event, step_name = nil, &block)
        if step_name
          unless VALID_STEP_HOOKS.include?(event)
            raise ArgumentError,
              "Per-step hooks support: #{VALID_STEP_HOOKS.join(", ")}. Got :#{event}"
          end
          pipeline_config[:step_hooks][step_name] ||= {}
          (pipeline_config[:step_hooks][step_name][event] ||= []) << block
        else
          unless VALID_HOOKS.include?(event)
            raise ArgumentError,
              "Unknown Pipeline hook :#{event}. Valid: #{VALID_HOOKS.join(", ")}"
          end
          (pipeline_config[:hooks][event] ||= []) << block
        end
      end

      # Rails-style aliases for +on+:
      #
      # Global:
      #   before :step                          do |name, payload| end  # → on :before_step
      #   after  :step                          do |name, result|  end  # → on :after_step
      #   callback :stopped                     do |name, result|  end  # → on :stopped
      #   callback :complete                    do |result|        end  # → on :complete
      #
      # Per-step:
      #   after  :step, :translate              do |result| end
      #   before :step, :translate              do |payload| end
      def before(event, step_name = nil, &block)
        on(:"before_#{event}", step_name, &block)
      end

      def after(event, step_name = nil, &block)
        on(:"after_#{event}", step_name, &block)
      end

      def callback(event, &block)
        on(event, &block)
      end
    end

    include Core::HookRunner

    private

    def fire(event, step_name, data, config)
      run_hooks(config[:hooks], event, step_name, data)
      @stream&.call(:pipeline, event, step_name, data)
    rescue IOError, ActionController::Live::ClientDisconnected
      nil
    end

    # Per-step hook: receives (data) only — not forwarded to stream
    # (global fire already covers the step event with step_name context).
    def fire_step(event, step_name, data, config)
      run_hooks(config[:step_hooks][step_name] || {}, event, data)
    end
  end
end
