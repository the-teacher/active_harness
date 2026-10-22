require_relative "../requests/files_request"
require_relative "../tools/ls_tool"
require_relative "../tools/read_file_tool"
require_relative "../goals/answer_present_goal"
require_relative "../concerns/agent_tracing"

# A tool-calling agent: the model decides which tool to call, the agent validates
# the call, runs the allowed tools and feeds the results back until an answer or a limit.
#
#   agent = FilesAgent.call(input: "What is in the workspace?")
#   agent.output       # final answer
#   agent.stop_reason  # :goal_reached | :max_turns | ...
#   puts agent.trace
class FilesAgent < ActiveHarness::Agent
  include AgentTracing

  # Which Request talks to the model each turn. It owns the model chain, retries and
  # fallback — the agent never repeats a tool call just because a model failed.
  # (Name more than one with `request :cheap, CheapRequest` and pick with `request_for`.)
  request FilesRequest

  # The only tools the model may call. Default deny: any other name is refused as
  # "unknown tool" and never executed, however the model asks.
  tools LsTool, ReadFileTool

  # "The model stopped asking for tools" is not proof the job is done. A goal check
  # judges the final answer and can send the agent back for another turn.
  # Without `goal`, the first answer without tool calls ends the run.
  goal AnswerPresentGoal

  # Hard limits: a model that loops or wanders must not run (or spend) forever.
  # Whichever trips first ends the run with a matching stop_reason.
  max_turns 8        # at most 8 Request calls
  max_cost  0.50     # USD summed over all turns; stops NEW steps, a running call may overshoot

  # Stop early when the model repeats the same tool call with the same input
  # several turns in a row (stop_reason: :repeating).
  loop_guard
end
