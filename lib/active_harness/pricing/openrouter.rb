require "json"
require "net/http"
require "uri"
require "fileutils"

module ActiveHarness
  module Pricing
    # Fetches complete pricing for all OpenRouter models across all modalities.
    #
    # OpenRouter exposes models via several endpoints:
    #   GET /api/v1/models                          → 337 text models (base)
    #   GET /api/v1/models?output_modalities=image  → 32 image-gen models (25 extra)
    #   GET /api/v1/models?output_modalities=embeddings    → 26 models (all extra)
    #   GET /api/v1/models?output_modalities=speech        →  9 models (all extra)
    #   GET /api/v1/models?output_modalities=transcription → 10 models (all extra)
    #   GET /api/v1/models?output_modalities=video         → 14 models (all zero pricing)
    #   GET /api/v1/models?output_modalities=rerank        →  4 models (all zero pricing)
    #
    # For image-output models, /api/v1/models/{id}/endpoints is also fetched
    # to get the accurate `image_output` per-token rate.
    #
    # All models are merged by id; pricing fields are populated per-modality:
    #   text_input / text_output — text tokens
    #   image_input              — image tokens accepted as input (vision)
    #   image_output             — image generation tokens (from /endpoints)
    #   audio_input              — audio tokens as input
    #   audio_output             — audio tokens as output (TTS)
    #   cache_read / cache_write — cache tokens
    #   web_search               — per web-search request
    #
    # Usage:
    #   Pricing::OpenRouter.find("openai/gpt-5-image-mini")  # → ModelPrice or nil
    #   Pricing::OpenRouter.all                              # → Array<ModelPrice>
    #   Pricing::OpenRouter.update                           # force refresh
    module OpenRouter
      API_BASE   = "https://openrouter.ai/api/v1/models"
      MEMORY_TTL = 3 * 86_400  # 3 days

      # Modalities that have models outside the base text-337 set.
      EXTRA_MODALITIES = %w[image embeddings speech transcription video rerank].freeze

      class << self
        def find(model_id)
          ensure_fresh_registry
          raw = registry.find { |m| m[:id] == model_id.to_s }
          raw ? build_price(raw) : nil
        end

        def all
          ensure_fresh_registry
          registry.filter_map { |raw| build_price(raw) }
        end

        def preload!
          update
        rescue StandardError
          nil
        ensure
          @registry  = load_registry
          @loaded_at = @registry.empty? ? nil : Time.now
        end

        def update
          entries = collect_all_models
          FileUtils.mkdir_p(File.dirname(cache_file))
          File.write(cache_file, JSON.generate(entries))
          entries.size
        end

        def reload!
          @registry  = nil
          @loaded_at = nil
        end

        def cache_file
          File.join(project_root, "tmp", "active_harness", "openrouter_pricing.json")
        end

        private

        # ── Freshness ────────────────────────────────────────────────────

        def ensure_fresh_registry
          return if memory_fresh?
          unless file_fresh?
            begin
              update
            rescue StandardError
              nil
            end
          end
          @registry  = load_registry
          @loaded_at = @registry.empty? ? nil : Time.now
        end

        def memory_fresh?
          @loaded_at && (Time.now - @loaded_at) < MEMORY_TTL
        end

        def file_fresh?
          File.exist?(cache_file) && (Time.now - File.mtime(cache_file)) < MEMORY_TTL
        end

        def registry
          @registry ||= []
        end

        def load_registry
          return [] unless File.exist?(cache_file)
          data = JSON.parse(File.read(cache_file), symbolize_names: true)
          data.is_a?(Array) ? data : []
        rescue JSON::ParserError
          []
        end

        # ── Data collection ──────────────────────────────────────────────

        # Fetches all modality endpoints, merges by id, enriches image models.
        def collect_all_models
          models = {}

          # Base text models
          fetch_models(API_BASE).each do |m|
            models[m[:id]] = normalize(m)
          end

          # Specialized modalities — add extra models and merge pricing
          EXTRA_MODALITIES.each do |mod|
            fetch_models("#{API_BASE}?output_modalities=#{mod}").each do |m|
              id = m[:id]
              if models[id]
                merge_pricing!(models[id], m)
              else
                models[id] = normalize(m)
              end
            end
          end

          # Enrich image-output models with /endpoints for accurate image_output rate
          models.values.map do |entry|
            if Array(entry[:output_modalities]).include?("image")
              enrich_with_endpoint(entry)
            else
              entry
            end
          end
        end

        # Normalize a raw API model hash into our cache entry format.
        def normalize(m)
          p = m[:pricing] || {}
          {
            id:                m[:id],
            name:              m[:name],
            input_modalities:  m.dig(:architecture, :input_modalities)  || [],
            output_modalities: m.dig(:architecture, :output_modalities) || [],
            text_input:        p[:prompt].to_s,
            text_output:       p[:completion].to_s,
            image_input:       p[:image].to_s,
            audio_input:       p[:audio].to_s,
            image_output:      "",
            audio_output:      "",
            cache_read:        p[:input_cache_read].to_s,
            cache_write:       p[:input_cache_write].to_s,
            web_search:        p[:web_search].to_s
          }
        end

        # Merge non-zero pricing fields from a new API response into existing entry.
        def merge_pricing!(entry, raw_model)
          p = raw_model[:pricing] || {}
          [
            [:text_input,  p[:prompt]],
            [:text_output, p[:completion]],
            [:image_input, p[:image]],
            [:audio_input, p[:audio]],
            [:cache_read,  p[:input_cache_read]],
            [:cache_write, p[:input_cache_write]],
            [:web_search,  p[:web_search]]
          ].each do |key, val|
            entry[key] = val.to_s if val.to_f > 0 && entry[key].to_f == 0
          end

          # Merge modalities (union)
          new_out = raw_model.dig(:architecture, :output_modalities) || []
          entry[:output_modalities] = (Array(entry[:output_modalities]) | new_out).uniq
          new_in  = raw_model.dig(:architecture, :input_modalities)  || []
          entry[:input_modalities]  = (Array(entry[:input_modalities])  | new_in).uniq
        end

        # Fetch /endpoints and add image_output rate to the entry.
        def enrich_with_endpoint(entry)
          pricing = fetch_endpoint_pricing(entry[:id])
          entry[:image_output] = pricing&.dig(:image_output).to_s
          entry[:audio_output] = pricing&.dig(:audio_output).to_s
          entry
        rescue StandardError
          entry
        end

        def fetch_endpoint_pricing(model_id)
          uri = URI("#{API_BASE}/#{model_id}/endpoints")
          resp = http_get(uri)
          data = JSON.parse(resp.body, symbolize_names: true)
          endpoints = data.dig(:data, :endpoints) || []
          ep = endpoints.find { |e| e[:status] == 0 } || endpoints.first
          ep&.dig(:pricing)
        rescue StandardError
          nil
        end

        def fetch_models(url)
          resp = http_get(URI(url))
          data = JSON.parse(resp.body, symbolize_names: true)
          data[:data] || []
        end

        # ── Build ModelPrice ─────────────────────────────────────────────

        def build_price(raw)
          out_mods = Array(raw[:output_modalities])
          inp_mods = Array(raw[:input_modalities])

          is_imggen        = out_mods.include?("image")
          is_embed         = out_mods.include?("embeddings")
          is_speech        = out_mods.include?("speech")
          is_transcription = out_mods.include?("transcription")

          text_in_pm  = to_pm(raw[:text_input])
          text_out_pm = to_pm(raw[:text_output])
          img_in_pm   = to_pm(raw[:image_input])
          img_out_pm  = to_pm(raw[:image_output])
          # p[:audio] field — audio input tokens (multimodal/embedding models like Gemini)
          audio_in_pm = to_pm(raw[:audio_input])
          aud_out_pm  = to_pm(raw[:audio_output])
          cache_r_pm  = to_pm(raw[:cache_read])
          cache_w_pm  = to_pm(raw[:cache_write])
          # web_search is a flat per-request fee in USD, not a per-token rate
          ws_raw         = raw[:web_search].to_s
          web_search_usd = ws_raw.empty? ? nil : (ws_raw.to_f > 0 ? ws_raw.to_f : nil)

          # Transcription pricing is stored in `prompt` but the unit differs by model:
          #   prompt < 0.0001  → per-audio-token  (e.g. gpt-4o-transcribe $2.5/M)  → use to_pm
          #   prompt >= 0.0001 → per-minute of audio (e.g. Whisper $0.006/min)      → raw USD
          if is_transcription
            raw_rate = raw[:text_input].to_s.to_f
            audio_in_pm = if raw_rate > 0 && raw_rate < 0.0001
              to_pm(raw[:text_input])    # per-token → convert to per-million
            elsif raw_rate > 0
              raw_rate                   # per-minute → keep raw USD value
            end
            text_in_pm = nil
          end

          # Primary output for cost calculation and sorting:
          # imggen  → image_output rate (from /endpoints)
          # speech  → audio_output rate (completion is audio)
          # embed / transcription → no output cost
          # text    → text_output rate
          primary_output = if is_imggen
            img_out_pm || text_out_pm
          elsif is_speech
            aud_out_pm || text_out_pm
          elsif is_embed || is_transcription
            nil
          else
            text_out_pm
          end

          # Primary input for cost calculation and sorting
          primary_input = is_transcription ? audio_in_pm : text_in_pm

          # Skip models with no id/name; keep zero-priced models (rerank, video) —
          # they are real models, just have $0 rates in the OpenRouter API.
          return nil unless raw[:id] && raw[:name]

          Pricing::ModelPrice.new(
            id:                           raw[:id],
            name:                         raw[:name],
            provider:                     "openrouter",
            input_per_million:            primary_input,
            output_per_million:           primary_output,
            cache_read_input_per_million: cache_r_pm,
            cache_write_input_per_million: cache_w_pm,
            context_window:               nil,
            max_output_tokens:            nil,
            input_modalities:             inp_mods,
            output_modalities:            out_mods,
            image_input_per_million:      img_in_pm,
            image_output_per_million:     img_out_pm,
            audio_input_per_million:      audio_in_pm,
            audio_output_per_million:     aud_out_pm,
            web_search_per_request:       web_search_usd
          )
        end

        # Per-token string → per-million float. Returns nil for zero/blank.
        def to_pm(value)
          return nil if value.nil? || value.to_s.strip.empty?
          f = value.to_f
          return nil if f <= 0
          (f * 1_000_000).round(6)
        end

        def http_get(uri)
          resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 15) do |h|
            h.get(uri.request_uri)
          end
          raise "OpenRouter API #{resp.code} for #{uri}" unless resp.is_a?(Net::HTTPSuccess)
          resp
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
