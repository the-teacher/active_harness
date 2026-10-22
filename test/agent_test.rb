require "test_helper"

class AgentTest < Minitest::Test
  def agent_class(request, tools: [EchoTool], &block)
    Class.new(ActiveHarness::Agent) do
      self.request(request)
      self.tools(*tools) unless tools.empty?
      class_eval(&block) if block
    end
  end

  def test_answer_without_tools_finishes_by_answer
    req, provider = scripted_request([text("Hello!")])
    agent = agent_class(req, tools: []).call(input: "Hi")

    assert_equal :done, agent.status
    assert_equal :final_answer, agent.stop_reason
    assert_equal "Hello!", agent.output
    assert_equal 1, agent.turns.size
    assert_nil provider.calls.first[:tools]
    assert_equal [{ role: "user", content: "Hi" }], provider.calls.first[:messages].map { |m| { role: m[:role].to_s, content: m[:content] } }
  end

  def test_tool_loop_executes_tools_and_feeds_results_back
    req, provider = scripted_request([
      tool_call("test__echo", { text: "one" }, id: "c1"),
      tool_call("test__echo", { "text" => "two" }, id: "c2"),
      text("All done")
    ])
    agent = agent_class(req).call(input: "Echo twice")

    assert_equal :done, agent.status
    assert_equal "All done", agent.output
    assert_equal 3, agent.turns.size
    assert_equal %w[echo:\ one echo:\ two], agent.tool_calls.map { |c| c.result.output }
    assert_equal 2, agent.state.tool_calls_count

    # tools were offered with the neutral schema
    assert_equal "test__echo", provider.calls.first[:tools].first[:name]

    # the last request saw the tool results bound to the call ids
    last = provider.calls.last[:messages]
    tool_msgs = last.select { |m| m[:role].to_s == "tool" }
    assert_equal %w[c1 c2], tool_msgs.map { |m| m[:tool_call_id] }
    assert_equal ["echo: one", "echo: two"], tool_msgs.map { |m| m[:content] }
    assert_equal :assistant, last.find { |m| m[:tool_calls] }[:role]

    # usage is summed over all Requests
    assert_equal 45, agent.usage.tokens.total
  end

  def test_unknown_tool_is_never_executed_and_model_is_told
    req, provider = scripted_request([tool_call("os__rm", { path: "/" }), text("ok, I can't")])
    agent = agent_class(req).call(input: "rm it")

    assert_equal :done, agent.status
    call = agent.tool_calls.first
    assert_nil call.tool
    assert_equal :denied, call.result.status
    assert_equal "unknown tool: os__rm", provider.calls.last[:messages].last[:content]
    assert_equal 1, agent.denied_calls.size
  end

  def test_invalid_arguments_are_refused_before_the_tool_runs
    ran = false
    spy = Class.new(ActiveHarness::Tool) do
      tool_scope :test
      tool_name "spy"
      param :n, "n"
      define_method(:perform) { |_| ran = true }
      def self.name; "SpyTool"; end
    end
    req, = scripted_request([tool_call("test__spy", {}), tool_call("test__spy", { n: 1, extra: 2 }), tool_call("test__spy", "not json"), text("fine")])
    agent = agent_class(req, tools: [spy]).call(input: "go")

    refute ran
    assert_equal ["missing required argument: n", "unknown argument: extra", "arguments are not valid JSON"],
                 agent.tool_calls.map { |c| c.result.model_message }
    assert_equal :done, agent.status
  end

  def test_tool_error_goes_back_to_the_model_with_generic_text
    req, provider = scripted_request([tool_call("test__boom"), text("Let me finish without it")])
    agent = agent_class(req, tools: [BoomTool]).call(input: "go")

    assert_equal :done, agent.status
    msg = provider.calls.last[:messages].last[:content]
    assert_equal ActiveHarness::Tool::GENERIC_ERROR_MESSAGE, msg
    refute_match(/secret/, msg)
    assert_match(/secret internals/, agent.state.events.find { |e| e[:type] == :tool_call }[:detail])
  end

  def test_consecutive_tool_errors_stop_the_agent
    req, = scripted_request([tool_call("test__boom"), tool_call("test__boom", { why: "a" }), tool_call("test__boom", { why: "b" }), text("never")])
    agent = agent_class(req, tools: [BoomTool]).call(input: "go")

    assert_equal :stopped, agent.status
    assert_equal :too_many_tool_errors, agent.stop_reason
  end

  def test_a_successful_call_resets_the_error_counter
    req, = scripted_request([tool_call("test__boom"), tool_call("test__boom", { why: "a" }), tool_call("test__echo", { text: "x" }),
                             tool_call("test__boom", { why: "b" }), text("done")])
    agent = agent_class(req, tools: [BoomTool, EchoTool]).call(input: "go")
    assert_equal :done, agent.status
  end

  def test_too_many_denials
    req, = scripted_request(Array.new(6) { |i| tool_call("nope#{i}") } + [text("never")])
    agent = agent_class(req) { max_denials 3 }.call(input: "go")
    assert_equal :too_many_denials, agent.stop_reason
    assert_equal 3, agent.tool_calls.size
  end

  def test_max_turns
    req, = scripted_request(Array.new(5) { |i| tool_call("test__echo", { text: "t#{i}" }) } + [text("never")])
    agent = agent_class(req) { max_turns 3 }.call(input: "go")

    assert_equal :stopped, agent.status
    assert_equal :max_turns, agent.stop_reason
    assert_equal 3, agent.turns.size
  end

  def test_max_tool_calls
    req, = scripted_request([tool_call([["test__echo", { text: "1" }, "a"], ["test__echo", { text: "2" }, "b"], ["test__echo", { text: "3" }, "c"]]), text("never")])
    agent = agent_class(req) { max_tool_calls 2 }.call(input: "go")

    assert_equal :max_tool_calls, agent.stop_reason
    assert_equal 2, agent.tool_calls.size
  end

  def test_max_cost_blocks_tools_after_the_request_that_exceeded_it
    req, = scripted_request([tool_call("test__echo", { text: "x" }, cost: 0.6), text("never")])
    agent = agent_class(req) { max_cost 0.5 }.call(input: "go")

    assert_equal :max_cost, agent.stop_reason
    assert_empty agent.tool_calls
  end

  def test_max_cost_stops_before_the_next_request
    req, = scripted_request([tool_call("test__echo", { text: "x" }, cost: 0.3), tool_call("test__echo", { text: "y" }, cost: 0.3), text("never")])
    agent = agent_class(req) { max_cost 0.5 }.call(input: "go")

    assert_equal :max_cost, agent.stop_reason
    assert_equal 2, agent.turns.size
    assert_in_delta 0.6, agent.usage.cost.total
  end

  def test_loop_guard_stops_repeating_calls
    req, = scripted_request(Array.new(6) { tool_call("test__echo", { text: "same" }) } + [text("never")])
    agent = agent_class(req) { loop_guard times: 3 }.call(input: "go")

    assert_equal :repeating, agent.stop_reason
    assert_equal 3, agent.turns.size
  end

  def test_stop_if
    req, = scripted_request(Array.new(3) { |i| tool_call("test__echo", { text: "n#{i}" }) })
    agent = agent_class(req) { stop_if(:enough) { |turn| turn.number == 2 } }.call(input: "go")
    assert_equal :enough, agent.stop_reason
    assert_equal 2, agent.turns.size
  end

  def test_before_tool_hook_can_deny
    req, provider = scripted_request([tool_call("test__echo", { text: "x" }), text("ok")])
    agent = agent_class(req) { on(:before_tool, "test::echo") { |call| deny!("echo needs a human") } }.call(input: "go")

    assert_equal :denied, agent.tool_calls.first.result.status
    assert_equal "echo needs a human", provider.calls.last[:messages].last[:content]
  end

  def test_request_for_selects_a_named_request
    cheap, cheap_provider = scripted_request([text("from cheap")])
    main,  main_provider  = scripted_request([tool_call("test__echo", { text: "x" })])
    agent = Class.new(ActiveHarness::Agent) do
      request main
      request :cheap, cheap
      tools EchoTool
      request_for { |turn| turn.number > 1 ? :cheap : :default }
    end.call(input: "go")

    assert_equal "from cheap", agent.output
    assert_equal %i[default cheap], agent.turns.map(&:request_name)
    assert_equal 1, main_provider.calls.size
    assert_equal 1, cheap_provider.calls.size
  end

  def test_goal_continue_then_achieved
    req, provider = scripted_request([text("draft"), text("better")])
    verdicts = [ActiveHarness::GoalCheckResult.new(status: :continue, feedback: "too short"), ActiveHarness::GoalCheckResult.new(status: :achieved)]
    agent = agent_class(req, tools: []) { goal { |_candidate, _goal, _state| verdicts.shift } }.call(input: "write")

    assert_equal :done, agent.status
    assert_equal :goal_reached, agent.stop_reason
    assert_equal "better", agent.output
    assert_equal "Goal not reached: too short", provider.calls.last[:messages].last[:content]
  end

  def test_goal_class_gets_keywords
    check = Class.new do
      def call(candidate:, goal:, state:)
        ActiveHarness::GoalCheckResult.new(status: candidate == "42" ? :achieved : :continue, feedback: "want 42 for #{goal.task}")
      end
    end
    req, = scripted_request([text("42")])
    agent = agent_class(req, tools: []) { goal check }.call(input: "answer")
    assert_equal :goal_reached, agent.stop_reason
  end

  def test_goal_failed_after_max_goal_retries
    req, = scripted_request(Array.new(5) { text("nope") })
    agent = agent_class(req, tools: []) { goal { |*| false }; max_goal_retries 2 }.call(input: "x")

    assert_equal :stopped, agent.status
    assert_equal :goal_failed, agent.stop_reason
    assert_equal 3, agent.turns.size
    assert_equal "nope", agent.output
  end

  def test_goal_needs_input_is_not_a_success
    req, = scripted_request([text("Which file?")])
    agent = agent_class(req, tools: []) { goal { |*| { status: :needs_input } } }.call(input: "x")
    assert_equal :stopped, agent.status
    assert_equal :needs_input, agent.stop_reason
    assert_equal "Which file?", agent.output
  end

  def test_setup_builds_the_goal_and_finalize_shapes_the_output
    setup = Class.new(ActiveHarness::Pipeline) do
      step :goal, ->(input) { ActiveHarness::Result.new(output: input, processed: { "task" => "Do: #{input}", "success_criteria" => { "n" => 1 } }) }
    end
    seen = {}
    finalize = Class.new(ActiveHarness::Pipeline) do
      step :wrap, lambda { |input, context:, params:|
        seen.merge!(status: context[:status], reason: context[:stop_reason], state: context[:state])
        ActiveHarness::Result.new(output: "[#{context[:status]}] #{input}", processed: nil)
      }
    end
    req, provider = scripted_request([text("answer")])
    agent = agent_class(req, tools: []) { self.setup(setup); self.finalize(finalize) }.call(input: "thing")

    assert_equal "Do: thing", agent.goal.task
    assert_equal({ "n" => 1 }, agent.goal.success_criteria)
    assert_equal "Do: thing", provider.calls.first[:messages].first[:content]
    assert_equal "[done] answer", agent.output
    assert_equal :done, seen[:status]
    assert_equal :final_answer, seen[:reason]
    assert_same agent.state, seen[:state]
  end

  def test_setup_rejection_stops_the_agent_and_finalize_still_runs
    setup = Class.new(ActiveHarness::Pipeline) do
      step :validate do
        use ->(input) { ActiveHarness::Result.new(output: "Please clarify", processed: { "ok" => false }) }
        stop_if ->(r) { r.processed["ok"] == false }
      end
    end
    ran = []
    finalize = Class.new(ActiveHarness::Pipeline) do
      step :seen, lambda { |input, context:, params:|
        ran << context[:stop_reason]
        ActiveHarness::Result.new(output: input, processed: nil)
      }
    end
    req, provider = scripted_request([text("never")])
    agent = agent_class(req, tools: []) { self.setup(setup); self.finalize(finalize) }.call(input: "x")

    assert_equal :stopped, agent.status
    assert_equal :setup_rejected, agent.stop_reason
    assert_equal "Please clarify", agent.output
    assert_empty provider.calls
    assert_equal [:setup_rejected], ran
  end

  def test_provider_failure_marks_the_run_failed_and_still_finalizes
    finalize_ran = false
    finalize = Class.new(ActiveHarness::Pipeline) do
      step :seen, lambda { |input, **|
        finalize_ran = true
        ActiveHarness::Result.new(output: input, processed: nil)
      }
    end
    req, = scripted_request([ActiveHarness::Errors::ServerError.new("boom"), ActiveHarness::Errors::ServerError.new("boom")]) do
      model { use provider: :openai, model: "m", retry_attempts: 1 }
    end
    agent = agent_class(req, tools: []) { self.finalize(finalize) }.call(input: "x")

    assert_equal :failed, agent.status
    assert_equal :request_error, agent.stop_reason
    assert_kind_of ActiveHarness::Errors::AllModelsFailed, agent.error
    assert finalize_ran
  end

  def test_tool_hooks_streams_and_trace
    events = []
    req, = scripted_request([tool_call("test__echo", { text: "x" }), text("end")])
    agent = agent_class(req) do
      on(:after_tool) { |call, result| events << [:hook, call.full_name, result.status] }
    end.call(input: "go", stream: ->(source, event, *args) { events << [source, event] if source == :agent })

    assert_includes events, [:hook, "test::echo", :ok]
    assert_includes events, %i[agent before_turn]
    assert_includes events, %i[agent after_tool]
    assert_includes events, %i[agent complete]
    assert_match(/tool test::echo/, agent.trace)
    assert_match(/stop    final_answer/, agent.trace)
  end

  def test_turn_steps_are_named
    req, = scripted_request([tool_call("test__echo", { text: "x" }), text("end")])
    agent = agent_class(req).call(input: "go")
    assert_equal %i[context llm tools limits], agent.turns[0].steps.map { |s| s[:name] }
    assert_equal %i[context llm goal], agent.turns[1].steps.map { |s| s[:name] }
  end

  def test_agent_is_a_pipeline_step
    req, = scripted_request([text("agent says hi")])
    inner = agent_class(req, tools: [])
    pipeline = Class.new(ActiveHarness::Pipeline) do
      step :shout, ->(input) { ActiveHarness::Result.new(output: input.upcase, processed: nil) }
      step :agent, inner
    end.new(input: "hello")
    pipeline.call

    assert_equal "agent says hi", pipeline.output
  end

  def test_no_request_configured
    assert_raises(ArgumentError) { Class.new(ActiveHarness::Agent).call(input: "x") }
  end

  def test_event_journal_keeps_full_details
    req, = scripted_request([tool_call("test__echo", { text: "x" }), text("end")])
    agent = agent_class(req).call(input: "go")
    types = agent.state.events.map { |e| e[:type] }
    assert_equal %i[llm tool_call llm stop], types
    assert_equal({ text: "x" }, agent.state.events[1][:input])
  end
