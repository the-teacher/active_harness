# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"

module ActiveHarness
  # Provides access to AI model pricing data, filtered to providers supported
  # by ActiveHarness (files present in lib/active_harness/providers/).
  #
  # Data source priority:
  #   1. {project_root}/tmp/active_harness/costs.json — fetched cache (refreshed once per day)
  #   2. lib/active_harness/data/models.json           — bundled fallback (ships with gem)
  #
  # Usage:
  #
  #   # Fetch fresh data and save to tmp cache (also called automatically when stale)
  #   ActiveHarness::Costs.update
  #
  #   # All models (auto-updates cache if missing or older than 24h)
  #   ActiveHarness::Costs.all
  #
  #   # Single model by ID
  #   ActiveHarness::Costs.find("gpt-4o")
  #
  #   # By provider — method or bracket syntax
  #   ActiveHarness::Costs.providers.openai
  #   ActiveHarness::Costs.providers[:anthropic]
  #
  #   # List providers that have data
  #   ActiveHarness::Costs.providers.list
  #
  module Costs
    BUNDLED_DATA_FILE = File.expand_path("data/models.json", __dir__).freeze
    MODELS_DEV_URL    = "https://models.dev/api.json"
    CACHE_TTL         = 86_400 # 24 hours in seconds

    # Maps models.dev provider keys → ActiveHarness provider names.
    # Only entries whose value matches a file in providers/ will be kept.
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

    # Value object representing the pricing for a single model.
    ModelCost = Struct.new(
      :id,
      :name,
      :provider,
      :input_per_million,
      :output_per_million,
      :cache_read_input_per_million,
      :cache_write_input_per_million,
      :context_window,
      :max_output_tokens,
      :input_modalities,
      :output_modalities,
      keyword_init: true
    ) do
      # Returns capability tags derived from modality data and model id/name.
      # Possible values: "vision", "pdf", "audio", "video", "imggen", "embed"
      def categories
        inp = input_modalities  || []
        out = output_modalities || []
        cats = []
        cats << "vision" if inp.include?("image")
        cats << "pdf"    if inp.include?("pdf")
        cats << "audio"  if inp.include?("audio") || out.include?("audio")
        cats << "video"  if inp.include?("video")  || out.include?("video")
        cats << "imggen" if out.include?("image")
        cats << "embed"  if id.to_s.match?(/embed/i) || name.to_s.match?(/embed/i)
        cats
      end

      def inspect
        parts = ["id=#{id.inspect}", "provider=#{provider.inspect}"]
        parts << "input=$#{input_per_million}/M"  if input_per_million
        parts << "output=$#{output_per_million}/M" if output_per_million
        parts << "ctx=#{context_window}"           if context_window
        parts << "cats=#{categories.join(',')}"    if categories.any?
        "#<ModelCost #{parts.join(' ')}>"
      end
    end

    # Proxy object that exposes providers as methods and via [].
    class ProvidersProxy
      def [](name)
        ActiveHarness::Costs.for_provider(name.to_s)
      end

      def list
        ActiveHarness::Costs.provider_names
      end

      def method_missing(name, *args, &block)
        provider = name.to_s
        if ActiveHarness::Costs.provider_names.include?(provider)
          ActiveHarness::Costs.for_provider(provider)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        ActiveHarness::Costs.provider_names.include?(name.to_s) || super
      end
    end

    class << self
      # Returns pricing data for all models from supported providers.
      # Automatically fetches fresh data if the cache is missing or older than 24h.
      def all
        ensure_fresh_registry
        registry.map { |raw| build_cost(raw) }
      end

      # Returns pricing data for a single model by ID, or nil if not found.
      def find(model_id)
        ensure_fresh_registry
        raw = registry.find { |m| m[:id] == model_id.to_s }
        raw ? build_cost(raw) : nil
      end

      # Returns a ProvidersProxy for provider-scoped access.
      def providers
        @providers_proxy ||= ProvidersProxy.new
      end

      # Returns pricing data for all models from the given provider.
      def for_provider(name)
        ensure_fresh_registry
        registry
          .select { |m| m[:provider] == name.to_s }
          .map { |m| build_cost(m) }
      end

      # Returns a sorted list of provider names that have data.
      def provider_names
        @provider_names ||= begin
          ensure_fresh_registry
          registry.map { |m| m[:provider] }.uniq.sort
        end
      end

      # Fetches fresh pricing data from models.dev, filters to supported providers,
      # and writes the result to {project_root}/tmp/active_harness/costs.json.
      # Returns the number of models saved, or raises on HTTP failure.
      def update
        raw_api = fetch_models_dev
        models  = extract_models(raw_api)

        FileUtils.mkdir_p(File.dirname(cache_file))
        File.write(cache_file, JSON.generate(models))

        reload!
        models.size
      end

      # Reloads registry from disk on next access.
      def reload!
        @registry      = nil
        @provider_names = nil
        nil
      end

      # Path to the per-project cache file.
      def cache_file
        File.join(project_root, "tmp", "active_harness", "costs.json")
      end

      # Names of providers supported by ActiveHarness (derived from providers/ directory).
      def available_providers
        @available_providers ||= begin
          providers_dir = File.expand_path("providers", __dir__)
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
        # Network unavailable or update failed — fall back to bundled/stale cache silently
      end

      def cache_file_fresh?
        File.exist?(cache_file) && (Time.now - File.mtime(cache_file)) < CACHE_TTL
      end

      def registry
        @registry ||= load_registry
      end

      def load_registry
        if File.exist?(cache_file)
          begin
            data = JSON.parse(File.read(cache_file), symbolize_names: true)
            return data if data.is_a?(Array)
          rescue JSON::ParserError
            # Cache file corrupted — fall through to bundled data
          end
        end
        JSON.parse(File.read(BUNDLED_DATA_FILE), symbolize_names: true)
      rescue JSON::ParserError, Errno::ENOENT
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

            cost = m[:cost] || {}
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
        ModelCost.new(
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
