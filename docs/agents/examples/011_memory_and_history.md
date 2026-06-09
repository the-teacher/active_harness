# 011 — Memory and Conversation History

## Topic

How to save conversation history and use it for contextual understanding in subsequent requests.

## Why This Is Needed

Memory allows an agent to remember previous messages and conversation context. Critical for chat and dialogue systems.

## Example

```ruby
class ChatPrompt
  def call
    history = @context[:history_text].presence || "No history yet."

    <<~PROMPT
      You are a helpful chat assistant.

      Conversation History:
      #{history}

      Current user message: #{@input}

      Respond naturally, remembering the conversation context.
    PROMPT
  end
end
```

```ruby
class ChatAgent < ActiveHarness::Agent
  system_prompt ChatPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :setup do
    # Initialize history if it doesn't exist
    @context[:history] ||= []
    @context[:conversation_id] ||= SecureRandom.uuid
  end

  on :before_call do
    # Add history to context
    @context[:history_text] = format_history(@context[:history])
  end

  on :after_call do |result|
    # Save user message and response to history
    @context[:history] << {
      role: "user",
      content: @input,
      timestamp: Time.now
    }

    @context[:history] << {
      role: "assistant",
      content: result.output,
      timestamp: Time.now
    }

    # Limit history size (last 10 messages)
    @context[:history] = @context[:history].last(10)
  end

  private

  def format_history(history)
    history.map do |msg|
      "#{msg[:role].upcase}: #{msg[:content]}"
    end.join("\n")
  end
end

def chat_turn(input, history, conversation_id)
  agent = ChatAgent.new(
    input: input,
    context: { history: history, conversation_id: conversation_id }
  )
  agent.call
  puts "Assistant: #{agent.result.output}\n"
  agent.context[:history]
end

# Simulate a conversation
conversation_id = SecureRandom.uuid
history = []

history = chat_turn("Hello! How are you?", history, conversation_id)
history = chat_turn("Tell me about yourself", history, conversation_id)
chat_turn("Thanks for the information", history, conversation_id)
```

## Persisting History to Database

```ruby
class ConversationMemory
  def initialize(conversation_id)
    @conversation_id = conversation_id
  end

  def load_history
    Conversation.find_by(id: @conversation_id)&.messages || []
  end

  def save_message(role, content)
    conversation = Conversation.find_or_create_by(id: @conversation_id)
    conversation.messages.create!(role: role, content: content)
  end

  def clear_history
    Conversation.find_by(id: @conversation_id)&.destroy
  end
end

# Usage
memory = ConversationMemory.new(conversation_id)
history = memory.load_history

agent = ChatAgent.new(
  input: "Hello!",
  context: { history: history, conversation_id: conversation_id }
)

agent.call

# Save messages
memory.save_message("user", agent.input)
memory.save_message("assistant", agent.result.output)
```

## Database Schema

```ruby
# db/migrate/xxx_create_conversations.rb
class CreateConversations < ActiveRecord::Migration[7.0]
  def change
    create_table :conversations, id: :uuid do |t|
      t.string :title
      t.timestamps
    end

    create_table :messages, id: :uuid do |t|
      t.uuid :conversation_id, null: false
      t.string :role, null: false  # "user" or "assistant"
      t.text :content, null: false
      t.timestamps

      t.foreign_key :conversations
      t.index :conversation_id
    end
  end
end

# app/models/conversation.rb
class Conversation < ApplicationRecord
  has_many :messages, dependent: :destroy
end

# app/models/message.rb
class Message < ApplicationRecord
  belongs_to :conversation
end
```

## Limiting History Size

```ruby
class ChatAgent < ActiveHarness::Agent
  MAX_HISTORY_SIZE = 20
  MAX_HISTORY_TOKENS = 2000

  on :before_call do
    # Trim history by message count
    @context[:history] = @context[:history].last(MAX_HISTORY_SIZE)

    # Trim history by token count
    history_text = format_history(@context[:history])
    if estimate_tokens(history_text) > MAX_HISTORY_TOKENS
      @context[:history] = @context[:history].drop_while do |msg|
        estimate_tokens(format_history(@context[:history])) > MAX_HISTORY_TOKENS
      end
    end
  end

  private

  def estimate_tokens(text)
    # Rough estimate: 1 token ≈ 4 characters
    (text.length / 4).ceil
  end

  def format_history(history)
    history.map do |msg|
      "#{msg[:role]}: #{msg[:content]}"
    end.join("\n")
  end
end
```
