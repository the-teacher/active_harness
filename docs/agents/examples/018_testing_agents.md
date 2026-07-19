# 018 — Testing Agents

## Topic

How to write tests for agents, mock LLMs, and verify behavior.

## Why This Is Needed

Testing ensures code reliability and helps catch regressions. Mocking LLMs speeds up tests and makes them deterministic.

## Example with RSpec

```ruby
# spec/agents/support_agent_spec.rb
require 'rails_helper'

RSpec.describe SupportAgent do
  describe '#call' do
    context 'with valid input' do
      it 'returns a result' do
        agent = SupportAgent.new(input: "Hello!")
        agent.call

        expect(agent.result).to be_present
        expect(agent.result.output).to be_present
        expect(agent.result.model.name).to be_present
      end

      it 'includes usage information' do
        agent = SupportAgent.new(input: "Question")
        agent.call

        expect(agent.result.usage.tokens.input).to be_present
        expect(agent.result.usage.tokens.output).to be_present
        expect(agent.result.usage.tokens.total).to be_present
      end
    end

    context 'with empty input' do
      it 'raises an error' do
        agent = SupportAgent.new(input: "")

        expect { agent.call }.to raise_error(ValidationError)
      end
    end

    context 'with context' do
      it 'uses context in the prompt' do
        agent = SupportAgent.new(
          input: "Hello",
          context: { language: "English", tone: "friendly" }
        )
        agent.call

        expect(agent.result.output).to be_present
      end
    end
  end

  describe 'hooks' do
    it 'calls setup hook' do
      agent = SupportAgent.new(input: "  Hello  ")
      expect(agent).to receive(:setup).and_call_original

      agent.call
    end

    it 'calls after_call hook' do
      agent = SupportAgent.new(input: "Hello")
      expect(agent).to receive(:after_call).and_call_original

      agent.call
    end
  end
end
```

## Mocking the LLM

```ruby
# spec/agents/mocked_agent_spec.rb
require 'rails_helper'

RSpec.describe SupportAgent do
  describe '#call with mocked LLM' do
    before do
      stub_request(:post, /api\.openrouter\.io/).to_return(
        status: 200,
        body: {
          choices: [
            { message: { content: "Mocked response" } }
          ],
          usage: {
            prompt_tokens: 10,
            completion_tokens: 5
          }
        }.to_json
      )
    end

    it 'returns mocked response' do
      agent = SupportAgent.new(input: "Question")
      agent.call

      expect(agent.result.output).to eq("Mocked response")
      expect(agent.result.usage.tokens.input).to eq(10)
      expect(agent.result.usage.tokens.output).to eq(5)
    end
  end
end
```

## Testing with VCR

```ruby
# spec/agents/vcr_agent_spec.rb
require 'rails_helper'

RSpec.describe SupportAgent do
  describe '#call with VCR' do
    it 'records and replays HTTP interactions', vcr: { cassette_name: 'support_agent' } do
      agent = SupportAgent.new(input: "Hello!")
      agent.call

      expect(agent.result.output).to be_present
    end
  end
end

# spec/vcr_config.rb
VCR.configure do |config|
  config.cassette_library_dir = 'spec/cassettes'
  config.hook_into :webmock
  config.filter_sensitive_data('<API_KEY>') { ENV['OPENROUTER_API_KEY'] }
end
```

## Testing Hooks

```ruby
# spec/agents/hooks_spec.rb
require 'rails_helper'

RSpec.describe 'Agent hooks' do
  describe 'setup hook' do
    it 'normalizes input' do
      agent = SupportAgent.new(input: "  Hello  ")
      agent.call

      expect(agent.instance_variable_get(:@input)).to eq("Hello")
    end
  end

  describe 'before_call hook' do
    it 'adds language suffix' do
      agent = SupportAgent.new(
        input: "Hello",
        context: { language: "English" }
      )

      expect(agent.instance_variable_get(:@input)).to include("English")
    end
  end

  describe 'after_call hook' do
    it 'logs successful call' do
      agent = SupportAgent.new(input: "Question")

      expect(Rails.logger).to receive(:info)
      agent.call
    end
  end

  describe 'retry hook' do
    it 'logs retry attempts' do
      allow_any_instance_of(SupportAgent).to receive(:call).and_raise(
        ActiveHarness::Errors::TimeoutError.new("Timeout")
      )

      agent = SupportAgent.new(input: "Question")

      expect(Rails.logger).to receive(:warn)
      expect { agent.call }.to raise_error(ActiveHarness::Errors::AllModelsFailed)
    end
  end
end
```

