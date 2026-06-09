require_relative "active_harness/configuration"
require_relative "active_harness/core/errors"
require_relative "active_harness/core/hooks"
require_relative "active_harness/result"
require_relative "active_harness/http/client"
require_relative "active_harness/http/streaming_client"
require_relative "active_harness/http/retry_policy"
require_relative "active_harness/providers/base"
require_relative "active_harness/providers/openai"
require_relative "active_harness/providers/openrouter"
require_relative "active_harness/providers/groq"
require_relative "active_harness/providers/gemini"
require_relative "active_harness/providers/anthropic"
require_relative "active_harness/providers/xai"
require_relative "active_harness/providers/deepseek"
require_relative "active_harness/providers/mistral"
require_relative "active_harness/providers/ollama"
require_relative "active_harness/providers/perplexity"
require_relative "active_harness/providers/gpustack"
require_relative "active_harness/providers/azure"
require_relative "active_harness/providers/bedrock"
require_relative "active_harness/providers/vertexai"
require_relative "active_harness/providers/custom"
require_relative "active_harness/costs"
require_relative "active_harness/memory"
require_relative "active_harness/agent"
require_relative "active_harness/tribunal"
require_relative "active_harness/pipeline"

require_relative "active_harness/railtie" if defined?(Rails::Railtie)

module ActiveHarness
  VERSION = "0.2.23"

  class << self
    # Configure ActiveHarness.
    #
    #   ActiveHarness.configure do |config|
    #     config.openai_api_key = ENV["OPENAI_API_KEY"]
    #     config.openai_api_url = "https://api.openai.com/v1/chat/completions"
    #   end
    def configure
      yield config
    end

    # Returns the singleton Configuration instance.
    # Lazily initialized on first access.
    def config
      @config ||= Configuration.new
    end

    # Reset config to defaults (useful in tests).
    def reset_config!
      @config = nil
    end
  end
end
