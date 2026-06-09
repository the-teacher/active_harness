require_relative "memory/adapter/base"
require_relative "memory/adapter/json_file"
require_relative "memory/adapter/postgresql"
require_relative "memory/adapter/sqlite"

module ActiveHarness
  # Conversational memory for agents.
  #
  # Memory only records the history of request/response turns.
  # It does NOT automatically inject history into LLM messages.
  # Injection is always manual — you control when and how context is used.
  #
  # --- Recording (automatic) ---
  #
  # When a Memory object is passed to an agent, the agent automatically
  # saves each successful turn (request + response) after the call.
  #
  #   memory = ActiveHarness::Memory.new(session_id: "u42", depth: 8)
  #   SupportAgent.call(input: "Hello", memory: memory)
  #   # => turn is saved to storage/ai/memory/u42.json
  #
  # --- Manual injection patterns ---
  #
  # Option A: prepend history to input in a before_call hook
  #
  #   on :before_call do
  #     history = @memory&.to_messages
  #     if history&.any?
  #       lines = history.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n")
  #       @input = "Previous conversation:\n#{lines}\n\nUser: #{@input}"
  #     end
  #   end
  #
  # Option B: inject history into the system prompt
  #
  #   on :after_system_prompt do |prompt|
  #     history = @memory&.to_messages
  #     if history&.any?
  #       lines = history.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n")
  #       @system_prompt = "#{prompt}\n\nConversation so far:\n#{lines}"
  #     end
  #   end
  #
  # Option C: use a prompt class that reads @memory directly
  #
  #   class SupportPrompt
  #     def call
  #       base = "You are a helpful assistant."
  #       return base unless @memory&.size&.positive?
  #       history = @memory.to_messages
  #                        .map { |m| "#{m[:role]}: #{m[:content]}" }
  #                        .join("\n")
  #       "#{base}\n\nConversation so far:\n#{history}"
  #     end
  #   end
  #
  class Memory
    ADAPTERS = {
      json_file: ->(**opts) { Adapter::JsonFile.new(**opts) }
    }.freeze

    attr_reader :session_id

    # -------------------------------------------------------------------------
    # Constructor
    # -------------------------------------------------------------------------
    #   session_id       — required; uniquely identifies this conversation
    #   depth            — how many past turns to inject into messages (nil = all)
    #   adapter          — :json_file (default), or an adapter instance
    #   enabled          — false disables all reads and writes (no-op mode)
    #   read_only        — true: load history but never write new turns
    #   namespace        — isolates history per-agent within a session
    #   on_trim          — Proc called with trimmed turns on storage trim
    #   async            — write to adapter in a background thread
    #   **adapter_opts   — forwarded to the adapter (path, storage_size, etc.)
    def initialize(
      session_id:,
      depth:       nil,
      adapter:     :json_file,
      enabled:     true,
      read_only:   false,
      namespace:   nil,
      on_trim:     nil,
      async:       false,
      **adapter_opts
    )
      @session_id  = session_id
      @depth       = depth
      @enabled     = enabled
      @read_only   = read_only
      @namespace   = namespace
      @async       = async
      @turns       = []
      @loaded      = false

      adapter_opts[:namespace] = namespace if namespace
      adapter_opts[:on_trim]   = on_trim   if on_trim

      @adapter = resolve_adapter(adapter, adapter_opts)
    end

    # -------------------------------------------------------------------------
    # Public API
    # -------------------------------------------------------------------------

    # Load history from storage into RAM.
    # Called automatically by the agent at the start of #call.
    # After loading, history is available via #turns and #to_messages
    # for manual injection in hooks or prompt classes.
    def load
      return unless @enabled
      return if @loaded

      @adapter.open(@session_id)
      @turns  = @adapter.read
      @loaded = true
    end

    # Record a turn after a successful agent call.
    def record(request:, response:, **meta)
      return unless @enabled
      return if @read_only

      turn = { request: request.to_s, response: response.to_s }
      turn.merge!(meta) unless meta.empty?
      turn[:at] ||= Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      @turns << turn

      if @async
        Thread.new { safe_write(turn) }
      else
        safe_write(turn)
        # keep RAM in sync with what adapter stored (adapter may have trimmed)
        @turns = @adapter.read
      end
    end

    # Returns messages array for LLM consumption, respecting depth.
    # Optional filters:
    #   filter:       ->(turn) { turn[:agent] == "SupportAgent" }
    #   since:        Time.now - 3600
    #   token_budget: 4000  # rough limit (chars / 4 estimate); trims oldest turns first
    def to_messages(filter: nil, since: nil, token_budget: nil)
      turns = @turns.dup
      turns.select! { |t| filter.call(t) }   if filter
      turns.select! { |t| after?(t, since) } if since
      turns = turns.last(@depth)              if @depth
      turns = trim_to_token_budget(turns, token_budget) if token_budget

      turns.flat_map do |t|
        [
          { role: "user",      content: t[:request]  },
          { role: "assistant", content: t[:response] }
        ]
      end
    end

    # All stored turns without depth/filter trimming.
    def turns
      @turns.dup
    end

    # Number of turns currently in memory.
    def size
      @turns.size
    end

    # Clear in-RAM turns (does not touch the storage file/key).
    def clear
      @turns  = []
      @loaded = false
    end

    # Delete the session from storage backend entirely.
    def delete
      return unless @enabled

      @adapter.open(@session_id) unless @loaded
      @adapter.delete
      clear
    end

    # Flush and close the adapter.
    def close
      @adapter.close
    end

    # -------------------------------------------------------------------------
    private
    # -------------------------------------------------------------------------

    def resolve_adapter(adapter, opts)
      case adapter
      when Symbol
        factory = ADAPTERS[adapter]
        raise ArgumentError, "Unknown adapter: #{adapter.inspect}. Available: #{ADAPTERS.keys.join(', ')}" unless factory
        factory.call(**opts)
      else
        # assume an adapter instance
        adapter
      end
    end

    def safe_write(turn)
      @adapter.open(@session_id) unless @loaded
      @adapter.write(turn)
    end

    def after?(turn, time)
      return true unless turn[:at]
      turn_time = Time.parse(turn[:at].to_s) rescue nil
      turn_time ? turn_time >= time : true
    end

    def trim_to_token_budget(turns, budget)
      return turns if turns.empty?

      total = 0
      turns.reverse.take_while do |t|
        tokens = ((t[:request].to_s.length + t[:response].to_s.length) / 4.0).ceil
        total += tokens
        total <= budget
      end.reverse
    end
  end
end
