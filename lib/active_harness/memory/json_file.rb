module ActiveHarness
  class Memory
    # File-backed memory with a path-safe file_name interface.
    #
    # Differences from the base Memory class:
    #   - file_name:    replaces session_id — may contain slashes to create
    #                   subdirectories under storage_path, e.g. "users/42/chat"
    #                   Final file is always <storage_path>/<file_name>.json
    #   - storage_path: replaces the adapter-level path: option
    #   - adapter:      always :file — no other adapter can be passed
    #
    # Path traversal is rejected: segments equal to "." or ".." or containing
    # null bytes raise ArgumentError before any file I/O happens.
    # Missing directories are created automatically on the first write.
    class JsonFile < Memory
      DEFAULT_STORAGE_PATH = "storage/ai/memory"

      def initialize(file_name:, storage_path: DEFAULT_STORAGE_PATH, **opts)
        super(
          session_id:   sanitize!(file_name),
          adapter:      :file,
          path:         storage_path,
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
