require "json"
require "net/http"
require "uri"
require "fileutils"
require "set"

module ActiveHarness
  module Pricing
    # Fallback pricing source — fetches model data from models.dev.
    #
    # Data source:
    #   {project_root}/tmp/active_harness/pricing_models_dev.json — fetched cache (24h TTL)
    #   Returns nil/empty if cache is missing and network is unavailable.
    #
    # Usage:
    #   Pricing::ModelsDev.find("gpt-4o")
    #   Pricing::ModelsDev.all
    #   Pricing::ModelsDev.update
    module ModelsDev
      MODELS_DEV_URL = "https://models.dev/api.json"
      CACHE_TTL         = 86_400

      MODELS_DEV_PROVIDER_MAP = {
        "openai"         => "openai",
        "anthropic"      => "anthropic",
        "google"         => "gemini",
        "google-vertex"  => "vertexai",
        "amazon-bedrock" => "bedrock",
        "deepseek"       => "deepseek",
        "mistral"        => "mistral",
        "openrouter"     => "openrouter",
        "perplexity"     => "perplexity",
        "xai"            => "xai",
        "groq"           => "groq",
        "azure"          => "azure"
      }.freeze

      class << self
        def all
          ensure_fresh_registry
          registry.map { |raw| build_cost(raw) }
        end

        def find(model_id)
          ensure_fresh_registry
          raw = registry.find { |m| m[:id] == model_id.to_s }
          raw ? build_cost(raw) : nil
        end

        def providers
          @providers_proxy ||= Pricing::ProvidersProxy.new(self)
        end

        def for_provider(name)
          ensure_fresh_registry
          registry
            .select { |m| m[:provider] == name.to_s }
            .map { |m| build_cost(m) }
        end

        def provider_names
          @provider_names ||= begin
            ensure_fresh_registry
            registry.map { |m| m[:provider] }.uniq.sort
          end
        end

        def update
          raw_api = fetch_models_dev
          models  = extract_models(raw_api)

          FileUtils.mkdir_p(File.dirname(cache_file))
          File.write(cache_file, JSON.generate(models))

          reload!
          models.size
        end

        def reload!
          @registry       = nil
          @provider_names = nil
          nil
        end

        def cache_file
          File.join(project_root, "tmp", "active_harness", "pricing_models_dev.json")
        end

        def available_providers
          @available_providers ||= begin
            providers_dir = File.expand_path("../providers", __dir__)
            Dir.glob("#{providers_dir}/*.rb")
              .map { |f| File.basename(f, ".rb") }
              .reject { |n| %w[base custom].include?(n) }
          end
        end

        private

        def ensure_fresh_registry
          return if cache_file_fresh?
          update
        rescue StandardError
          # Network unavailable — fall back to bundled/stale cache silently
        end

        def cache_file_fresh?
          File.exist?(cache_file) && (Time.now - File.mtime(cache_file)) < CACHE_TTL
        end

        def registry
          @registry ||= load_registry
        end

        def load_registry
          return [] unless File.exist?(cache_file)
          data = JSON.parse(File.read(cache_file), symbolize_names: true)
          data.is_a?(Array) ? data : []
        rescue JSON::ParserError
          []
        end

        def fetch_models_dev
          uri      = URI(MODELS_DEV_URL)
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.get(uri.request_uri)
          end
          raise "models.dev returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body, symbolize_names: true)
        end

        def extract_models(raw_api)
          allowed = available_providers.to_set

          raw_api.flat_map do |provider_key, provider_data|
            ah_provider = MODELS_DEV_PROVIDER_MAP[provider_key.to_s]
            next [] unless ah_provider && allowed.include?(ah_provider)

            models_hash = provider_data.is_a?(Hash) ? (provider_data[:models] || {}) : {}
            models_hash.values.filter_map do |m|
              next unless m.is_a?(Hash) && m[:id]

              cost     = m[:cost] || {}
              standard = {
                input_per_million:             cost[:input],
                output_per_million:            cost[:output],
                cache_read_input_per_million:  cost[:cache_read],
                cache_write_input_per_million: cost[:cache_write]
              }.compact

              mods = m[:modalities] || {}
              {
                id:                m[:id],
                name:              m[:name] || m[:id],
                provider:          ah_provider,
                context_window:    m[:context_window] || m.dig(:limit, :context),
                max_output_tokens: m[:max_output_tokens] || m.dig(:limit, :output),
                input_modalities:  Array(mods[:input]),
                output_modalities: Array(mods[:output]),
                pricing:           standard.any? ? { text_tokens: { standard: standard } } : {}
              }
            end
          end
        end

        def build_cost(raw)
          standard = raw.dig(:pricing, :text_tokens, :standard) || {}
          Pricing::ModelPrice.new(
            id:                            raw[:id],
            name:                          raw[:name],
            provider:                      raw[:provider],
            input_per_million:             standard[:input_per_million],
            output_per_million:            standard[:output_per_million],
            cache_read_input_per_million:  standard[:cache_read_input_per_million],
            cache_write_input_per_million: standard[:cache_write_input_per_million],
            context_window:                raw[:context_window],
            max_output_tokens:             raw[:max_output_tokens],
            input_modalities:              Array(raw[:input_modalities]),
            output_modalities:             Array(raw[:output_modalities])
          )
        end

        def project_root
          if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
            Rails.root.to_s
          else
            Dir.pwd
          end
        end
      end
    end
  end
end
