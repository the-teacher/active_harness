require_relative "active_harness/core/errors"
require_relative "active_harness/result"
require_relative "active_harness/http/client"
require_relative "active_harness/http/streaming_client"
require_relative "active_harness/providers/base"
require_relative "active_harness/providers/openai"
require_relative "active_harness/providers/openrouter"
require_relative "active_harness/providers/groq"
require_relative "active_harness/providers/gemini"
require_relative "active_harness/providers/anthropic"
require_relative "active_harness/memory"
require_relative "active_harness/agent"
require_relative "active_harness/tribunal"
require_relative "active_harness/pipeline"

module ActiveHarness
  VERSION = "0.2.0"
end
