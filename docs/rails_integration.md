# Using with Ruby on Rails

## 1. Add the gem

```ruby
# Gemfile
gem "active_harness"
```

```bash
bundle install
```

## 2. Set API keys

Add `dotenv-rails` to your Gemfile:

```ruby
gem "dotenv-rails"
```

```bash
bundle install
```

Create `.env` in Rails root and add it to `.gitignore`:

```bash
# .env
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GEMINI_API_KEY=...
GROQ_API_KEY=...
OPENROUTER_API_KEY=sk-or-v1-...
```

```bash
echo ".env" >> .gitignore
```

Set only the keys for the providers you use.

## 3. Run the install generator

```bash
rails generate active_harness:install
```

This creates the `app/ai/` directory structure with example classes, a controller, and routes.  
Files are only created if they don't already exist — running the generator on an existing project is safe.

```
app/
└── ai/
    ├── agents/
    │   ├── support_agent.rb
    │   └── support_guard_agent.rb
    ├── prompts/
    │   ├── support_prompt.rb
    │   └── support_guard_prompt.rb
    ├── tribunals/
    │   └── support_guard_tribunal.rb
    ├── pipelines/
    │   └── support_pipeline.rb
    └── memory/
        └── app_memory.rb
app/controllers/
    └── ai_support_controller.rb
```

Routes injected into `config/routes.rb`:

```
POST /ai/agent          — single agent call
POST /ai/agent_memory   — agent call with session memory
POST /ai/tribunal       — content moderation check
POST /ai/pipeline       — full pipeline run
GET  /ai/agent_stream   — streaming response (SSE)
```

## 4. Try it

```bash
curl -s -X POST http://localhost:3000/ai/agent \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello!"}'

# {"output":"Hi, how can I assist you today?","model":"mistralai/mistral-nemo","time":2.862}
```

## Generators

Generate individual components by name:

```
rails generate active_harness:prompt   Support
rails generate active_harness:agent    Support
rails generate active_harness:tribunal Politeness
rails generate active_harness:pipeline Support
rails generate active_harness:memory   App
```

| Command                        | File created                        |
| ------------------------------ | ----------------------------------- |
| `active_harness:prompt Name`   | `app/ai/prompts/name_prompt.rb`     |
| `active_harness:agent Name`    | `app/ai/agents/name_agent.rb`       |
| `active_harness:tribunal Name` | `app/ai/tribunals/name_tribunal.rb` |
| `active_harness:pipeline Name` | `app/ai/pipelines/name_pipeline.rb` |
| `active_harness:memory Name`   | `app/ai/memory/name_memory.rb`      |

## Autoloading

All files under `app/ai/` are autoloaded automatically — no `require` calls needed.
