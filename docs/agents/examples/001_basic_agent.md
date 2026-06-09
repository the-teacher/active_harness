# 001 — Basic Agent Creation

## Topic

How to create the simplest agent with a single model and call it.

## Why This Is Needed

This is the foundation for working with ActiveHarness. You will learn how to define an agent, configure a model, and get a result.

## Example

First, define the prompt class that the agent will use:

```ruby
class SimpleGreetingPrompt
  def call
    "You are a friendly assistant. Greet the user warmly."
  end
end
```

Then define and use the agent:

```ruby
# Create an agent class inheriting from ActiveHarness::Agent
class SimpleGreetingAgent < ActiveHarness::Agent
  # Specify the system prompt class
  system_prompt SimpleGreetingPrompt

  # Configure the model
  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

# Create an agent instance with input data
agent = SimpleGreetingAgent.new(input: "Hello! How are you?")

# Call the agent
agent.call

# Get the result
result = agent.result

puts "Model: #{result.model}"
puts "Response: #{result.output}"
```

## Result Structure

```ruby
result.provider       # => "openrouter"
result.model          # => "mistralai/mistral-nemo"
result.input          # => "Hello! How are you?"
result.output         # => "Model response..."
result.system_prompt  # => "System instructions..."
result.usage          # => { input_tokens: 10, output_tokens: 20, total_tokens: 30 }
result.cost           # => 0.00015
result.execution_time # => 1.234
```
