require "rails/generators"

module ActiveHarness
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc "Creates the app/ai/ directory structure for ActiveHarness"

      source_root File.expand_path("templates", __dir__)

      APP_AI_DIRS = %w[agents prompts tribunals pipelines memory].freeze

      def create_structure
        APP_AI_DIRS.each do |dir|
          empty_directory "app/ai/#{dir}"
          copy_templates_if_empty(dir)
        end
      end

      def copy_controller
        target = File.join(destination_root, "app", "controllers", "ai_support_controller.rb")
        return if File.exist?(target)

        copy_file "controllers/ai_controller.rb",
                  "app/controllers/ai_support_controller.rb"
      end

      def inject_routes
        route <<~ROUTES.strip
          # ActiveHarness — AI support endpoints
          post "ai/agent",        to: "ai_support#agent"
          post "ai/agent_memory", to: "ai_support#agent_memory"
          post "ai/tribunal",     to: "ai_support#tribunal"
          post "ai/pipeline",     to: "ai_support#pipeline"
          get  "ai/agent_stream", to: "ai_support#agent_stream"
        ROUTES
      end

      private

      def copy_templates_if_empty(dir)
        target_dir = File.join(destination_root, "app", "ai", dir)
        return if Dir.glob(File.join(target_dir, "*.rb")).any?

        template_dir = File.join(self.class.source_root, dir)
        return unless Dir.exist?(template_dir)

        Dir[File.join(template_dir, "*.rb")].sort.each do |tpl|
          copy_file File.join(dir, File.basename(tpl)),
                    File.join("app", "ai", dir, File.basename(tpl))
        end
      end
    end
  end
end
