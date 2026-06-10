# Prompts

## How Prompts Work

A prompt class is a plain Ruby object. The only requirement is a `call` instance method that returns a string — the system prompt text sent to the model.

The agent injects the following instance variables before calling `call`:

| Variable           | Description                                               |
| ------------------ | --------------------------------------------------------- |
| `@input`           | Current user input string                                 |
| `@context`         | Domain data — user role, locale, flags, etc.              |
| `@params`          | Tuning knobs — max length, fractions, technical settings  |
| `@memory`          | Memory object, if passed to the agent                     |
| `@context_window`  | Context window size of the primary model; `nil` if unknown |

There is no base class to inherit from. Any class with `call` works.

---

## Minimal Prompt

```ruby
class SupportPrompt
  def call
    "You are a concise and helpful assistant. Answer in 1-2 sentences."
  end
end
```

```ruby
class SupportAgent < ActiveHarness::Agent
  system_prompt SupportPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

---

## Multi-line Prompt

Use a heredoc for longer instructions:

```ruby
class TranslationPrompt
  def call
    <<~PROMPT
      You are a translation assistant.
      If the user message is already in English, return it unchanged.
      Otherwise, translate it to English accurately.
      Reply with ONLY the translated text — no explanations, no labels.
    PROMPT
  end
end
```

---

## Dynamic Content with `@context`

Use `@context` for domain-specific data — locale, user role, feature flags. Pass it at the call site:

```ruby
class TeacherPrompt
  def call
    <<~PROMPT
      You are an experienced teacher.

      Language: #{language}
      Student level: #{level}

      Explain concepts clearly, use examples, and be patient.
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
```

```ruby
agent = TeacherAgent.call(
  input:   "Explain recursion",
  context: { language: "Spanish", level: "beginner" }
)
```

---

## Tuning with `@params`

Use `@params` for technical knobs that change output shape — max length, format, verbosity. Keep domain context in `@context`, tuning in `@params`:

```ruby
class SummaryPrompt
  DEFAULT_MAX_WORDS = 200

  def call
    <<~PROMPT
      Summarize the following text in #{max_words} words or fewer.
      Reply with the summary only — no preamble.
    PROMPT
  end

  private

  def max_words
    @params[:max_words] || DEFAULT_MAX_WORDS
  end
end
```

```ruby
SummaryAgent.call(input: article, params: { max_words: 50 })
```

---

## Using `@input` in the Prompt

Include the user input directly in the system prompt when you want to frame it with instructions:

```ruby
class ClassifierPrompt
  def call
    <<~PROMPT
      Classify the following message into one of these categories:
      billing, technical, general, other.

      Reply with ONLY the category name.

      Message: #{@input}
    PROMPT
  end
end
```

---

## JSON Output Prompt

When the agent uses `format :json`, the model must return valid JSON. State the exact schema in the prompt:

```ruby
class ToxicityPrompt
  def call
    <<~PROMPT
      You are a toxicity classifier.
      Analyze the user message and reply ONLY with valid JSON, no markdown:

      {"toxic": true,  "reason": "..."}
      {"toxic": false, "reason": "..."}

      Toxic content includes: hate speech, threats, severe insults, dehumanizing language.
    PROMPT
  end
end
```

```ruby
class ToxicityAgent < ActiveHarness::Agent
  system_prompt ToxicityPrompt
  format :json

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

result = ToxicityAgent.call(input: "You are terrible!")
result.processed["toxic"]   # => true
result.processed["reason"]  # => "..."
```

---

## Using `@memory` for Conversation History

Read conversation history inside the prompt. Load and record still happen in agent hooks — the prompt only reads:

```ruby
class MemoryPrompt
  def call
    return base_instruction if @memory.nil? || @memory.size.zero?

    "#{base_instruction}\n\n" \
    "Conversation so far:\n" \
    "#{history}"
  end

  private

  def base_instruction
    "You are a helpful conversational assistant. Keep answers concise (1-3 sentences)."
  end

  def history
    @memory
      .to_messages
      .map { |message| message[:content] }
      .join("\n")
  end
end
```

---

## Respecting `@context_window`

Use `@context_window` to cap how much history you include — useful when the model's context is limited:

```ruby
class MemoryPrompt
  HISTORY_FRACTION = 0.25

  def call
    return base_instruction if @memory.nil? || @memory.size.zero?

    "#{base_instruction}\n\n" \
    "Conversation so far:\n" \
    "#{history}"
  end

  private

  def base_instruction
    "You are a helpful conversational assistant. Keep answers concise (1-3 sentences)."
  end

  def history
    @memory
      .to_messages(token_budget: token_budget)
      .map { |message| message[:content] }
      .join("\n")
  end

  def token_budget
    return nil unless @context_window

    fraction = @params[:history_fraction] || HISTORY_FRACTION
    (@context_window * fraction).to_i
  end
end
```

`@context_window` comes from the Costs table for the primary model. When it is `nil` (unknown model), `token_budget: nil` disables the limit.

---

## Generator

```
rails generate active_harness:prompt NAME
```

Creates `app/ai/prompts/name_prompt.rb` with a minimal `call` method.
