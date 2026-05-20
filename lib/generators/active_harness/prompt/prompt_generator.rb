require "rails/generators"

module ActiveHarness
  module Generators
    class PromptGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness prompt in app/ai/prompts/"

      def create_prompt
        template "prompt.rb.tt",
                 "app/ai/prompts/#{file_name}_prompt.rb"
      end
    end
  end
end
