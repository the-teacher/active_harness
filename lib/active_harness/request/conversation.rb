module ActiveHarness
  class Request
    # `input` is a String (one user turn) or an Array of messages (a conversation):
    #
    #   Request.call(input: "Find Ruby frameworks")
    #   Request.call(input: [{ role: :user, content: "Find Ruby frameworks" }, ...])
    #
    # A String is shorthand for [{ role: :user, content: "..." }]. For an Array the
    # request keeps the messages in @messages and @input holds the text of the last
    # user message, so everything that reads @input as a String (prompt classes,
    # lambdas, hooks) keeps working. There is no separate `messages:` keyword.
    MULTI_MESSAGE_WARNING =
      "only the last user message was taken from a multi-message input — " \
      "make sure that is what this prompt needs (use `transcript` for the full history)".freeze

    # What was passed in: the Array of messages, or the String.
    def input
      @messages || @input
    end

    def input=(value)
      assign_input(value)
    end

    # Non-fatal remarks collected during the last call (also streamed as [:request, :warning, text]).
    def warnings
      @warnings ||= []
    end

    # Text of the input for prompts and hooks that need a String.
    #
    #   input_text                   # => text of the last user message (the String itself for a String input)
    #   input_text(roles: [:user])   # => all user messages, joined with a blank line
    def input_text(roles: nil)
      return @input.to_s unless @messages
      return @input.to_s if roles.nil?

      wanted = Array(roles).map(&:to_s)
      @messages.select { |m| wanted.include?(message_role(m)) }
               .map { |m| message_text(message_content(m)) }
               .join("\n\n")
    end

    # Role-labelled history: "user: ...", "assistant: ...", "tool(os__ls): ...".
    def transcript
      return "user: #{@input}" unless @messages

      @messages.map do |m|
        role  = message_role(m)
        label = role == "tool" && (name = m[:name] || m["name"]) ? "tool(#{name})" : role
        "#{label}: #{message_text(message_content(m))}"
      end.join("\n")
    end

    private

    def assign_input(value)
      if value.is_a?(Array)
        @messages = value
        @input    = last_user_content(value)
      else
        @messages = nil
        @input    = value
      end
      normalize_input!
    end

    def message_role(message)
      (message[:role] || message["role"]).to_s
    end

    def message_content(message)
      message[:content] || message["content"]
    end

    # Content may be a String or a list of parts ([{ type: "text", text: "..." }, ...]).
    def message_text(content)
      return content.to_s unless content.is_a?(Array)

      content.map { |part| part.is_a?(Hash) ? (part[:text] || part["text"]).to_s : part.to_s }.join
    end

    def multi_message_input?
      @messages && @messages.size > 1
    end

    # Called where a prompt consumes the text of a multi-message input.
    def warn_multi_message_input
      emit_warning(MULTI_MESSAGE_WARNING) if multi_message_input?
    end

    def emit_warning(message)
      return if warnings.include?(message)

      warnings << message
      fire(:warning, message)
    end

    def last_user_content(messages)
      last = Array(messages).reverse.find { |m| message_role(m) == "user" }
      last && message_text(message_content(last))
    end
  end
end
