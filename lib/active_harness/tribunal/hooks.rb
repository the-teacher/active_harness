module ActiveHarness
  class Tribunal
    VALID_HOOKS = %i[
      before_call
      before_agent
      after_agent
      agent_error
      after_call
      before_verdict
      after_verdict
    ].freeze

    class << self
      # Class-level hook registration.
      #
      #   on :before_call                  do ... end
      #   on :before_agent                 do |agent| ... end
      #   on :after_agent                  do |result| ... end
      #   on :agent_error                  do |name, error| ... end
      #   on :after_call                   do |results, errors| ... end
      #   on :before_verdict               do |results| results end  # transform hook
      #   on :after_verdict                do |verdict| ... end
      def on(event, &block)
        unless VALID_HOOKS.include?(event)
          raise ArgumentError,
            "Unknown Tribunal hook :#{event}. Valid hooks: #{VALID_HOOKS.map { |h| ":#{h}" }.join(", ")}"
        end

        tribunal_config[:hooks][event] = block
      end

      # Rails-style aliases for +on+:
      #
      #   before :call                     do ... end       # → on :before_call
      #   before :agent                    do |agent| end   # → on :before_agent
      #   before :verdict                  do |results| end # → on :before_verdict (transform)
      #   after  :call                     do |r, e| end    # → on :after_call
      #   after  :agent                    do |result| end  # → on :after_agent
      #   after  :verdict                  do |verdict| end # → on :after_verdict
      #   callback :agent_error            do |name, e| end # → on :agent_error
      def before(event, &block)
        on(:"before_#{event}", &block)
      end

      def after(event, &block)
        on(:"after_#{event}", &block)
      end

      def callback(event, &block)
        on(event, &block)
      end
    end

    # Instance-level hook registration — overrides class-level hooks for this instance.
    # :before_verdict is a transform hook: its return value replaces the results array
    # passed to the process block.
    def on(event, &block)
      unless VALID_HOOKS.include?(event)
        raise ArgumentError,
          "Unknown Tribunal hook :#{event}. Valid hooks: #{VALID_HOOKS.map { |h| ":#{h}" }.join(", ")}"
      end

      @hooks[event] = block
      self
    end

    private

    def run_hook(event, *args)
      return unless @hooks[event]

      if args.any?
        instance_exec(*args, &@hooks[event])
      else
        instance_eval(&@hooks[event])
      end
    end

    # Fire the DSL-registered hook AND the external tribunal_event_stream lambda (if set).
    def fire(event, *args)
      run_hook(event, *args)
      @tribunal_event_stream&.call(event, *args)
    rescue IOError, ActionController::Live::ClientDisconnected
      nil
    end

    # Like run_hook but uses the return value to replace the passed value.
    # Used by :before_verdict to allow results transformation before verdict computation.
    def transform_hook(event, value)
      return value unless @hooks[event]

      instance_exec(value, &@hooks[event])
    end
  end
end
