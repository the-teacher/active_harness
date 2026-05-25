# Supported Providers

**Built-in:**

- [OpenAI](#openai)
- [Anthropic](#anthropic)
- [Gemini](#gemini)
- [Groq](#groq)
- [OpenRouter](#openrouter)
- [xAI (Grok)](#xai-grok)
- [DeepSeek](#deepseek)
- [Mistral](#mistral)
- [Perplexity](#perplexity)
- [Ollama](#ollama)
- [GPUStack](#gpustack)
- [Azure OpenAI](#azure-openai)

**Stubs (require external gem):**

- [AWS Bedrock](#aws-bedrock)
- [Google Vertex AI](#google-vertex-ai)

**Custom:**

- [Any OpenAI-compatible endpoint](#custom-provider)
- [Via RubyLLM backend](#using-rubyllm-as-a-backend)

---

## Built-in Providers

### OpenAI

|                   |                                              |
| ----------------- | -------------------------------------------- |
| **Key** `:openai` |
| **Env var**       | `OPENAI_API_KEY`                             |
| **API**           | Native                                       |
| **Default URL**   | `https://api.openai.com/v1/chat/completions` |

```ruby
use provider: :openai, model: "gpt-4o-mini"
```

---

### Anthropic

|                      |                                         |
| -------------------- | --------------------------------------- |
| **Key** `:anthropic` |
| **Env var**          | `ANTHROPIC_API_KEY`                     |
| **API**              | Native (Messages API)                   |
| **Default URL**      | `https://api.anthropic.com/v1/messages` |

```ruby
use provider: :anthropic, model: "claude-3-haiku-20240307"
```

---

### Gemini

|                   |                                                                            |
| ----------------- | -------------------------------------------------------------------------- |
| **Key** `:gemini` |
| **Env var**       | `GEMINI_API_KEY`                                                           |
| **API**           | OpenAI-compatible                                                          |
| **Default URL**   | `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` |

```ruby
use provider: :gemini, model: "gemini-2.0-flash"
```

---

### Groq

|                 |                                                   |
| --------------- | ------------------------------------------------- |
| **Key** `:groq` |
| **Env var**     | `GROQ_API_KEY`                                    |
| **API**         | OpenAI-compatible                                 |
| **Default URL** | `https://api.groq.com/openai/v1/chat/completions` |

```ruby
use provider: :groq, model: "llama-3.1-8b-instant"
```

---

### OpenRouter

|                       |                                                 |
| --------------------- | ----------------------------------------------- |
| **Key** `:openrouter` |
| **Env var**           | `OPENROUTER_API_KEY`                            |
| **API**               | OpenAI-compatible                               |
| **Default URL**       | `https://openrouter.ai/api/v1/chat/completions` |

OpenRouter proxies hundreds of models from many providers under a single API key.

```ruby
use provider: :openrouter, model: "mistralai/mistral-nemo"
```

---

### xAI (Grok)

|                 |                                        |
| --------------- | -------------------------------------- |
| **Key** `:xai`  |
| **Env var**     | `XAI_API_KEY`                          |
| **API**         | OpenAI-compatible                      |
| **Default URL** | `https://api.x.ai/v1/chat/completions` |

```ruby
use provider: :xai, model: "grok-3-mini"
```

---

### DeepSeek

|                     |                                                |
| ------------------- | ---------------------------------------------- |
| **Key** `:deepseek` |
| **Env var**         | `DEEPSEEK_API_KEY`                             |
| **API**             | OpenAI-compatible                              |
| **Default URL**     | `https://api.deepseek.com/v1/chat/completions` |

```ruby
use provider: :deepseek, model: "deepseek-chat"
```

---

### Mistral

|                    |                                              |
| ------------------ | -------------------------------------------- |
| **Key** `:mistral` |
| **Env var**        | `MISTRAL_API_KEY`                            |
| **API**            | OpenAI-compatible                            |
| **Default URL**    | `https://api.mistral.ai/v1/chat/completions` |

```ruby
use provider: :mistral, model: "mistral-small-latest"
```

---

### Perplexity

|                       |                                              |
| --------------------- | -------------------------------------------- |
| **Key** `:perplexity` |
| **Env var**           | `PERPLEXITY_API_KEY`                         |
| **API**               | OpenAI-compatible                            |
| **Default URL**       | `https://api.perplexity.ai/chat/completions` |

```ruby
use provider: :perplexity, model: "sonar"
```

---

### Ollama

|                   |                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------- |
| **Key** `:ollama` |
| **Env var**       | `OLLAMA_API_BASE` (optional, default: `http://localhost:11434`), `OLLAMA_API_KEY` (optional) |
| **API**           | OpenAI-compatible                                                                            |

Local inference server. No API key required unless running behind an authenticated proxy.

```ruby
use provider: :ollama, model: "llama3.2"
```

---

### GPUStack

|                     |                                                               |
| ------------------- | ------------------------------------------------------------- |
| **Key** `:gpustack` |
| **Env var**         | `GPUSTACK_API_BASE` (required), `GPUSTACK_API_KEY` (optional) |
| **API**             | OpenAI-compatible                                             |

Self-hosted GPU inference server.

```ruby
use provider: :gpustack, model: "Qwen/Qwen2.5-7B-Instruct-GGUF"
```

---

### Azure OpenAI

|                  |                                                                                   |
| ---------------- | --------------------------------------------------------------------------------- |
| **Key** `:azure` |
| **Config**       | `azure_api_base`, `azure_api_key` (or `azure_ai_auth_token`), `azure_api_version` |
| **API**          | OpenAI-compatible (deployment-based)                                              |

The `model:` value is the **deployment name** from the Azure portal, not the underlying model name.

```ruby
ActiveHarness.configure do |config|
  config.azure_api_base = "https://my-resource.openai.azure.com"
  config.azure_api_key  = ENV["AZURE_API_KEY"]
end
```

```ruby
use provider: :azure, model: "my-gpt4o-deployment"
```

---

## Stub Providers

These providers require external dependencies that are not bundled with ActiveHarness.
When used, they raise `ProviderUnavailableError` and the agent automatically falls through to the next fallback in the chain.

### AWS Bedrock

Requires AWS Signature V4 request signing. Use a dedicated gem (e.g. `active_harness-bedrock`, not yet released).

```ruby
model do
  use      provider: :bedrock,   model: "anthropic.claude-3-5-sonnet-20241022-v2:0"
  fallback provider: :anthropic, model: "claude-3-5-sonnet-20241022"
end
```

### Google Vertex AI

Requires Google Cloud OAuth2 / Service Account credentials (`googleauth` gem). For most use cases, the `:gemini` provider is a simpler alternative (plain API key, no OAuth).

```ruby
model do
  use      provider: :vertexai, model: "gemini-2.0-flash"
  fallback provider: :gemini,   model: "gemini-2.0-flash"
end
```

---

## Custom Provider

For any OpenAI-compatible endpoint not listed above, use the `:custom` provider:

```ruby
ActiveHarness.configure do |config|
  config.custom["MyLocal"]["url"]     = "http://localhost:8080/v1/chat/completions"
  config.custom["MyLocal"]["api_key"] = ENV["MYLOCAL_API_KEY"]  # omit if no auth needed
end
```

```ruby
use provider: :custom, name: "MyLocal", model: "llama3.2"
```

→ See [Configuration reference](configuration.md) for full custom provider options.

---

## Using RubyLLM as a Backend

If you need features not covered by the built-in providers (tools, vision, structured output, audio), you can delegate HTTP calls to the `ruby_llm` gem via the `ruby_llm_backend` DSL — all fallback, retry, hooks, and memory features remain fully functional.

→ See [RubyLLM Integration guide](ruby_llm_integration.md).
