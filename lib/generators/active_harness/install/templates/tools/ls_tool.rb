require_relative "../concerns/tool_tracing"

# A safe directory listing: the model can only see inside ALLOWED_PATHS.
class LsTool < ActiveHarness::Tool
  include ActiveHarness::Tool::PathPolicy   # safe_path!: resolves symlinks and ".." and checks ALLOWED_PATHS
  include ToolTracing                        # logs every step; see app/ai/concerns/

  # `tool_scope` namespaces the tool (os::ls vs web::ls) and lets you allow or log a whole group;
  # `tool_name` is the name the model sees. Both are explicit: renaming the class changes nothing for the model.
  tool_scope :os
  tool_name  :ls

  # What the model reads when it decides whether to call this tool — write it for the model.
  description "List files in a directory inside the workspace"

  # An argument the model must provide. `param` only DESCRIBES it to the model; the
  # agent rejects missing or unknown arguments, and the checks below do the real policing.
  param :path, "Directory to list (absolute path inside the workspace)"

  # Fail closed: PathPolicy raises if a tool using it forgets to define this.
  ALLOWED_PATHS = [Rails.root.join("storage").to_s].freeze

  # Steps run in order BEFORE #perform. `transform: true` means the return value
  # replaces the input for every later step and for #perform — so after this step the
  # tool only ever sees a canonical path inside ALLOWED_PATHS.
  step :resolve_path, transform: true do |input|
    input.merge(path: safe_path!(input[:path]))
  end

  # A plain check: refuse with deny!. The text goes back to the model so it can adjust;
  # pass `detail:` for anything that must stay in the logs only.
  step :no_hidden_dirs do |input|
    deny!("hidden dirs are off limits") if input[:path].split("/").any? { |segment| segment.start_with?(".") }
  end

  # The action itself — always last; its return value is what the model gets back.
  # Cap the output: a huge result floods the model's context.
  def perform(input)
    Dir.children(input[:path]).first(200)
  end
end
