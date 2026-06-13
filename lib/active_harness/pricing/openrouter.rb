require "json"
require "net/http"
require "uri"
require "fileutils"

module ActiveHarness
  module Pricing
    # Fetches image-model pricing directly from the OpenRouter API.
    #
    # models.dev only has generic prompt/completion rates for OpenRouter models.
    # OpenRouter's own /endpoints API exposes a separate `image_output` rate
    # that reflects the real cost of image generation tokens.
    #
    # Data flow:
    #   1. GET /api/v1/models?output_modalities=image  → list of image models
    #   2. GET /api/v1/models/{id}/endpoints           → per-model, picks first
    #      active endpoint to get image_output rate
    #   3. Result cached to tmp/active_harness/pricing_openrouter.json for 24h
    #
    # Usage:
    #   Pricing::OpenRouter.find("openai/gpt-5-image-mini")  # → ModelPrice or nil
    #   Pricing::OpenRouter.update                           # force refresh
    module OpenRouter
      API_BASE  = "https://openrouter.ai/api/v1/models"
      CACHE_TTL = 86_400

      class << self
        # Returns a ModelPrice for the given OpenRouter model id, or nil.
        # Automatically refreshes the cache if missing or stale.
        def find(model_id)
          ensure_fresh_registry
          raw = registry.find { |m| m[:id] == model_id.to_s }
          raw ? build_price(raw) : nil
        end

        # Fetches fresh data from OpenRouter and writes the cache.
        # Returns the number of models saved.
        def update
          image_models = fetch_image_models
          enriched = image_models.map { |m| enrich_with_endpoint(m) }

          FileUtils.mkdir_p(File.dirname(cache_file))
          File.write(cache_file, JSON.generate(enriched))
          reload!
          enriched.size
        end

        def reload!
          @registry = nil
        end

        def cache_file
          File.join(project_root, "tmp", "active_harness", "pricing_openrouter.json")
        end

        private

        def ensure_fresh_registry
          return if cache_fresh?
          update
        rescue StandardError
          # network unavailable — fall back to stale cache silently
        end

        def cache_fresh?
          File.exist?(cache_file) && (Time.now - File.mtime(cache_file)) < CACHE_TTL
        end

        def registry
          @registry ||= begin
            return [] unless File.exist?(cache_file)
            JSON.parse(File.read(cache_file), symbolize_names: true)
          rescue JSON::ParserError
            []
          end
        end

        # Fetch all models with image output from OpenRouter.
        def fetch_image_models
          uri = URI("#{API_BASE}?output_modalities=image")
          response = http_get(uri)
          data = JSON.parse(response.body, symbolize_names: true)
          data[:data] || []
        end

        # Fetch /endpoints for the model and merge image_output pricing.
        def enrich_with_endpoint(model)
          model_id = model[:id]
          base_pricing = model[:pricing] || {}

          endpoint_pricing = fetch_endpoint_pricing(model_id)

          {
            id:               model_id,
            name:             model[:name],
            input_modalities:  model.dig(:architecture, :input_modalities)  || [],
            output_modalities: model.dig(:architecture, :output_modalities) || [],
            prompt:            base_pricing[:prompt].to_s,
            completion:        base_pricing[:completion].to_s,
            image_output:      endpoint_pricing&.dig(:image_output).to_s,
            image:             endpoint_pricing&.dig(:image).to_s,
            cache_read:        (endpoint_pricing&.dig(:input_cache_read) || base_pricing[:input_cache_read]).to_s
          }
        end

        # Returns the pricing hash from the first active endpoint, or nil.
        def fetch_endpoint_pricing(model_id)
          uri = URI("#{API_BASE}/#{model_id}/endpoints")
          response = http_get(uri)
          data = JSON.parse(response.body, symbolize_names: true)
          endpoints = data.dig(:data, :endpoints) || []

          # Prefer the first endpoint with status == 0 (online), else first available.
          ep = endpoints.find { |e| e[:status] == 0 } || endpoints.first
          ep&.dig(:pricing)
        rescue StandardError
          nil
        end

        # Build a ModelPrice compatible with the rest of the Pricing system.
        # For image-output models, uses image_output rate for output_per_million.
        def build_price(raw)
          is_image_output = Array(raw[:output_modalities]).include?("image")

          input_pm      = to_per_million(raw[:prompt])
          completion_pm = to_per_million(raw[:completion])
          image_out_pm  = to_per_million(raw[:image_output])
          cache_pm      = to_per_million(raw[:cache_read])

          output_pm = (is_image_output && image_out_pm) ? image_out_pm : completion_pm

          return nil unless input_pm || output_pm

          Pricing::ModelPrice.new(
            id:                           raw[:id],
            name:                         raw[:name],
            provider:                     "openrouter",
            input_per_million:            input_pm,
            output_per_million:           output_pm,
            cache_read_input_per_million: cache_pm,
            cache_write_input_per_million: nil,
            context_window:               nil,
            max_output_tokens:            nil,
            input_modalities:             Array(raw[:input_modalities]),
            output_modalities:            Array(raw[:output_modalities])
          )
        end

        # OpenRouter pricing fields are per-token strings (e.g. "0.000008").
        # Convert to per-million float. Returns nil for zero/blank values.
        def to_per_million(value)
          return nil if value.nil? || value.to_s.empty?
          f = value.to_f
          return nil if f <= 0
          (f * 1_000_000).round(6)
        end

        def http_get(uri)
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 10) do |http|
            http.get(uri.request_uri)
          end
          raise "OpenRouter API returned HTTP #{response.code} for #{uri}" unless response.is_a?(Net::HTTPSuccess)
          response
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
