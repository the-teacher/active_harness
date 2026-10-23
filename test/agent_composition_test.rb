require "test_helper"

# Agent composed from the existing pieces: Request / Tribunal / Pipeline as setup, goal, finalize.
class AgentCompositionTest < Minitest::Test
  def agent_class(request, tools: [], &block)
    Class.new(ActiveHarness::Agent) do
      self.request(request)
      self.tools(*tools) unless tools.empty?
      class_eval(&block) if block
    end
  end

  def tribunal_of(*scripts, strategy: :unanimous)
    requests = scripts.map { |script| scripted_request(script).first }
    Class.new(ActiveHarness::Tribunal) do
      self.requests(*requests)
      verdict strategy do |result|
        result.output.to_s.start_with?("yes")
      end
    end
  end

  # --- goal: Tribunal / Request directly ---

  def test_tribunal_as_goal_achieved_and_its_cost_is_counted
    main, = scripted_request([text("the answer", cost: 0.01)])
    judges = tribunal_of([text("yes", cost: 0.002)], [text("yes, fine", cost: 0.003)])
    agent = agent_class(main) { goal judges }.call(input: "q")

    assert_equal :goal_reached, agent.stop_reason
    assert_equal "the answer", agent.output
    assert_in_delta 0.015, agent.usage.cost.total, 1e-9
    assert(agent.state.events.any? { |e| e[:type] == :nested_usage && e[:source] == :goal })
  end

  def test_tribunal_as_goal_not_approved_sends_feedback_and_continues
    main, provider = scripted_request([text("draft"), text("better")])
    judges = tribunal_of([text("no: too short"), text("yes")], [text("no: unclear"), text("yes")])
    agent = agent_class(main) { goal judges }.call(input: "q")

    assert_equal :goal_reached, agent.stop_reason
    assert_equal 2, agent.turns.size
    feedback = provider.calls.last[:messages].last[:content]
    assert_match(/Goal not reached: no: too short; no: unclear/, feedback)
  end

  def test_request_as_goal
    main, = scripted_request([text("answer")])
    judge, = scripted_request([text("yes", cost: 0.004)])
    agent = agent_class(main) { goal judge }.call(input: "q")

    assert_equal :goal_reached, agent.stop_reason
    assert_in_delta 0.004, agent.usage.cost.total, 1e-9
  end

  # --- setup / finalize: any executor, cost counted ---

  def test_setup_and_finalize_accept_a_bare_request_and_their_cost_counts
    setup, = scripted_request([text('{"task":"Do the thing"}', cost: 0.001)]) { format :json }
    final, = scripted_request([text("FINAL: shaped", cost: 0.002)])
    main, provider = scripted_request([text("raw answer", cost: 0.01)])
    agent = agent_class(main) { self.setup(setup); self.finalize(final) }.call(input: "thing")

    assert_equal :done, agent.status
    assert_equal "Do the thing", agent.goal.task
    assert_equal "Do the thing", provider.calls.first[:messages].last[:content]
    assert_equal "FINAL: shaped", agent.output
    assert_in_delta 0.013, agent.usage.cost.total, 1e-9
  end

  def test_setup_cost_counts_toward_max_cost
    setup, = scripted_request([text('{"task":"t"}', cost: 0.5)]) { format :json }
    main, = scripted_request([text("never asked")])
    agent = agent_class(main) { self.setup(setup); max_cost 0.1 }.call(input: "x")

    assert_equal :stopped, agent.status
    assert_equal :max_cost, agent.stop_reason
  end

  def test_finalize_receives_processed_of_the_last_request
    seen = nil
    final = Class.new(ActiveHarness::Pipeline) do
      step :keep, ->(input, context:, params:) { seen = context[:processed]; ActiveHarness::Result.new(output: input, processed: input) }
    end
    main, = scripted_request([text('{"a":1}')]) { format :json }
    agent_class(main) { self.finalize(final) }.call(input: "x")

    assert_equal({ "a" => 1 }, seen)
  end

  def test_finalize_error_is_readable_and_fires_a_hook
    fired = []
    final = Class.new(ActiveHarness::Pipeline) do
      step :boom, ->(_input) { raise "finalize broke" }
    end
    main, = scripted_request([text("ok")])
    agent = agent_class(main) { self.finalize(final); on(:finalize_error) { |e| fired << e.message } }.call(input: "x")

    assert_equal :done, agent.status
    assert_equal :final_answer, agent.stop_reason
    assert_equal "finalize broke", agent.finalize_error.message
    assert_equal ["finalize broke"], fired
  end

  # --- result and composition ---

  def test_result_carries_status_and_stop_reason
    main, = scripted_request([text("hi")])
    agent = agent_class(main).call(input: "x")

    assert_equal({ status: :done, stop_reason: :final_answer, run_id: agent.run_id }, agent.result.meta)
  end

  def test_agent_as_a_pipeline_step_with_class_level_agent_events
    main, = scripted_request([text("agent says hi", cost: 0.01)])
    agent_klass = agent_class(main)
    events = []
    pipeline = Class.new(ActiveHarness::Pipeline) do
      step :agent, agent_klass
      on_agent_event { |event, *| events << event }
    end
    p = pipeline.new(input: "x").call

    assert_equal "agent says hi", p.output
    assert_equal({ status: :done, stop_reason: :final_answer }, p.steps.to_a.first[2].meta.slice(:status, :stop_reason))
    assert_includes events, :before_turn
    assert_includes events, :complete
  end
end
