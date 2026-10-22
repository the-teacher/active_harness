require "rails/generators"

module ActiveHarness
  module Generators
    class ToolGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness tool in app/ai/tools/"

      def create_tool
        template "tool.rb.tt",
                 "app/ai/tools/#{file_name}_tool.rb"
      end
    end
  end
end
