# API Keys

Each provider reads its key from an environment variable. Set only the keys for the providers you intend to use.

| Provider       | Environment variable                                                          |
| -------------- | ----------------------------------------------------------------------------- |
| OpenAI         | `OPENAI_API_KEY`                                                              |
| Anthropic      | `ANTHROPIC_API_KEY`                                                           |
| Google Gemini  | `GEMINI_API_KEY`                                                              |
| Groq           | `GROQ_API_KEY`                                                                |
| OpenRouter     | `OPENROUTER_API_KEY`                                                          |
| xAI (Grok)     | `XAI_API_KEY`                                                                 |
| DeepSeek       | `DEEPSEEK_API_KEY`                                                            |
| Mistral        | `MISTRAL_API_KEY`                                                             |
| Ollama (local) | `OLLAMA_API_BASE` (optional, default: localhost)                              |
| Perplexity     | `PERPLEXITY_API_KEY`                                                          |
| GPUStack       | `GPUSTACK_API_BASE`, `GPUSTACK_API_KEY` (optional)                            |
| Azure OpenAI   | `AZURE_API_BASE`, `AZURE_API_KEY` (or `AZURE_AI_AUTH_TOKEN`)                  |
| Custom         | `config.custom["Name"]["url"]`, `config.custom["Name"]["api_key"]` (optional) |

## Plain Ruby

Export variables in your shell or load them from a `.env` file with [`dotenv`](https://github.com/bkeepers/dotenv):

```bash
export OPENAI_API_KEY="sk-..."
export OPENROUTER_API_KEY="sk-or-..."
```

Or in code:

```ruby
require "dotenv/load"
```

## Ruby on Rails

Store keys in `config/credentials.yml.enc`:

```bash
rails credentials:edit
```

```yaml
openai_api_key: sk-...
anthropic_api_key: sk-ant-...
```

Or use a `.env` file with [`dotenv-rails`](https://github.com/bkeepers/dotenv):

```ruby
# Gemfile
gem "dotenv-rails"
```

```bash
# .env  (add to .gitignore)
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
OPENROUTER_API_KEY=sk-or-v1-...
```

## Using ENV keys with the configure block

If you use `ActiveHarness.configure`, you can read the keys explicitly:

```ruby
ActiveHarness.configure do |config|
  config.openai_api_key    = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # ...
end
```

If `configure` is not called, all keys are read from ENV automatically — existing setups keep working without changes.
