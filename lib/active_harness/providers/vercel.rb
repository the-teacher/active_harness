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
        raise Errors::InvalidRequestError, "provider: :vercel (Jev) does not support token streaming" if stream

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

        raw  = post_json(URI(config.vercel_api_url), headers: headers, body: body)
        data = parse!(raw)
        handle_error!(data)

        {
          content:  JSON.pretty_generate(data["answers"]),
          provider: :vercel,
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

      # Two error shapes seen in practice:
      # - TypeSafe request-validation errors: { "message": "...", "error_type": "..." }
      # - AI Gateway account/billing errors (OpenAI-style, nested): { "error": { "message": "...", "type": "..." } }
      def handle_error!(data)
        msg, type =
          if data["message"] && data["error_type"]
            [data["message"].to_s, data["error_type"].to_s]
          elsif data["error"].is_a?(Hash)
            [data["error"]["message"].to_s, data["error"]["type"].to_s]
          end
        return unless msg

        case type
        when "invalid_request"                then raise Errors::InvalidRequestError.new(msg, error_code: type)
        when "unauthorized", "authentication_error" then raise Errors::InvalidApiKeyError.new(msg, error_code: type)
        when "rate_limit", "rate_limit_error" then raise Errors::RateLimitError.new(msg, error_code: type)
        when "customer_verification_required" then raise Errors::InvalidApiKeyError.new(msg, error_code: type)
        else                                        raise Errors::ProviderError.new(msg, error_code: type)
        end
      end
    end
  end
end
