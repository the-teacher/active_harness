# 006 — System Prompts

## Topic

How to create and use system prompts to control agent behavior.

## Why This Is Needed

A system prompt is an instruction for the LLM that determines how the model should behave. A good prompt is critical for response quality.

## Prompt Structure

```ruby
class MyPrompt
  def call
    # @context is available here
    # @input is available here

    <<~PROMPT
      Instructions for the model...
    PROMPT
  end
end
```

## Example

```ruby
class TeacherPrompt
  def call
    <<~PROMPT
      You are an experienced teacher.

      Language: #{language}
      Student Level: #{level}

      Your responsibilities:
      1. Explain concepts clearly and simply
      2. Use examples relevant to the student's level
      3. Ask clarifying questions if needed
      4. Encourage learning

      Always be patient and supportive.
    PROMPT
  end

  private

  def language
    @context[:language] || "English"
  end

  def level
    @context[:level] || "intermediate"
  end
end

# Use the prompt in an agent
class TeacherAgent < ActiveHarness::Agent
  system_prompt TeacherPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :setup do
    @context[:level] ||= "beginner"
  end
end

# Call the agent
agent = TeacherAgent.new(
  input: "Explain what recursion is",
  context: { language: "English", level: "beginner" }
)

agent.call
result = agent.result

puts "System prompt:"
puts result.system_prompt
puts "\nResponse:"
puts result.output
```

## Available instance variables in prompt classes

When ActiveHarness resolves a system prompt class it injects the full agent state before calling `#call`. All of the following are readable in any prompt class:

| Variable | Type | Description |
|---|---|---|
| `@input` | `String \| nil` | Current user input (normalized) |
| `@context` | `Hash` | Arbitrary caller-supplied context |
| `@params` | `Hash` | Technical parameters passed via `params:` |
| `@memory` | `Memory \| nil` | Memory object if `memory:` was passed |
| `@context_window` | `Integer \| nil` | Context window size for the primary model (from `Pricing`); `nil` if unknown |
| `@config` | `Hash` | Agent class-level DSL config (read-only) |

`@context` is for domain data (user id, locale, flags). `@params` is for technical overrides that should not mix with domain context — things like `{ history_fraction: 0.4 }` or `{ max_tokens: 500 }`.

## Accessing Data in Prompts

```ruby
class ContextAwarePrompt
  def call
    <<~PROMPT
      Role: #{role}
      Language: #{language}

      User's question: #{input_preview}

      Respond appropriately.
    PROMPT
  end

  private

  def role
    @context[:role] || "user"
  end

  def language
    @context[:language] || "English"
  end

  def input_preview
    @input.first(100)
  end
end
```

Params example — overriding a tuning knob at call time without polluting `@context`:

```ruby
class SummaryPrompt
  MAX_LENGTH_DEFAULT = 200

  def call
    max = @params[:max_length] || MAX_LENGTH_DEFAULT
    <<~PROMPT
      Summarize the following text in #{max} words or fewer.

      Text: #{@input}
    PROMPT
  end
end

# default
SummaryAgent.call(input: article)

# override at call time
SummaryAgent.call(input: article, params: { max_length: 50 })
```

## Example Prompts for Different Roles

### Assistant Prompt

```ruby
class AssistantPrompt
  def call
    <<~PROMPT
      You are a helpful assistant.

      Your goal is to:
      - Answer questions accurately
      - Provide useful information
      - Be concise and clear
      - Ask for clarification if needed
    PROMPT
  end
end
```

### Critic Prompt

```ruby
class CriticPrompt
  def call
    <<~PROMPT
      You are a constructive critic.

      Your role is to:
      - Identify strengths and weaknesses
      - Provide specific, actionable feedback
      - Suggest improvements
      - Be respectful and professional
    PROMPT
  end
end
```

### Dynamic Prompt

```ruby
class DynamicPrompt
  def call
    <<~PROMPT
      Tone: #{tone}

      #{length_instruction}

      Answer the user's question.
    PROMPT
  end

  private

  def tone
    @context[:tone] || "neutral"
  end

  def length_instruction
    case @context[:max_length] || "medium"
    when "short" then "Keep your response to 1-2 sentences."
    when "long"  then "Provide a detailed, comprehensive response."
    else              "Provide a balanced response."
    end
  end
end
```

## Best Practices

1. **Be specific** — the more precise the instruction, the better the result
2. **Use context** — pass parameters through `@context`
3. **Test** — try different prompt variations
4. **Document** — add comments about prompt purpose
5. **Version** — track prompt changes
