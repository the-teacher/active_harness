# RubyLLM Integration

ActiveHarness can delegate HTTP calls to the [`ruby_llm`](https://github.com/crmne/ruby_llm) gem
instead of its built-in Net::HTTP providers. This gives you access to everything RubyLLM supports:
tools, vision, structured output, audio, and any future features — while keeping the full
ActiveHarness interface unchanged (fallback chains, retry policy, hooks, memory, streaming).

## Setup

Add `ruby_llm` to your Gemfile:

```ruby
gem "ruby_llm", ">= 1.0"
```

```bash
bundle install
```

## How it Works

Define a `custom_llm_backend` block in your agent class. The block receives a `BackendParams` struct
with the current model entry's values and must return a `RubyLLM::Chat` instance.
ActiveHarness calls `chat.ask(@input)` and wraps the response in its standard `Result` object.

```
[agent.call]
  └─► for each entry in fallback chain:
        ├─► custom_llm_backend block called with BackendParams
        ├─► returns RubyLLM::Chat
        ├─► ActiveHarness calls chat.ask(@input)
        └─► on error → retry policy → next fallback
```

## BackendParams

| Field         | Type         | Description                                    |
| ------------- | ------------ | ---------------------------------------------- |
| `model`       | String       | Model ID from the current fallback chain entry |
| `provider`    | String       | Provider name ("openrouter", "openai", …)      |
| `temperature` | Float or nil | Temperature from the current entry, or nil     |

## Basic Example

```ruby
require "ruby_llm"

RubyLLM.configure do |c|
  c.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
end

class SupportAgent < ActiveHarness::Agent
  system_prompt SupportPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo", temperature: 0.5
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
    fallback provider: :openai,     model: "gpt-4o-mini"
  end

  custom_llm_backend do |params|
    RubyLLM.chat(
      model:               params.model,
      provider:            params.provider,
      assume_model_exists: true
    ).tap { |chat| chat.with_temperature(params.temperature) if params.temperature }
  end
end

result = SupportAgent.call(input: "What is the capital of France?")
puts result.output          # => "The capital of France is Paris."
puts result.model           # => "mistralai/mistral-nemo"
puts result.execution_time  # => 1.117
```

## With Custom Deployment (Azure, Bedrock, custom URLs)

The block gives full control over how `RubyLLM::Chat` is built — useful for custom deployments
that require special parameters:

```ruby
custom_llm_backend do |params|
  RubyLLM.chat(
    model:               "my-gpt4-deployment",
    provider:            "azure",
    assume_model_exists: true
  ).with_temperature(params.temperature || 0.7)
end
```

## Streaming

Streaming works without any changes — pass a `stream:` lambda as usual:

```ruby
SupportAgent.call(
  input:  "Tell me about Ruby",
  stream: ->(token) { print token }
)
```

ActiveHarness passes the lambda to `chat.ask` automatically.

## Fallback Chain and Retry Policy

All ActiveHarness resilience features work unchanged:

```ruby
model do
  use      provider: :openrouter, model: "mistralai/mistral-nemo",
           retry_attempts: 3, retry_delay: 1.0

  fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free",
           retry_attempts: 2, retry_delay: 0.5

  fallback provider: :openai, model: "gpt-4o-mini"
end
```

On a transient error (`RateLimitError`, `ServerError`, `TimeoutError`, `OverloadedError`),
ActiveHarness retries the same model with exponential backoff, then moves to the next fallback.

## Error Mapping

RubyLLM errors are mapped to ActiveHarness errors so the fallback chain works correctly:

| RubyLLM error                                   | ActiveHarness error   | Behavior           |
| ----------------------------------------------- | --------------------- | ------------------ |
| `UnauthorizedError`                             | `InvalidApiKeyError`  | stops chain        |
| `RateLimitError`, `OverloadedError`             | `RateLimitError`      | retries → fallback |
| `ServerError`, `ServiceUnavailableError`        | `ServerError`         | retries → fallback |
| `BadRequestError`, `ContextLengthExceededError` | `InvalidRequestError` | next fallback      |
| any other `RubyLLM::Error`                      | `ProviderError`       | next fallback      |

## Hooks

All hooks work as usual:

```ruby
on :retry do |entry, error|
  puts "[retry] #{entry[:provider]}/#{entry[:model]} — #{error.message}"
end

on :failure do |attempts|
  puts "[failure] #{attempts.size} models all failed"
end
```

## Without custom_llm_backend

If `custom_llm_backend` is not defined in the agent, ActiveHarness uses its built-in Net::HTTP
providers as normal. The two approaches can coexist in different agent classes within the same app.
