require_relative "../concerns/tool_tracing"

# Reads the first lines of a text file inside the workspace. Size and line caps
# keep a single call from flooding the model's context.
class ReadFileTool < ActiveHarness::Tool
  include ActiveHarness::Tool::PathPolicy
  include ToolTracing

  tool_scope :os          # full name: os::read_file
  tool_name  :read_file

  description "Read the first lines of a text file inside the workspace"

  param :path,  "Absolute path of the file"
  # Optional arguments: `required: false`; `type:` is :string by default (also :integer, :boolean, ...);
  # `enum: [...]` limits the allowed values.
  param :lines, "How many lines to read (default 50, max 100)", type: :integer, required: false

  ALLOWED_PATHS = [Rails.root.join("storage").to_s].freeze
  MAX_BYTES     = 200_000
  MAX_LINES     = 100

  # Canonicalize first, then check — validating the raw string would miss symlinks and "..".
  step :resolve_path, transform: true do |input|
    input.merge(path: safe_path!(input[:path]))
  end

  step :no_hidden_files do |input|
    deny!("hidden files are off limits") if input[:path].split("/").any? { |segment| segment.start_with?(".") }
  end

  # `detail:` is for the logs only — the model just learns that the file is too large.
  step :must_be_a_small_file do |input|
    deny!("not a regular file") unless File.file?(input[:path])
    deny!("file is too large", detail: "#{File.size(input[:path])} bytes") if File.size(input[:path]) > MAX_BYTES
  end

  # Anything raised here (other than deny!) becomes a generic "tool failed" for the
  # model; the real error stays in the trace. If a write may have happened but you
  # cannot tell (e.g. a timeout), call unknown_outcome!("...") instead of retrying.
  def perform(input)
    count = [(input[:lines] || 50).to_i, MAX_LINES].min
    File.foreach(input[:path]).first(count).join
  end
end
