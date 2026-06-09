require "json"
require "fileutils"

module ActiveHarness
  class Memory
    module Adapter
      # File-backed memory adapter — stores turns as JSON on disk.
      #
      # Each session is stored in one file:
      #   <path>/<session_id>.json                   (no namespace)
      #   <path>/<session_id>/<namespace>.json       (with namespace)
      #
      # Options:
      #   path             — base directory                  (default: "storage/ai/memory")
      #   filename         — String or Proc(session_id)      (default: "<session_id>.json")
      #   pretty           — format JSON with indentation    (default: false)
      #   compact          — store only q/a keys             (default: false)
      #   encoding         — file encoding                   (default: "UTF-8")
      #   storage_size     — max turns kept in file          (default: 1000)
      #   eviction_percent — % of oldest turns to drop       (default: 10)
      #   on_trim          — Proc called with trimmed turns  (default: nil)
      class JsonFile < Base
        DEFAULT_PATH         = "storage/ai/memory"
        DEFAULT_STORAGE_SIZE = 1000
        DEFAULT_TRIM_PERCENT = 10

        def initialize(opts = {})
          @path         = opts.fetch(:path, DEFAULT_PATH)
          @filename_opt = opts[:filename]
          @pretty       = opts.fetch(:pretty, false)
          @compact      = opts.fetch(:compact, false)
          @encoding     = opts.fetch(:encoding, "UTF-8")
          @storage_size = opts.fetch(:storage_size, DEFAULT_STORAGE_SIZE)
          @trim_percent = opts.fetch(:eviction_percent, DEFAULT_TRIM_PERCENT)
          @on_trim      = opts[:on_trim]
          @namespace    = opts[:namespace]

          @session_id = nil
          @turns      = []
        end

        def open(session_id)
          @session_id = session_id
          @turns      = load_from_disk
        end

        def read
          @turns.dup
        end

        def write(turn)
          @turns << turn
          trim_if_needed!
          flush!
        end

        def close
          # Writes immediately on each write — nothing to flush.
        end

        def delete
          path = file_path
          ::FileUtils.rm_f(path)
          dir = ::File.dirname(path)
          if @namespace && Dir.exist?(dir) && Dir.empty?(dir)
            Dir.rmdir(dir)
          end
          @turns = []
        end

        # -----------------------------------------------------------------------
        private
        # -----------------------------------------------------------------------

        def file_path
          name = resolve_filename
          if @namespace
            ::File.join(@path, @session_id.to_s, "#{@namespace}.json")
          else
            ::File.join(@path, name)
          end
        end

        def resolve_filename
          case @filename_opt
          when Proc   then @filename_opt.call(@session_id)
          when String then @filename_opt
          else             "#{@session_id}.json"
          end
        end

        def load_from_disk
          path = file_path
          return [] unless ::File.exist?(path)

          raw  = ::File.read(path, encoding: @encoding)
          data = JSON.parse(raw, symbolize_names: true)
          turns = Array(data[:turns])

          turns.map do |t|
            if t.key?(:q)
              { request: t[:q], response: t[:a] }
            else
              t
            end
          end
        rescue JSON::ParserError
          []
        end

        def flush!
          path = file_path
          ::FileUtils.mkdir_p(::File.dirname(path))

          turns_to_write = if @compact
            @turns.map { |t| { q: t[:request], a: t[:response] } }
          else
            @turns
          end

          data = { session_id: @session_id, turns: turns_to_write }
          json = @pretty ? JSON.pretty_generate(data) : JSON.generate(data)
          ::File.write(path, json, encoding: @encoding)
        end

        def trim_if_needed!
          return unless @storage_size
          return if @turns.size <= @storage_size

          count   = [@turns.size * @trim_percent / 100, 1].max
          trimmed = @turns.shift(count)
          @on_trim&.call(trimmed)
        end
      end
    end

    # Convenience Memory subclass for file-backed storage.
    #
    #   file_name:    replaces session_id — may contain slashes to create
    #                 subdirectories under storage_path, e.g. "users/42/chat"
    #                 Final file is always <storage_path>/<file_name>.json
    #   storage_path: base directory (default: "storage/ai/memory")
    #
    # Path traversal is rejected: segments equal to "." or ".." or containing
    # null bytes raise ArgumentError before any file I/O happens.
    # Missing directories are created automatically on the first write.
    class JsonFile < Memory
      def initialize(file_name:, storage_path: Adapter::JsonFile::DEFAULT_PATH, **opts)
        super(
          session_id: sanitize!(file_name),
          adapter:    Adapter::JsonFile.new(opts.merge(path: storage_path)),
          **opts
        )
      end

      private

      def sanitize!(raw)
        parts = raw.to_s.split("/").map(&:strip).reject(&:empty?)
        raise ArgumentError, "file_name must not be empty" if parts.empty?

        parts.each do |part|
          if part == ".." || part == "." || part.include?("\0")
            raise ArgumentError, "Invalid file_name segment: #{part.inspect}"
          end
        end

        parts.last.sub!(/\.json\z/i, "")
        parts.join("/")
      end
    end
  end
end
