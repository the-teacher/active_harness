# ActiveHarness Request Examples

This directory contains step-by-step examples for building and using requests, from simple to advanced.

## Example Structure

Each example includes:

- **Topic** — a brief description of what is covered
- **Why This Is Needed** — the practical motivation
- **Code Example** — working code with comments
- **Best Practices** — recommendations

## Examples

### Basics

| №       | Title                                                       | Topic                                                  |
| ------- | ----------------------------------------------------------- | ------------------------------------------------------ |
| **001** | [Basic Request](./001_basic_request.md)                         | Create the simplest request and get a result             |
| **002** | [Fallback Chain (Basic)](./002_fallback_chain_basic.md)     | Configure backup models for reliability                |
| **003** | [Fallback Chain](./003_fallback_chain.md)                   | Fallback chain with retry and failure callbacks        |

### Advanced Concepts

| №       | Title                                                       | Topic                                                  |
| ------- | ----------------------------------------------------------- | ------------------------------------------------------ |
| **004** | [Request Hooks](./004_request_hooks.md)                         | Use hooks to intervene at every lifecycle stage        |
| **005** | [Parse Hooks](./005_parse_hooks.md)                         | Transform and validate JSON output from the LLM        |
| **006** | [System Prompts](./006_system_prompts.md)                   | Create and use system instructions                     |
| **007** | [Parallel Requests](./007_parallel_requests.md)                 | Run multiple requests simultaneously                     |

### Streaming

| №       | Title                                                              | Topic                                                  |
| ------- | ------------------------------------------------------------------ | ------------------------------------------------------ |
| **008** | [Streaming (Basic)](./008_streaming_basic.md)                      | Receive responses token by token in real time          |
| **009** | [Streaming with Rails SSE](./009_streaming_rails_sse.md)           | Stream tokens to the browser using Server-Sent Events  |
| **010** | [Streaming (Multiple Streams)](./010_streaming_multiple_streams.md)| Stream tokens and request events simultaneously          |

### State and Memory

| №       | Title                                                   | Topic                                        |
| ------- | ------------------------------------------------------- | -------------------------------------------- |
| **011** | [Memory and History](./011_memory_and_history.md)       | Save conversation history and context        |
| **019** | [Memory (PostgreSQL)](./019_memory_postgresql.md)        | Persist conversation history in PostgreSQL   |
| **020** | [Memory (SQLite)](./020_memory_sqlite.md)                | Persist conversation history in SQLite       |

### Reliability and Error Handling

| №       | Title                                                          | Topic                                                  |
| ------- | -------------------------------------------------------------- | ------------------------------------------------------ |
| **012** | [Error Handling](./012_error_handling.md)                      | Handle errors properly and use retry logic             |
| **013** | [Custom LLM Backends](./013_custom_llm_backend.md)             | Integrate custom LLM services                          |
| **014** | [Guards and Validation](./014_guards_and_validation.md)        | Validate input data and results                        |

### Orchestration and Optimization

| №       | Title                                                              | Topic                                                       |
| ------- | ------------------------------------------------------------------ | ----------------------------------------------------------- |
| **015** | [Pipelines and Orchestration](./015_pipelines_orchestration.md)    | Combine multiple requests into pipelines                      |
| **016** | [Caching and Optimization](./016_caching_and_optimization.md)      | Cache results to improve performance                        |

### Monitoring and Testing

| №       | Title                                                     | Topic                                                  |
| ------- | --------------------------------------------------------- | ------------------------------------------------------ |
| **017** | [Monitoring and Metrics](./017_monitoring_and_metrics.md) | Track performance and collect metrics                  |
| **018** | [Testing Requests](./018_testing_requests.md)                 | Write tests and mock LLMs                              |

## Recommended Learning Order

### Beginners

1. Start with **001** — create a basic request
2. Move to **002** — add a fallback chain
3. Study **004** — understand the lifecycle
4. Try **006** — write your first system prompt

### Intermediate

5. Study **005** — parse hooks
6. Try **007** — parallel requests
7. Add **008**–**010** — streaming for better UX
8. Implement **011** — memory for dialogues

### Advanced

9. Handle **012** — errors and retry
10. Integrate **013** — custom backends
11. Add **014** — validation and guards
12. Build **015** — complex pipelines
13. Optimize **016** — caching
14. Monitor **017** — metrics
15. Test **018** — automated tests

## Quick Start

```ruby
class MyRequest < ActiveHarness::Request
  system_prompt MyPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end
end

request = MyRequest.new(input: "Hello!")
request.call
puts request.result.output
```

## Common Concepts

### The Result Object

Every request returns a `Result` object:

```ruby
result.model.provider       # LLM provider
result.model.name          # model used
result.input          # input data
result.output         # model response
result.system_prompt  # system prompt
result.usage          # token statistics
result.usage.cost.total     # request cost
result.execution_time # execution time
```

### Context

Context is a hash of parameters available in all hooks and prompts:

```ruby
request = MyRequest.new(
  input: "Question",
  context: {
    language: "English",
    tone: "friendly",
    user_id: "user_123"
  }
)
```

### Hooks

Hooks let you execute code at different lifecycle stages:

```ruby
class MyRequest < ActiveHarness::Request
  on :setup do
    puts "Initializing"
  end

  before :call do
    puts "Before request"
  end

  after :call do |result|
    puts "After request"
  end

  on :retry do |entry, error|
    puts "Switching model"
  end

  on :failure do |attempts|
    puts "All models exhausted"
  end
end
```

## Resources

- [Main documentation](../README.md)
- [Hooks documentation](../request_hooks.md)
- [Error handling documentation](../request_error_processing.md)
- [Retry policy documentation](../retry_policy.md)
- [Token usage documentation](../token_usage.md)
- [Cost documentation](../pricing.md)

## Help

If you have questions:

1. Check the relevant example
2. Read the main documentation
3. Open an issue on GitHub

## License

All examples are distributed under the same license as ActiveHarness.
