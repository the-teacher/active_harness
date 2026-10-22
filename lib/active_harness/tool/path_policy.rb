module ActiveHarness
  class Tool
    # Reusable path checks — implemented once, correctly (symlinks, "..", the
    # trailing-slash prefix bug). The including tool must define ALLOWED_PATHS;
    # a missing constant raises NameError, which fails closed (an :error result).
    #
    #   class LsTool < ActiveHarness::Tool
    #     include ActiveHarness::Tool::PathPolicy
    #     ALLOWED_PATHS = %w[/srv/app/workspace].freeze
    #
    #     step(:resolve_path, transform: true) { |input| input.merge(path: safe_path!(input[:path])) }
    #   end
    module PathPolicy
      # Returns a canonical absolute path inside ALLOWED_PATHS, or raises Denied.
      def safe_path!(path)
        deny!("path must not contain NUL") if path.to_s.include?("\0")

        real  = File.realpath(File.expand_path(path.to_s)) # follows symlinks
        roots = self.class::ALLOWED_PATHS.map { |r| File.realpath(r) }
        ok    = roots.any? { |r| real == r || real.start_with?(r + File::SEPARATOR) }
        deny!("#{path} is outside allowed directories", detail: "resolved to #{real}") unless ok
        real
      rescue Errno::ENOENT
        deny!("#{path} does not exist")
      end
    end
  end
end
