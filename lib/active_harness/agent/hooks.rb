module ActiveHarness
  class Agent
    VALID_HOOKS = %i[
      setup
      before_call
      after_call
      before_system_prompt
      after_system_prompt
      before_parse
      after_parse
      parse_error
      retry
      failure
    ].freeze

    class << self
      # Unified hook DSL.
      #
      #   on :setup                do ... end
      #   on :before_call          do ... end
      #   on :after_call           do |result| ... end
      #   on :before_system_prompt do ... end
      #   on :after_system_prompt  do |prompt| ... end
      #   on :before_parse         do |raw| ... end
      #   on :after_parse          do |parsed| ... end
      #   on :parse_error          do |raw, error| ... end
      #   on :retry                do |entry, error| ... end
      #   on :failure              do |attempts| ... end
      def on(event, &block)
        unless VALID_HOOKS.include?(event)
          raise ArgumentError, "Unknown hook :#{event}. Valid hooks: #{VALID_HOOKS.map { |h| ":#{h}" }.join(", ")}"
        end

        agent_config[:hooks] ||= {}
        (agent_config[:hooks][event] ||= []) << block
      end

      # Rails-style aliases for +on+:
      #
      #   before :call                    do ... end  # → on :before_call
      #   before :system_prompt           do ... end  # → on :before_system_prompt
      #   after  :call                    do |r| end  # → on :after_call
      #   after  :system_prompt           do |p| end  # → on :after_system_prompt
      #   after  :parse                   do |p| end  # → on :after_parse
      #   callback :retry                 do |e,err| end
      #   callback :failure               do |a| end
      #   callback :setup                 do end
      #   callback :parse_error           do |r,e| end
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

    include Core::HookRunner

    private

    def run_hook(event, *args)
      run_hooks(@config[:hooks] || {}, event, *args)
    end

    # Unified internal method: fires the DSL hook AND the external event_stream lambda.
    # Consistent with Tribunal#fire and Pipeline#fire.
    def fire(event, *args)
      run_hook(event, *args)
      @event_stream&.call(event, *args)
    rescue IOError, ActionController::Live::ClientDisconnected
    end
  end
end
