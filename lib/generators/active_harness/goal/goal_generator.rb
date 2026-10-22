require "rails/generators"

module ActiveHarness
  module Generators
    class GoalGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness goal check in app/ai/goals/"

      def create_goal
        template "goal.rb.tt",
                 "app/ai/goals/#{file_name}_goal.rb"
      end
    end
  end
end
