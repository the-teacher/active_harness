# A goal check judges the agent's final answer. Subclass ActiveHarness::GoalCheck and
# override #call(candidate:, goal:, state:) to return a GoalCheckResult; plug it in with
# `goal AnswerPresentGoal` in the agent. (The base class only raises a clear error if you
# forget #call — any object with that method works too.)
#
#   candidate — the answer the model proposed
#   goal      — what was asked (goal.task, goal.success_criteria)
#   state     — the whole run (messages, events, tool calls) as evidence
#
# Prefer deterministic checks (tests, schemas, counts) to asking an LLM.
class AnswerPresentGoal < ActiveHarness::GoalCheck
  def call(candidate:, goal:, state:)
    if candidate.to_s.strip.empty?
      # :continue — the feedback is sent to the model and the agent takes another turn
      # (at most `max_goal_retries`, default 2, then the run stops with :goal_failed).
      # Other statuses: :achieved, :replan, :needs_input, :failed.
      ActiveHarness::GoalCheckResult.new(status: :continue, feedback: "The answer is empty. Answer the question.")
    else
      ActiveHarness::GoalCheckResult.new(status: :achieved)
    end
  end
end
