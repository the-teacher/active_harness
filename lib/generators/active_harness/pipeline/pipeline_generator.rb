require "rails/generators"

module ActiveHarness
  module Generators
    class PipelineGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates an ActiveHarness pipeline in app/ai/pipelines/"

      def create_pipeline
        template "pipeline.rb.tt",
                 "app/ai/pipelines/#{file_name}_pipeline.rb"
      end
    end
  end
end
