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

puts "Model: #{result.model.name}"
puts "Response: #{result.output}"
```

## Result Structure

```ruby
result.input                 # => "Hello! How are you?"
result.output                # => "Model response..."
result.system_prompt         # => "System instructions..."
result.execution_time        # => 1.234

result.model.name            # => "mistralai/mistral-nemo"
result.model.provider        # => "openrouter"
result.model.context_window  # => 128_000
result.model.pricing.input   # => 0.0000003

result.usage.tokens.input    # => 10
result.usage.tokens.output   # => 20
result.usage.tokens.total    # => 30
result.usage.cost.total      # => 0.00015
```
