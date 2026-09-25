# Quick Start

## In 5 Minutes

### 1. Create a request

```ruby
class MyRequest < ActiveHarness::Request
  system_prompt MyPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end
```

### 2. Create a prompt

```ruby
class MyPrompt
  def call
    "You are a helpful assistant."
  end
end
```

### 3. Use the request

```ruby
request = MyRequest.new(input: "Hello!")
request.call
puts request.result.output
```

## Core Concepts

| Concept     | Description                       | Example                                   |
| ----------- | --------------------------------- | ----------------------------------------- |
| **Request**   | Class that processes requests     | `class MyRequest < ActiveHarness::Request`    |
| **Prompt**  | System instructions for the LLM   | `class MyPrompt; def call; ...; end; end` |
| **Model**   | LLM model configuration           | `use provider: :openrouter, model: "..."` |
| **Context** | Parameters passed to the request    | `context: { language: "English" }`        |
| **Result**  | Request output                      | `request.result.output`                     |
| **Hooks**   | Callbacks at different lifecycle stages | `on :after_call { \|result\| ... }`  |

## Common Tasks

### Add context

```ruby
request = MyRequest.new(
  input: "Question",
  context: { language: "English", tone: "friendly" }
)
```

### Add fallback models

```ruby
model do
  use provider: :openrouter, model: "mistral-nemo"
  fallback provider: :openrouter, model: "llama-3.3-70b"
  fallback provider: :openrouter, model: "gemma-4-31b"
end
```

### Handle errors

```ruby
begin
  request.call
rescue ActiveHarness::Errors::AllModelsFailed => e
  puts "All models exhausted"
end
```

### Add logging

```ruby
on :after_call do |result|
  puts "✓ #{result.model.name}: #{result.execution_time}s"
end

on :retry do |entry, error|
  puts "✗ #{entry[:model]}: #{error.message}"
end
```

### Use streaming

```ruby
request = MyRequest.new(
  input:  "Question",
  token:  ->(chunk) { print chunk }
)
request.call
```

### Save history

```ruby
@history ||= []

on :after_call do |result|
  @history << { role: "user", content: @input }
  @history << { role: "assistant", content: result.output }
end
```

## File Structure

```
docs/requests/examples/
├── README.md                          # Table of contents
├── QUICK_START.md                     # This file
├── 001_basic_request.md                 # Start here
├── 002_fallback_chain_basic.md
├── 003_fallback_chain.md
├── 004_request_hooks.md
├── 005_parse_hooks.md
├── 006_system_prompts.md
├── 007_parallel_requests.md
├── 008_streaming_basic.md
├── 009_streaming_rails_sse.md
├── 010_streaming_multiple_streams.md
├── 011_memory_and_history.md
├── 012_error_handling.md
├── 013_custom_llm_backend.md
├── 014_guards_and_validation.md
├── 015_pipelines_orchestration.md
├── 016_caching_and_optimization.md
├── 017_monitoring_and_metrics.md
├── 018_testing_requests.md
├── 019_memory_postgresql.md
└── 020_memory_sqlite.md
```

## Next Steps

1. **Read [001_basic_request.md](./001_basic_request.md)** — create your first request
2. **Read [002_fallback_chain_basic.md](./002_fallback_chain_basic.md)** — add resilience
3. **Read [004_request_hooks.md](./004_request_hooks.md)** — understand the lifecycle
4. **Browse [README.md](./README.md)** — pick the example you need

## Useful Links

- [Main documentation](../README.md)
- [Hooks documentation](../request_hooks.md)
- [Error handling documentation](../request_error_processing.md)

## Troubleshooting

If something isn't working:

1. Check that the API key is set: `ENV['OPENROUTER_API_KEY']`
2. Check the logs: `Rails.logger.info`
3. Open an issue on GitHub

## Ready?

Start with [001_basic_request.md](./001_basic_request.md) right now!
