module ActiveHarness
  class Agent
    private

    # Strips markdown code fences that some models add despite being told not to:
    #   ```json\n{...}\n```  →  {...}
    def strip_code_fences(raw)
      raw.to_s.strip
         .gsub(/\A```(?:json)?\s*/i, "")
         .gsub(/\s*```\z/, "")
         .strip
    end

    # Like run_hook but uses the block's return value to replace the current value.
    # If no hook is defined, returns the original value unchanged.
    #
    #   on :before_parse do |raw|
    #     raw.gsub("'", '"')   # fixed-up string is used for parsing
    #   end
    #
    #   on :after_parse do |parsed|
    #     parsed.transform_keys(&:to_sym)  # symbolized hash is stored in result
    #   end
    def transform_hook(event, value)
      hooks = @config[:hooks] || {}
      return value unless hooks[event]

      instance_exec(value, &hooks[event])
    end

    def parse_output(raw)
      return raw unless @config[:format] == :json

      # :before_parse — return value replaces raw before stripping/parsing
      raw = transform_hook(:before_parse, raw)

      clean = strip_code_fences(raw)

      begin
        parsed = JSON.parse(clean)

        # :after_parse — return value replaces processed result stored in Result
        transform_hook(:after_parse, parsed)
      rescue JSON::ParserError => e
        # :parse_error — if hook returns non-nil, it is used as fallback value
        # and the exception is suppressed. Return nil (or omit return) to re-raise.
        #
        #   on :parse_error do |raw, error|
        #     puts "Parse failed: #{error.message}"
        #     { "result" => nil, "reason" => "parse error" }   # fallback
        #   end
        fallback = fire(:parse_error, raw, e)
        fallback.nil? ? raise : fallback
      end
    end
  end
end
