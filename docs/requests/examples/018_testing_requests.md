# 018 — Testing Requests

## Topic

How to write tests for requests, mock LLMs, and verify behavior.

## Why This Is Needed

Testing ensures code reliability and helps catch regressions. Mocking LLMs speeds up tests and makes them deterministic.

## Example with RSpec

```ruby
# spec/requests/support_request_spec.rb
require 'rails_helper'

RSpec.describe SupportRequest do
  describe '#call' do
    context 'with valid input' do
      it 'returns a result' do
        request = SupportRequest.new(input: "Hello!")
        request.call

        expect(request.result).to be_present
        expect(request.result.output).to be_present
        expect(request.result.model.name).to be_present
      end

      it 'includes usage information' do
        request = SupportRequest.new(input: "Question")
        request.call

        expect(request.result.usage.tokens.input).to be_present
        expect(request.result.usage.tokens.output).to be_present
        expect(request.result.usage.tokens.total).to be_present
      end
    end

    context 'with empty input' do
      it 'raises an error' do
        request = SupportRequest.new(input: "")

        expect { request.call }.to raise_error(ValidationError)
      end
    end

    context 'with context' do
      it 'uses context in the prompt' do
        request = SupportRequest.new(
          input: "Hello",
          context: { language: "English", tone: "friendly" }
        )
        request.call

        expect(request.result.output).to be_present
      end
    end
  end

  describe 'hooks' do
    it 'calls setup hook' do
      request = SupportRequest.new(input: "  Hello  ")
      expect(request).to receive(:setup).and_call_original

      request.call
    end

    it 'calls after_call hook' do
      request = SupportRequest.new(input: "Hello")
      expect(request).to receive(:after_call).and_call_original

      request.call
    end
  end
end
```

## Mocking the LLM

```ruby
# spec/requests/mocked_request_spec.rb
require 'rails_helper'

RSpec.describe SupportRequest do
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
      request = SupportRequest.new(input: "Question")
      request.call

      expect(request.result.output).to eq("Mocked response")
      expect(request.result.usage.tokens.input).to eq(10)
      expect(request.result.usage.tokens.output).to eq(5)
    end
  end
end
```

## Testing with VCR

```ruby
# spec/requests/vcr_request_spec.rb
require 'rails_helper'

RSpec.describe SupportRequest do
  describe '#call with VCR' do
    it 'records and replays HTTP interactions', vcr: { cassette_name: 'support_request' } do
      request = SupportRequest.new(input: "Hello!")
      request.call

      expect(request.result.output).to be_present
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
# spec/requests/hooks_spec.rb
require 'rails_helper'

RSpec.describe 'Request hooks' do
  describe 'setup hook' do
    it 'normalizes input' do
      request = SupportRequest.new(input: "  Hello  ")
      request.call

      expect(request.instance_variable_get(:@input)).to eq("Hello")
    end
  end

  describe 'before_call hook' do
    it 'adds language suffix' do
      request = SupportRequest.new(
        input: "Hello",
        context: { language: "English" }
      )

      expect(request.instance_variable_get(:@input)).to include("English")
    end
  end

  describe 'after_call hook' do
    it 'logs successful call' do
      request = SupportRequest.new(input: "Question")

      expect(Rails.logger).to receive(:info)
      request.call
    end
  end

  describe 'retry hook' do
    it 'logs retry attempts' do
      allow_any_instance_of(SupportRequest).to receive(:call).and_raise(
        ActiveHarness::Errors::TimeoutError.new("Timeout")
      )

      request = SupportRequest.new(input: "Question")

      expect(Rails.logger).to receive(:warn)
      expect { request.call }.to raise_error(ActiveHarness::Errors::AllModelsFailed)
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
      allow_any_instance_of(AnalysisRequest).to receive(:call)
      allow_any_instance_of(SentimentRequest).to receive(:call)
      allow_any_instance_of(TranslationRequest).to receive(:call)
    end

    it 'executes all steps' do
      pipeline = AnalysisPipeline.new("Text")
      results = pipeline.call

      expect(results).to include(:analysis, :sentiment, :translation)
    end

    it 'handles errors gracefully' do
      allow_any_instance_of(AnalysisRequest).to receive(:call).and_raise(
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
# spec/factories/request_inputs.rb
FactoryBot.define do
  factory :request_input do
    input { "Test question" }
    context { { language: "English" } }
  end

  factory :request_input_russian, parent: :request_input do
    input { "Тестовый вопрос" }
    context { { language: "Russian" } }
  end
end

# spec/requests/factory_request_spec.rb
RSpec.describe SupportRequest do
  describe '#call' do
    it 'works with factory input' do
      input = build(:request_input)
      request = SupportRequest.new(input: input.input, context: input.context)
      request.call

      expect(request.result).to be_present
    end

    it 'works with Russian input' do
      input = build(:request_input_russian)
      request = SupportRequest.new(input: input.input, context: input.context)
      request.call

      expect(request.result).to be_present
    end
  end
end
```

## Performance Testing

```ruby
# spec/requests/performance_spec.rb
require 'rails_helper'

RSpec.describe SupportRequest do
  describe 'performance' do
    it 'completes within timeout' do
      request = SupportRequest.new(input: "Question")

      expect {
        Timeout.timeout(5) { request.call }
      }.not_to raise_error
    end

    it 'uses reasonable tokens' do
      request = SupportRequest.new(input: "Question")
      request.call

      expect(request.result.usage.tokens.total).to be < 1000
    end

    it 'costs less than threshold' do
      request = SupportRequest.new(input: "Question")
      request.call

      expect(request.result.usage.cost.total).to be < 0.01
    end
  end
end
```

## Integration Tests

```ruby
# spec/integration/request_flow_spec.rb
require 'rails_helper'

RSpec.describe 'Request flow' do
  it 'completes full pipeline' do
    analysis_request = AnalysisRequest.new(input: "Text")
    analysis_request.call
    expect(analysis_request.result).to be_present

    sentiment_request = SentimentRequest.new(input: "Text")
    sentiment_request.call
    expect(sentiment_request.result).to be_present

    translation_request = TranslationRequest.new(
      input: "Text",
      context: { target_language: "English" }
    )
    translation_request.call
    expect(translation_request.result).to be_present
  end
end
```

## Best Practices

1. **Mock the LLM** — use WebMock or VCR
2. **Test hooks** — make sure they are called
3. **Test error paths** — verify error handling
4. **Use factories** — for generating test data
5. **Write integration tests** — verify complete flows
