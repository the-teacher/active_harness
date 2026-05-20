module ActiveHarness
  class Railtie < Rails::Railtie
    APP_AI_DIRS = %w[agents prompts tribunals pipelines memory].freeze

    initializer "active_harness.autoload_paths" do |app|
      APP_AI_DIRS.each do |dir|
        path = Rails.root.join("app", "ai", dir)
        app.config.autoload_paths << path.to_s if path.exist?
      end
    end
  end
end
