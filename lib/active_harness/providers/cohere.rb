require "uri"

module ActiveHarness
  module Providers
    # Cohere — native v2 Chat API (not OpenAI-compatible).
    # https://docs.cohere.com/reference/chat
    #
    # Text chat only: tools, citations, documents, rerank and embeddings are not
    # supported. Thinking blocks returned by reasoning models are discarded —
    # only `text` blocks make it into the result.
    #
    # Example:
    #   model do
    #     use provider: :cohere, model: "command-a-03-2025"
    #   end
    class Cohere < Base
      def call(model:, messages:, temperature: 0.7, stream: nil)
        headers = { "Content-Type" => "application/json", "Authorization" => "Bearer #{api_key}" }
        body    = { model: model, messages: messages, temperature: temperature }

        return call_streaming(url: config.cohere_api_url, headers: headers, body: body, stream: stream, provider: :cohere, model: model) if stream

        raw  = post_json(URI(config.cohere_api_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data, status: raw.respond_to?(:http_status) ? raw.http_status : nil)

        {
          content:  extract_text(data),
          provider: :cohere,
          model:    model,
          usage:    extract_usage_cohere(data["usage"])
        }
      end

      private

      def api_key
        key = config.cohere_api_key.to_s
        raise Errors::InvalidApiKeyError, "cohere_api_key is not configured" if key.empty?
        key
      end

      # message.content is an array of typed blocks ({type: "text"|"thinking", ...});
      # keep only the text.
      def extract_text(data)
        Array(data.dig("message", "content"))
          .select { |block| block["type"] == "text" }
          .map { |block| block["text"].to_s }
          .join
          .strip
      end

      # `tokens` is what the model processed, `billed_units` what Cohere charges
      # for (it does not bill its own preamble). Prefer `tokens`, like ruby_llm.
      def extract_usage_cohere(usage)
        return nil unless usage

        tokens = usage["tokens"] || {}
        billed = usage["billed_units"] || {}
        input  = (tokens["input_tokens"]  || billed["input_tokens"]).to_i
        output = (tokens["output_tokens"] || billed["output_tokens"]).to_i
        { input_tokens: input, output_tokens: output, total_tokens: input + output }
      end

      # Cohere errors are flat: { "message": "..." } (validation errors may add
      # an "id"). Success bodies have no "message" string, only a message Hash.
      def handle_error!(data, status: nil)
        return unless data["message"].is_a?(String)
        return if status && status < 400

        msg  = data["message"]
        code = status ? status.to_s : nil
        meta = data["id"] ? { id: data["id"] } : nil

        case status
        when 401, 403 then raise Errors::InvalidApiKeyError.new(msg,       error_code: code, metadata: meta)
        when 429      then raise Errors::RateLimitError.new(msg,           error_code: code, metadata: meta)
        when 503      then raise Errors::ProviderUnavailableError.new(msg, error_code: code, metadata: meta)
        when 500..599 then raise Errors::ServerError.new(msg,              error_code: code, metadata: meta)
        else               raise Errors::InvalidRequestError.new(msg,      error_code: code, metadata: meta)
        end
      end

      # Cohere streaming takes a plain `stream: true` — no stream_options.
      def prepare_streaming_body(body)
        body.merge(stream: true)
      end

      # Cohere SSE events:
      #   content-delta → delta.message.content.text (or .thinking, ignored)
      #   message-end   → delta.usage with token counts
      def build_streaming_chunk(parsed)
        token = parsed.dig("delta", "message", "content", "text") if parsed["type"] == "content-delta"
        usage = extract_usage_cohere(parsed.dig("delta", "usage")) if parsed["type"] == "message-end"
        usage = usage&.reject { |k, _| k == :total_tokens }

        { token: token, usage: usage }
      end
    end
  end
end