end

class GoalCheckTest < Minitest::Test
  def agent_with(goal_check, script)
    req, = scripted_request(script)
    Class.new(ActiveHarness::Agent) { request req; goal goal_check }
  end

  def test_base_class_raises_until_call_is_defined
    klass = Class.new(ActiveHarness::GoalCheck)
    error = assert_raises(NotImplementedError) { klass.new.call(candidate: "x", goal: nil, state: nil) }
    assert_match(/must define #call/, error.message)

    named = Class.new(ActiveHarness::GoalCheck)
    Object.const_set(:ForgotCallGoal, named)
    assert_match(/ForgotCallGoal must define #call/, assert_raises(NotImplementedError) { named.new.call(candidate: "x", goal: nil, state: nil) }.message)
  ensure
    Object.send(:remove_const, :ForgotCallGoal) if Object.const_defined?(:ForgotCallGoal)
  end

  def test_agent_uses_a_goal_check_subclass
    check = Class.new(ActiveHarness::GoalCheck) do
      def call(candidate:, goal:, state:)
        ActiveHarness::GoalCheckResult.new(status: candidate == "yes" ? :achieved : :continue, feedback: "say yes")
      end
    end
    agent = agent_with(check, [{ content: "no", provider: :s, model: "m" }, { content: "yes", provider: :s, model: "m" }]).call(input: "q")
    assert_equal :goal_reached, agent.stop_reason
    assert_equal "yes", agent.output
  end

  def test_forgotten_call_fails_the_run_with_a_clear_error
    agent = agent_with(Class.new(ActiveHarness::GoalCheck), [{ content: "x", provider: :s, model: "m" }]).call(input: "q")
    assert_equal :failed, agent.status
    assert_equal :runtime_error, agent.stop_reason
    assert_kind_of NotImplementedError, agent.error
  end
end

class ClientGoneTest < Minitest::Test
  def test_matches_io_error_and_ignores_others_without_rails
    refute defined?(::ActionController)
    assert_kind_of ActiveHarness::ClientGone.singleton_class, ActiveHarness::ClientGone
    assert(ActiveHarness::ClientGone === IOError.new)
    refute(ActiveHarness::ClientGone === RuntimeError.new)
    assert_nil((begin; raise IOError; rescue ActiveHarness::ClientGone; end))
  end
end
