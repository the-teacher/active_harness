# ActiveHarness and RubyLLM

## The Short Answer

**RubyLLM** is a transport layer — a unified Ruby API for talking to any LLM provider.  
**ActiveHarness** is an architectural framework — a structured way to organize complex AI logic.

They live at different levels of the stack and work great together.

---

## What RubyLLM Brings

RubyLLM answers the question: _"how do I talk to any LLM provider through one consistent API?"_

It's a mature, production-ready, widely-used project that covers almost everything you can do with an LLM:

- Chat (text, streaming)
- Multimodal input (images, audio, video, PDF, CSV)
- Image generation
- Embeddings
- Audio transcription
- Content moderation
- Function calling (Tools)
- Structured output (Schema)
- Rails integration with `acts_as_chat` and persistent chat history in the database
- A registry of 800+ models with metadata, pricing, and capability flags

RubyLLM is wide — it covers nearly everything you can do with an LLM. It's an excellent foundation to build on.

---

## What ActiveHarness Brings

ActiveHarness answers the question: _"how do I organize complex AI flows reliably in a production app?"_

It adds an architectural layer on top of any LLM transport:

- **Fallback chains** — try this model; if it fails, automatically move to the next one
- **Tribunals** — run multiple agents in parallel and only accept a verdict when all (or most) agree
- **Pipelines** — chain agents and tribunals into sequential flows with guard steps and early-stop conditions
- **Lifecycle hooks** — observe and modify every stage of the agent call (setup, before, after, retry, failure)
- **Memory** — explicit conversation history injection you control
- **Retry policy** — exponential backoff per-model or globally
- **Streaming** — SSE token-by-token output from any step

ActiveHarness is focused on reliability and control — the architectural layer that RubyLLM happily sits underneath.

---

## How They Fit Together

Thinking about the two projects side by side:

|                          | ActiveHarness             | RubyLLM                              |
| ------------------------ | ------------------------- | ------------------------------------ |
| **Primary goal**         | Organize complex AI flows | Uniform access to all LLM providers  |
| **Fallback chains**      | ✅ Built-in               | ❌ Not provided                      |
| **Parallel consensus**   | ✅ Tribunal               | ❌ Not provided                      |
| **Pipeline with guards** | ✅ Built-in               | ❌ Not provided                      |
| **Lifecycle hooks**      | ✅ Rich DSL               | ❌ Not provided                      |
| **Retry with backoff**   | ✅ Built-in               | ❌ Not provided                      |
| **Function calling**     | ❌ No                     | ✅ Yes                               |
| **Structured output**    | Basic `:json` parse       | ✅ Typed Schema                      |
| **Multimodal input**     | ❌ No                     | ✅ Images, audio, video, PDF         |
| **Image generation**     | ❌ No                     | ✅ Yes                               |
| **Embeddings**           | ❌ No                     | ✅ Yes                               |
| **Audio transcription**  | ❌ No                     | ✅ Yes                               |
| **Rails integration**    | Railtie + file structure  | `acts_as_chat` + DB persistence + UI |
| **Model registry**       | No                        | 800+ models with metadata            |
| **Dependencies**         | 1 (`concurrent-ruby`)     | 3 (`faraday`, `zeitwerk`, `marcel`)  |
| **Status**               | WIP, API unstable         | Production-ready                     |

---

## Using Them Together

The natural fit: **RubyLLM as the transport, ActiveHarness as the architecture.**

Use the `custom_llm_backend` DSL to delegate HTTP calls from ActiveHarness to RubyLLM. You get all of RubyLLM's provider coverage and features — tools, vision, structured output, audio — while keeping the full ActiveHarness interface: fallback chains, retry policy, lifecycle hooks, memory, and streaming.

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
```

When `custom_llm_backend` is defined, ActiveHarness calls the block for each fallback entry, receives a `RubyLLM::Chat`, calls `chat.ask(@input)`, and wraps the result in its standard `Result` object. Errors from RubyLLM are automatically mapped to ActiveHarness error classes, so retry and fallback logic works transparently — no extra glue code needed.

→ See the [RubyLLM Integration guide](ruby_llm_integration.md) for the full setup and error mapping reference.
