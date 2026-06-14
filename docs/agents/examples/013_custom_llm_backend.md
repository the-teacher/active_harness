# 013 — Custom LLM Backends

## Topic

How to connect any OpenAI-compatible endpoint, or delegate HTTP calls to `ruby_llm`.

## Why This Is Needed

ActiveHarness has 16 built-in providers (OpenAI, Anthropic, Ollama, Gemini, etc.). When you need a local server, an internal API, or a model not covered by a built-in provider, there are two escape hatches — both work with the full fallback chain, hooks, and streaming.

## Two Mechanisms at a Glance

```text
provider: :custom, name: "..."   — any OpenAI-compatible HTTP endpoint
custom_llm_backend do |params|   — delegate all calls to ruby_llm
```

---

## Mechanism 1 — OpenAI-Compatible Endpoint

Use `provider: :custom` with a named entry in the configuration. Supports any server that speaks the OpenAI chat-completions API (LM Studio, llama.cpp server, vLLM, etc.).

### Configuration

```ruby
# config/initializers/active_harness.rb
ActiveHarness.configure do |config|
  config.custom["MyLocal"]["url"]     = "http://localhost:8080/v1/chat/completions"
  config.custom["MyLocal"]["api_key"] = ENV["MYLOCAL_API_KEY"]  # omit if no auth needed

  config.custom["SecondProvider"]["url"]     = "https://second.example.com/v1/chat/completions"
  config.custom["SecondProvider"]["api_key"] = ENV["SECOND_API_KEY"]
end
```

### Agent

First, define the prompt class:

```ruby
class LocalPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class LocalAgent < ActiveHarness::Agent
  system_prompt LocalPrompt

  model do
    use      provider: :custom, name: "MyLocal",        model: "llama3.2"
    fallback provider: :custom, name: "SecondProvider", model: "mixtral"
  end
end

# Usage
agent = LocalAgent.new(input: "Question")
agent.call
puts agent.result.output
```

### Fallback to a Built-in Provider

First, define the prompt class:

```ruby
class HybridPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class HybridAgent < ActiveHarness::Agent
  system_prompt HybridPrompt

  model do
    # try the local server first
    use      provider: :custom,      name: "MyLocal", model: "llama3.2"
    # fall back to a cloud model if the local server is unavailable
    fallback provider: :openrouter,  model: "mistralai/mistral-nemo"
  end
end
```

---

## Mechanism 2 — ruby_llm Backend

`custom_llm_backend` replaces the built-in HTTP layer with `ruby_llm`. The block receives a `BackendParams` struct and must return a `RubyLLM::Chat` object.

```text
BackendParams.model        # model name from the `use` / `fallback` line
BackendParams.provider     # provider name as a string
BackendParams.temperature  # temperature value (may be nil)
```

All ActiveHarness features work unchanged: fallback chains, hooks, streaming, retry policy.

### Agent

First, define the prompt class:

```ruby
class RubyLLMPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class RubyLLMAgent < ActiveHarness::Agent
  system_prompt RubyLLMPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  custom_llm_backend do |params|
    RubyLLM.chat(
      model:               params.model,
      provider:            params.provider,
      assume_model_exists: true
    ).tap do |chat|
      chat.with_temperature(params.temperature) if params.temperature
    end
  end
end

# Usage
agent = RubyLLMAgent.new(input: "Question")
agent.call
puts agent.result.output
```

### With Streaming

```ruby
class StreamingRubyLLMAgent < ActiveHarness::Agent
  system_prompt RubyLLMPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  custom_llm_backend do |params|
    RubyLLM.chat(
      model:               params.model,
      provider:            params.provider,
      assume_model_exists: true
    )
  end
end

token_stream = ->(token) do
  print token
end

agent = StreamingRubyLLMAgent.new(
  input: "Tell me about the history of computers",
  token: token_stream
)
agent.call
```

### With Hooks

```ruby
class MonitoredRubyLLMAgent < ActiveHarness::Agent
  system_prompt RubyLLMPrompt

  model do
    use      provider: :openrouter, model: "mistralai/mistral-nemo"
    fallback provider: :openrouter, model: "meta-llama/llama-3.3-70b-instruct:free"
  end

  custom_llm_backend do |params|
    RubyLLM.chat(
      model:               params.model,
      provider:            params.provider,
      assume_model_exists: true
    )
  end

  on :setup do
    @start_time = Time.now
  end

  on :after_call do |result|
    elapsed = (Time.now - @start_time).round(2)
    puts "[SUCCESS] #{result.model.name} — #{elapsed}s"
  end

  on :retry do |entry, error|
    puts "[RETRY] #{entry[:model]}: #{error.message}"
  end
end
```

---

## Choosing a Mechanism

| Situation                                         | Mechanism                        |
| ------------------------------------------------- | -------------------------------- |
| Local server (Ollama, LM Studio, vLLM, llama.cpp) | `provider: :custom, name: "..."` |
| Internal corporate API (OpenAI-compatible)        | `provider: :custom, name: "..."` |
| Any provider supported by `ruby_llm`              | `custom_llm_backend`             |
| You want advanced `ruby_llm` chat features        | `custom_llm_backend`             |

## Best Practices

1. **Use `:custom` for OpenAI-compatible servers** — no extra gems required
2. **Use `custom_llm_backend` for ruby_llm** — gives access to ruby_llm's full feature set
3. **Always add a fallback** — a cloud provider as a safety net for local servers
4. **Store credentials in ENV** — never hardcode URLs or keys
5. **Test connectivity** — local servers can be unavailable; the fallback chain handles this automatically
