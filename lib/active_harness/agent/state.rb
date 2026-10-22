module ActiveHarness
  # Intent + verification criteria of one Agent run. Built by +setup+ (a Pipeline);
  # without +setup+ the runtime makes a minimal Goal from the input.
  Goal = Struct.new(:task, :constraints, :success_criteria, :plan, keyword_init: true) do
    def self.from(value)
      case value
      when Goal   then value
      when String then value.strip.empty? ? nil : new(task: value)
      when Hash
        h = value.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
        return nil if h[:task].to_s.strip.empty?

        new(task: h[:task], constraints: h[:constraints], success_criteria: h[:success_criteria], plan: h[:plan])
      end
    end
  end

  # What a goal check returns.
  #
  #   status   — :achieved | :continue | :replan | :needs_input | :failed
  #   feedback — text for the model (for :continue / :replan)
  #   evidence — anything useful for the trace
  GoalCheckResult = Struct.new(:status, :feedback, :evidence, keyword_init: true) do
    def self.from(value)
      case value
      when GoalCheckResult then value
      when true            then new(status: :achieved)
      when false, nil      then new(status: :continue, feedback: "The goal is not reached yet.")
      when Hash
        new(status: (value[:status] || value["status"])&.to_sym, feedback: value[:feedback] || value["feedback"], evidence: value[:evidence] || value["evidence"])
      else
        raise ArgumentError, "A goal check must return GoalCheckResult (or true/false/Hash), got #{value.class}"
      end
    end
  end

  # One tool call requested by the model, with its outcome.
  #
  #   id     — provider call id; the tool message is bound to it
  #   name   — wire name (os__ls)
  #   tool   — Tool class (nil for an unknown name)
  #   input  — validated arguments (symbol keys) or the raw value if invalid
  #   result — ToolResult
  ToolCall = Struct.new(:id, :name, :tool, :input, :result, keyword_init: true) do
    def full_name
      tool ? tool.full_name : name
    end

    def denied?
      !result.nil? && result.status == :denied
    end

    def error?
      !result.nil? && result.status == :error
    end
  end

  # One iteration of the Agent loop.
  AgentTurn = Struct.new(:number, :request_name, :request, :response, :tool_calls, :steps, :verdict, :ms, keyword_init: true) do
    def denied_calls
      tool_calls.select(&:denied?)
    end

    def error_calls
      tool_calls.select(&:error?)
    end
  end

  # Trustworthy data of one run — the source of truth. The model-facing context is
  # only a view built from it by the context builder.
  #
  #   messages — normalized conversation (user / assistant / tool)
  #   events   — full journal of turns, denials, tool calls and results; never summarized
  AgentState = Struct.new(
    :run_id, :status, :input, :goal, :plan,
    :messages, :events, :artifacts,
    :turn, :tool_calls_count, :usage, :stop_reason,
    keyword_init: true
  )

  class Agent
    # Default context builder: the full history. A custom builder is any object with
    # call(state:) returning a messages array (a shortened view, never a rewrite of the state).
    class ContextBuilder
      def call(state:)
        state.messages.map(&:dup)
      end
    end
  end
end
