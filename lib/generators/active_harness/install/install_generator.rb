require "rails/generators"

module ActiveHarness
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc "Creates the app/ai/ directory structure for ActiveHarness.\n" \
           "Safe to re-run: existing files are never touched, only missing example files are added."

      source_root File.expand_path("templates", __dir__)

      ROUTES = {
        "ai/agent"          => 'post "ai/agent",          to: "ai_support#agent" # not "request" — would override ActionController::Base#request',
        "ai/request_memory" => 'post "ai/request_memory", to: "ai_support#request_memory"',
        "ai/tribunal"       => 'post "ai/tribunal",       to: "ai_support#tribunal"',
        "ai/pipeline"       => 'post "ai/pipeline",       to: "ai_support#pipeline"',
        "ai/files_agent"    => 'post "ai/files_agent",    to: "ai_support#files_agent"',
        "ai/request_stream" => 'get  "ai/request_stream", to: "ai_support#request_stream"'
      }.freeze

      APP_AI_DIRS = %w[concerns requests prompts tribunals pipelines memory agents tools goals].freeze

      def create_structure
        APP_AI_DIRS.each do |dir|
          empty_directory "app/ai/#{dir}"
          copy_missing_templates(dir)
        end
      end

      def create_initializer
        target = File.join(destination_root, "config", "initializers", "active_harness.rb")
        return if File.exist?(target)

        copy_file "initializers/active_harness.rb",
                  "config/initializers/active_harness.rb"
      end

      def copy_controller
        target = File.join(destination_root, "app", "controllers", "ai_support_controller.rb")
        return if File.exist?(target)

        copy_file "controllers/ai_controller.rb",
                  "app/controllers/ai_support_controller.rb"
      end

      # Adds only the routes that are not in config/routes.rb yet, so re-running is harmless.
      def inject_routes
        routes_file = File.join(destination_root, "config", "routes.rb")
        existing    = File.exist?(routes_file) ? File.read(routes_file) : ""
        missing     = ROUTES.reject { |path, _line| existing.include?(%("#{path}")) }
        return if missing.empty?

        route(["# ActiveHarness — AI support endpoints", *missing.map { |_path, line| line }].join("\n"))
      end

      private

      # Per-file, never overwrites: a template is copied only when its target does not exist.
      # Examples depend on each other (agent -> request/tools/goal/concerns), so a missing
      # piece is added even when its directory already holds the user's own files.
      def copy_missing_templates(dir)
        template_dir = File.join(self.class.source_root, dir)
        return unless Dir.exist?(template_dir)

        Dir[File.join(template_dir, "*.rb")].sort.each do |tpl|
          relative = File.join("app", "ai", dir, File.basename(tpl))
          if File.exist?(File.join(destination_root, relative))
            say_status :skip, "#{relative} (exists)", :yellow
          else
            copy_file File.join(dir, File.basename(tpl)), relative
          end
        end
      end
    end
  end
end
