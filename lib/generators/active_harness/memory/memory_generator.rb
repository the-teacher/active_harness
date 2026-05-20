require "rails/generators"

module ActiveHarness
  module Generators
    class MemoryGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness memory class in app/ai/memory/"

      def create_memory
        template "memory.rb.tt",
                 "app/ai/memory/#{file_name}_memory.rb"
      end
    end
  end
end
