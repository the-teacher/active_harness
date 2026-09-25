require "rails/generators"

module ActiveHarness
  module Generators
    class RequestGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness request in app/ai/requests/"

      def create_request
        template "request.rb.tt",
                 "app/ai/requests/#{file_name}_request.rb"
      end
    end
  end
end