## Testing Pipelines

```ruby
# spec/pipelines/analysis_pipeline_spec.rb
require 'rails_helper'

RSpec.describe AnalysisPipeline do
  describe '#call' do
    before do
      allow_any_instance_of(AnalysisAgent).to receive(:call)
      allow_any_instance_of(SentimentAgent).to receive(:call)
      allow_any_instance_of(TranslationAgent).to receive(:call)
    end

    it 'executes all steps' do
      pipeline = AnalysisPipeline.new("Text")
      results = pipeline.call

      expect(results).to include(:analysis, :sentiment, :translation)
    end

    it 'handles errors gracefully' do
      allow_any_instance_of(AnalysisAgent).to receive(:call).and_raise(
        ActiveHarness::Errors::AllModelsFailed.new("Failed")
      )

      pipeline = AnalysisPipeline.new("Text")
      results = pipeline.call

      expect(results[:error]).to be_present
    end
  end
end
```

## Testing with Factories

```ruby
# spec/factories/agent_inputs.rb
FactoryBot.define do
  factory :agent_input do
    input { "Test question" }
    context { { language: "English" } }
  end

  factory :agent_input_russian, parent: :agent_input do
    input { "Тестовый вопрос" }
    context { { language: "Russian" } }
  end
end

# spec/agents/factory_agent_spec.rb
RSpec.describe SupportAgent do
  describe '#call' do
    it 'works with factory input' do
      input = build(:agent_input)
      agent = SupportAgent.new(input: input.input, context: input.context)
      agent.call

      expect(agent.result).to be_present
    end

    it 'works with Russian input' do
      input = build(:agent_input_russian)
      agent = SupportAgent.new(input: input.input, context: input.context)
      agent.call

      expect(agent.result).to be_present
    end
  end
end
```

## Performance Testing

```ruby
# spec/agents/performance_spec.rb
require 'rails_helper'

RSpec.describe SupportAgent do
  describe 'performance' do
    it 'completes within timeout' do
      agent = SupportAgent.new(input: "Question")

      expect {
        Timeout.timeout(5) { agent.call }
      }.not_to raise_error
    end

    it 'uses reasonable tokens' do
      agent = SupportAgent.new(input: "Question")
      agent.call

      expect(agent.result.usage.tokens.total).to be < 1000
    end

    it 'costs less than threshold' do
      agent = SupportAgent.new(input: "Question")
      agent.call

      expect(agent.result.usage.cost.total).to be < 0.01
    end
  end
end
```

## Integration Tests

```ruby
# spec/integration/agent_flow_spec.rb
require 'rails_helper'

RSpec.describe 'Agent flow' do
  it 'completes full pipeline' do
    analysis_agent = AnalysisAgent.new(input: "Text")
    analysis_agent.call
    expect(analysis_agent.result).to be_present

    sentiment_agent = SentimentAgent.new(input: "Text")
    sentiment_agent.call
    expect(sentiment_agent.result).to be_present

    translation_agent = TranslationAgent.new(
      input: "Text",
      context: { target_language: "English" }
    )
    translation_agent.call
    expect(translation_agent.result).to be_present
  end
end
```

## Best Practices

1. **Mock the LLM** — use WebMock or VCR
2. **Test hooks** — make sure they are called
3. **Test error paths** — verify error handling
4. **Use factories** — for generating test data
5. **Write integration tests** — verify complete flows
