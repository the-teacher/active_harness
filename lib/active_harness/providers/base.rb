require "json"

module ActiveHarness
  module Providers
    class Base
      HTTP            = ActiveHarness::Http::Client.new
      STREAMING_HTTP  = ActiveHarness::Http::StreamingClient.new

      private

      def config
        ActiveHarness.config
      end

      def post_json(url, headers:, body:, timeout: 30)
        HTTP.post(url, headers: headers, body: body.to_json, timeout: timeout)
      end

      def post_json_stream(url, headers:, body:, timeout: 60, on_token:, parse_chunk: nil)
        STREAMING_HTTP.post(url, headers: headers, body: body.to_json, timeout: timeout, on_token: on_token, parse_chunk: parse_chunk)
      end

      # Normalize OpenAI-compatible usage object to a consistent hash.
      # Returns nil if the response contains no usage data.
      # provider_cost is included when the provider returns a cost field (e.g. OpenRouter).
      def extract_usage_openai(data)
        u = data["usage"]
        return nil unless u

        result = {
          input_tokens:  u["prompt_tokens"].to_i,
          output_tokens: u["completion_tokens"].to_i,
          total_tokens:  u["total_tokens"].to_i
        }
        result[:provider_cost] = u["cost"].to_f if u.key?("cost")
        result
      end

      # Normalize Anthropic usage object.
      def extract_usage_anthropic(data)
        u = data["usage"]
        return nil unless u
        input  = u["input_tokens"].to_i
        output = u["output_tokens"].to_i
        {
          input_tokens:  input,
          output_tokens: output,
          total_tokens:  input + output
        }
      end

      # Streaming call for OpenAI-compatible providers.
      # Subclasses may override +prepare_streaming_body+ and +build_streaming_chunk+
      # to support non-OpenAI SSE formats (e.g. Anthropic).
      def call_streaming(url:, headers:, body:, stream:, provider:, model:)
        body   = prepare_streaming_body(body)
        result = post_json_stream(URI(url), headers: headers, body: body, on_token: stream, parse_chunk: method(:build_streaming_chunk))
        u      = result[:usage] || {}
        usage  = u.any? ? { input_tokens: u[:input_tokens].to_i, output_tokens: u[:output_tokens].to_i, total_tokens: u[:input_tokens].to_i + u[:output_tokens].to_i } : nil
        { content: result[:content], provider: provider, model: model, usage: usage }
      end

      # Override in subclass to change streaming request body options.
      def prepare_streaming_body(body)
        body.merge(stream: true, stream_options: { include_usage: true })
      end

      # Override in subclass to parse provider-specific SSE chunks.
      # Must return { token: String|nil, usage: Hash|nil } where usage keys
      # are :input_tokens and :output_tokens.
      def build_streaming_chunk(parsed)
        token = parsed.dig("choices", 0, "delta", "content")
        raw_u = parsed["usage"]
        usage = raw_u ? { input_tokens: raw_u["prompt_tokens"].to_i, output_tokens: raw_u["completion_tokens"].to_i } : nil
        { token: token, usage: usage }
      end

      def parse!(raw)
        JSON.parse(raw)
      rescue JSON::ParserError => e
        raise Errors::ProviderError, "Invalid JSON response: #{e.message}"
      end
    end
  end
end
