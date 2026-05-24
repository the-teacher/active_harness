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

      def post_json_stream(url, headers:, body:, timeout: 60, on_token:)
        STREAMING_HTTP.post(url, headers: headers, body: body.to_json, timeout: timeout, on_token: on_token)
      end

      # Normalize OpenAI-compatible usage object to a consistent hash.
      # Returns nil if the response contains no usage data.
      def extract_usage_openai(data)
        u = data["usage"]
        return nil unless u
        {
          input_tokens:  u["prompt_tokens"].to_i,
          output_tokens: u["completion_tokens"].to_i,
          total_tokens:  u["total_tokens"].to_i
        }
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
      # Adds stream: true and stream_options to body, calls StreamingClient,
      # and returns the same { content:, provider:, model:, usage: } shape
      # as non-streaming calls so callers need no special handling.
      def call_streaming(url:, headers:, body:, stream:, provider:, model:)
        body = body.merge(stream: true, stream_options: { include_usage: true })
        result = post_json_stream(URI(url), headers: headers, body: body, on_token: stream)
        {
          content:  result[:content],
          provider: provider,
          model:    model,
          usage:    extract_usage_openai({ "usage" => result[:raw_usage] })
        }
      end

      def parse!(raw)
        JSON.parse(raw)
      rescue JSON::ParserError => e
        raise Errors::ProviderError, "Invalid JSON response: #{e.message}"
      end
    end
  end
end
