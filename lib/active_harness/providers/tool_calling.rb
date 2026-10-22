require "json"

module ActiveHarness
  module Providers
    # Tool-calling support shared by OpenAI-compatible providers.
    #
    # ActiveHarness speaks to providers in a neutral shape:
    #
    #   tools:    [{ name: "os__ls", description: "...", parameters: { type: "object", ... } }]
    #   messages: [{ role: :user, content: "..." },
    #              { role: :assistant, content: "", tool_calls: [{ id:, name:, arguments: {} }] },
    #              { role: :tool, tool_call_id: "...", name: "os__ls", content: "..." }]
    #
    # and receives tool calls back as [{ id:, name:, arguments: Hash|nil, raw_arguments: String }].
    # This module maps that shape to and from the OpenAI wire format.
    module ToolCalling
      def supports_tools?
        true
      end

      private

      def tools?(tools)
        !tools.nil? && !tools.empty?
      end

      def openai_tools(tools)
        Array(tools).map do |t|
          {
            type:     "function",
            function: { name: t[:name], description: t[:description].to_s, parameters: t[:parameters] }
          }
        end
      end

      def openai_messages(messages)
        messages.map { |m| openai_message(m) }
      end

      def openai_message(message)
        role  = (message[:role] || message["role"]).to_s
        calls = message[:tool_calls] || message["tool_calls"]

        if role == "assistant" && calls && !calls.empty?
          content = message[:content] || message["content"]
          {
            role:       "assistant",
            content:    content.to_s.empty? ? nil : content,
            tool_calls: calls.map do |c|
              {
                id:       c[:id],
                type:     "function",
                function: { name: c[:name], arguments: JSON.generate(c[:arguments] || {}) }
              }
            end
          }
        elsif role == "tool"
          {
            role:         "tool",
            tool_call_id: message[:tool_call_id] || message["tool_call_id"],
            content:      (message[:content] || message["content"]).to_s
          }
        else
          message
        end
      end

      # { tool_calls: [...] } when the response contains tool calls, {} otherwise.
      # Meant to be splatted into the provider's response hash.
      def openai_tool_calls_entry(data)
        raw = data.dig("choices", 0, "message", "tool_calls")
        return {} if raw.nil? || raw.empty?

        { tool_calls: raw.map { |c| parse_openai_tool_call(c) } }
      end

      def parse_openai_tool_call(call)
        raw_args = call.dig("function", "arguments")
        args =
          case raw_args
          when Hash   then raw_args
          when String then raw_args.strip.empty? ? {} : (JSON.parse(raw_args) rescue nil)
          else {}
          end

        {
          id:            call["id"],
          name:          call.dig("function", "name"),
          arguments:     args.is_a?(Hash) ? args : nil,
          raw_arguments: raw_args.is_a?(String) ? raw_args : raw_args.to_s
        }
      end
    end
  end
end
