require "rails/generators"

module ActiveHarness
  module Generators
    class TribunalGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness tribunal in app/ai/tribunals/"

      def create_tribunal
        template "tribunal.rb.tt",
                 "app/ai/tribunals/#{file_name}_tribunal.rb"
      end
    end
  end
end
