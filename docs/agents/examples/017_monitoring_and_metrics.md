# 017 — Monitoring and Metrics

## Topic

How to track agent performance, collect metrics, and monitor errors.

## Why This Is Needed

Monitoring helps identify problems, optimize costs, and improve quality. Critical for production applications.

## Basic Monitoring

First, define the prompt class:

```ruby
class MonitoredPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class MonitoredAgent < ActiveHarness::Agent
  system_prompt MonitoredPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :setup do
    @start_time = Time.now
    @metrics = {
      input_length: @input.length,
      context_keys: @context.keys
    }
  end

  on :before_call do
    @metrics[:before_call_time] = Time.now
  end

  on :after_call do |result|
    elapsed = Time.now - @start_time

    @metrics.merge!({
      success: true,
      model: result.model,
      execution_time: result.execution_time,
      total_time: elapsed,
      input_tokens: result.usage[:input_tokens],
      output_tokens: result.usage[:output_tokens],
      total_tokens: result.usage[:total_tokens],
      cost: result.cost,
      output_length: result.output.length
    })

    log_metrics
  end

  on :retry do |entry, error|
    @metrics[:retries] ||= 0
    @metrics[:retries] += 1
    @metrics[:last_error] = error.class.name
  end

  on :failure do |attempts|
    @metrics[:success] = false
    @metrics[:failure_count] = attempts.size
    @metrics[:total_time] = Time.now - @start_time
    log_metrics
  end

  private

  def log_metrics
    puts "\n=== METRICS ==="
    @metrics.each do |key, value|
      puts "#{key}: #{value}"
    end
  end
end

# Usage
agent = MonitoredAgent.new(input: "Question")
agent.call
```

## Saving Metrics to a Database

First, define the prompt class:

```ruby
class DatabaseMonitoredPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class DatabaseMonitoredAgent < ActiveHarness::Agent
  system_prompt DatabaseMonitoredPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :setup do
    @start_time = Time.now
    @session_id = SecureRandom.uuid
  end

  on :after_call do |result|
    save_metrics(result, success: true)
  end

  on :failure do |attempts|
    save_metrics(nil, success: false, attempts: attempts)
  end

  private

  def save_metrics(result, success:, attempts: nil)
    AgentMetric.create!(
      session_id: @session_id,
      agent_class: self.class.name,
      input: @input,
      input_length: @input.length,
      success: success,
      model: result&.model,
      execution_time: result&.execution_time,
      input_tokens: result&.usage&.dig(:input_tokens),
      output_tokens: result&.usage&.dig(:output_tokens),
      total_tokens: result&.usage&.dig(:total_tokens),
      cost: result&.cost,
      output_length: result&.output&.length,
      retry_count: attempts&.size || 0,
      timestamp: Time.now
    )
  end
end

# Database model
class AgentMetric < ApplicationRecord
  self.table_name = 'agent_metrics'

  scope :successful, -> { where(success: true) }
  scope :failed, -> { where(success: false) }
  scope :by_agent, ->(agent_class) { where(agent_class: agent_class) }
  scope :recent, -> { order(timestamp: :desc).limit(100) }

  def self.success_rate
    total = count
    successful.count.to_f / total * 100
  end

  def self.average_execution_time
    successful.average(:execution_time)
  end

  def self.total_cost
    successful.sum(:cost)
  end

  def self.average_tokens
    successful.average(:total_tokens)
  end
end
```

## Migration for the Metrics Table

```ruby
# db/migrate/xxx_create_agent_metrics.rb
class CreateAgentMetrics < ActiveRecord::Migration[7.0]
  def change
    create_table :agent_metrics, id: :uuid do |t|
      t.uuid :session_id, null: false
      t.string :agent_class, null: false
      t.text :input
      t.integer :input_length
      t.boolean :success, null: false
      t.string :model
      t.float :execution_time
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :total_tokens
      t.decimal :cost, precision: 10, scale: 6
      t.integer :output_length
      t.integer :retry_count, default: 0
      t.timestamp :timestamp, null: false

      t.timestamps
    end

    add_index :agent_metrics, :session_id
    add_index :agent_metrics, :agent_class
    add_index :agent_metrics, :success
    add_index :agent_metrics, :timestamp
  end
end
```

## Prometheus Integration

First, define the prompt class:

```ruby
class PrometheusPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
require 'prometheus/client'
require 'prometheus/client/push'

class PrometheusAgent < ActiveHarness::Agent
  system_prompt PrometheusPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  @@prometheus = Prometheus::Client.registry

  # Metrics
  @@execution_time = @@prometheus.histogram(
    :agent_execution_time_seconds,
    docstring: 'Agent execution time in seconds',
    labels: [:agent_class, :model]
  )

  @@tokens_used = @@prometheus.counter(
    :agent_tokens_used_total,
    docstring: 'Total tokens used',
    labels: [:agent_class, :model]
  )

  @@cost = @@prometheus.counter(
    :agent_cost_total,
    docstring: 'Total cost',
    labels: [:agent_class, :model]
  )

  @@errors = @@prometheus.counter(
    :agent_errors_total,
    docstring: 'Total errors',
    labels: [:agent_class, :error_type]
  )

  on :after_call do |result|
    labels = { agent_class: self.class.name, model: result.model }

    @@execution_time.observe(result.execution_time, labels: labels)
    @@tokens_used.increment(result.usage[:total_tokens], labels: labels)
    @@cost.increment(result.cost, labels: labels)
  end

  on :retry do |entry, error|
    labels = { agent_class: self.class.name, error_type: error.class.name }
    @@errors.increment(labels: labels)
  end
end
```

## Sentry Integration

First, define the prompt class:

```ruby
class SentryPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class SentryAgent < ActiveHarness::Agent
  system_prompt SentryPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :after_call do |result|
    Sentry.capture_message("Agent call successful", level: 'info', extra: {
      agent: self.class.name,
      model: result.model,
      execution_time: result.execution_time,
      tokens: result.usage[:total_tokens],
      cost: result.cost
    })
  end

  on :retry do |entry, error|
    Sentry.capture_exception(error, extra: {
      agent: self.class.name,
      model: entry[:model],
      input: @input
    })
  end

  on :failure do |attempts|
    Sentry.capture_message("Agent failed", level: 'error', extra: {
      agent: self.class.name,
      attempts: attempts.size,
      errors: failure_messages(attempts)
    })
  end

  private

  def failure_messages(attempts)
    attempts.map do |a|
      a[:error].message
    end
  end
end
```

## Metrics Dashboard

```ruby
class Ai::MetricsController < ApplicationController
  def dashboard
    @metrics = {
      success_rate: AgentMetric.success_rate,
      average_execution_time: AgentMetric.average_execution_time,
      total_cost: AgentMetric.total_cost,
      average_tokens: AgentMetric.average_tokens,
      recent_metrics: AgentMetric.recent
    }

    render :dashboard
  end

  def by_agent
    agent_class = params[:agent_class]
    @metrics = AgentMetric.by_agent(agent_class).recent

    render json: @metrics
  end

  def cost_analysis
    @cost_by_model = AgentMetric.group(:model).sum(:cost)
    @cost_by_agent = AgentMetric.group(:agent_class).sum(:cost)

    render json: {
      by_model: @cost_by_model,
      by_agent: @cost_by_agent
    }
  end
end
```

## Best Practices

1. **Collect metrics** — track all important parameters
2. **Use the right tools** — Prometheus, Sentry, DataDog
3. **Analyze data** — look for trends and anomalies
4. **Optimize** — use metrics to drive improvements
5. **Monitor costs** — track LLM spending
