require "uri"

module ActiveHarness
  module Providers
    # Vercel AI Gateway — TypeSafe-compatible "System One" evaluation endpoint (Jev).
    #
    # This is fundamentally different from every other provider here: Jev does not
    # take free-form chat messages and does not return free text. It evaluates a
    # single `state` string against typed `questions` and returns typed answers
    # (a score/probability/choice per question), e.g.:
    #
    #   POST https://ai-gateway.vercel.sh/typesafe/v1/systemone
    #   { "model": "typesafe-ai/jev", "state": "...", "questions": { "answer": { "type": "noul", "instructions": "..." } } }
    #   => { "answers": { "answer": { "type": "noul", "noul": 0.8 } }, "usage": {...} }
    #
    # Question types are "noul" (0..1 probability, optionally scoped by a
    # true/false `criteria` hash), "choice" (requires `criteria` — a name=>
    # description hash), and "score" (requires `criteria` — an ordered array of
    # at least 2 labels).
    #
    # To fit the standard Request(messages:) call shape without building a whole
    # typed-questions DSL into Request itself, this bridges it minimally: the
    # last user message becomes `state`, and — unless the model-chain entry
    # supplies its own `questions:` hash (already in the API's own shape) — the
    # system message (if any) becomes a single default "noul" question's
    # `instructions`. Either way the raw `answers` payload is returned as-is
    # (pretty JSON) as `content` — no interpretation of the typed answer is
    # attempted.
    #
    #   # simplest form — one implicit yes/no-ish question from the system prompt
    #   model do
    #     use provider: :vercel, model: "typesafe-ai/jev"
    #   end
    #
    #   # explicit multi-question form — full control over the question set
    #   model do
    #     use provider: :vercel, model: "typesafe-ai/jev", questions: {
    #       sentiment: { type: "score",  instructions: "...", criteria: ["negative", "neutral", "positive"] },
    #       topic:     { type: "choice", instructions: "...", criteria: { support: "...", spam: "..." } },
    #       urgent:    { type: "noul",   instructions: "..." }
    #     }
    #   end
    class Vercel < Base
      DEFAULT_INSTRUCTIONS = "Evaluate the given state.".freeze

      def call(model:, messages:, temperature: nil, stream: nil, questions: nil)
        raise Errors::InvalidRequestError, "provider: :#{provider_name} (Jev) does not support token streaming" if stream

        state = messages.reverse.find { |m| m[:role] == "user" }&.fetch(:content, nil).to_s

        headers = {
          "Content-Type"  => "application/json",
          "Authorization" => "Bearer #{api_key}"
        }
        body = {
          model:     model,
          state:     state,
          questions: questions || default_questions(messages)
        }

        raw  = post_json(URI(endpoint_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data, status: raw.respond_to?(:http_status) ? raw.http_status : nil)

        {
          content:  JSON.pretty_generate(data["answers"]),
          provider: provider_name,
          model:    data["model"] || model,
          usage:    extract_usage(data)
        }
      end

      private

      def default_questions(messages)
        instructions = messages.find { |m| m[:role] == "system" }&.fetch(:content, nil).to_s
        instructions = DEFAULT_INSTRUCTIONS if instructions.empty?
        { answer: { type: "noul", instructions: instructions } }
      end

      # Subclasses (e.g. TypeSafe) reuse everything above and only swap these.
      def provider_name
        :vercel
      end

      def endpoint_url
        config.vercel_api_url
      end

      def api_key
        key = config.vercel_api_key.to_s
        raise Errors::InvalidApiKeyError, "vercel_api_key is not configured" if key.empty?
        key
      end

      # Jev's usage object only has input/output tokens, OpenAI-shaped but
      # under different keys than the chat-completions providers use.
      def extract_usage(data)
        u = data["usage"]
        return nil unless u

        input  = u["input_tokens"].to_i
        output = u["output_tokens"].to_i
        { input_tokens: input, output_tokens: output, total_tokens: input + output }
      end

      # TypeSafe's own API reports { "detail": String | { "message": ... } |
      # [ { "loc": [...], "msg": "..." } ] } (FastAPI-style).
      def detail_message(detail)
        case detail
        when Hash  then detail["message"].to_s
        when Array then detail.map { |e| e.is_a?(Hash) ? [Array(e["loc"]).join("."), e["msg"]].reject { |x| x.to_s.empty? }.join(": ") : e.to_s }.join("; ")
        else            detail.to_s
        end
      end

      # Prefer the HTTP status when we have it; fall back to sniffing the
      # message only when we don't (e.g. a custom HTTP client without #http_status).
      def detail_error_type(msg, status)
        case status
        when 401, 403 then "unauthorized"
        when 429      then "rate_limit"
        when 500..599 then "server_error"
        when nil      then msg =~ /api key|unauthori|authenticat|invalid token|credentials/i ? "unauthorized" : "invalid_request"
        else               "invalid_request"
        end
      end

      # Error shapes seen in practice:
      # - TypeSafe direct API: { "detail": ... } (see detail_message)
      # - TypeSafe request-validation errors: { "message": "...", "error_type": "..." }
      # - AI Gateway account/billing errors (OpenAI-style, nested): { "error": { "message": "...", "type": "..." } }
      def handle_error!(data, status: nil)
        msg, type =
          if data.key?("detail")
            msg = detail_message(data["detail"])
            [msg, detail_error_type(msg, status)]
          elsif data["message"] && data["error_type"]
            [data["message"].to_s, data["error_type"].to_s]
          elsif data["error"].is_a?(Hash)
            [data["error"]["message"].to_s, data["error"]["type"].to_s]
          end
        return unless msg

        case type
        when "invalid_request"                then raise Errors::InvalidRequestError.new(msg, error_code: type)
        when "unauthorized", "authentication_error" then raise Errors::InvalidApiKeyError.new(msg, error_code: type)
        when "rate_limit", "rate_limit_error" then raise Errors::RateLimitError.new(msg, error_code: type)
        when "server_error"                   then raise Errors::ServerError.new(msg, error_code: type)
        when "customer_verification_required" then raise Errors::InvalidApiKeyError.new(msg, error_code: type)
        else                                        raise Errors::ProviderError.new(msg, error_code: type)
        end
      end
    end
  end
end
