require "rails/generators"

module ActiveHarness
  module Generators
    class AgentGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness agent in app/ai/agents/"

      def create_agent
        template "agent.rb.tt",
                 "app/ai/agents/#{file_name}_agent.rb"
      end
    end
  end
end
