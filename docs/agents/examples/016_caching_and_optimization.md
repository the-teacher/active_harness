# 016 — Caching and Optimization

## Topic

How to cache agent results to improve performance and reduce costs.

## Why This Is Needed

Caching reduces the number of LLM calls, which saves money and speeds up responses. Critical for production applications under high load.

## Simple In-Memory Cache

First, define the prompt class:

```ruby
class CachedPrompt
  def call
    "You are a helpful assistant. Answer questions clearly."
  end
end
```

Then define the agent:

```ruby
class CachedAgent < ActiveHarness::Agent
  system_prompt CachedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  @@cache = {}

  def call
    cache_key = generate_cache_key

    cached = read_from_cache(cache_key)
    if cached
      @result = cached
      return
    end

    puts "[CACHE MISS] Calling agent..."
    super
    write_to_cache(cache_key, @result)
  end

  private

  def read_from_cache(key)
    result = @@cache[key]
    puts "[CACHE HIT] Using cached result" if result
    result
  end

  def write_to_cache(key, result)
    @@cache[key] = result
  end

  def generate_cache_key
    Digest::MD5.hexdigest("#{@input}:#{@context.to_json}")
  end
end

# Usage
agent1 = CachedAgent.new(input: "What is AI?")
agent1.call
puts "Result 1: #{agent1.result.output}\n"

# Second call with the same question — cache will be used
agent2 = CachedAgent.new(input: "What is AI?")
agent2.call
puts "Result 2: #{agent2.result.output}"
```

## Caching with Redis

```ruby
require 'redis'

class RedisAgent < ActiveHarness::Agent
  system_prompt RedisPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  CACHE_TTL = 3600  # 1 hour

  def call
    cache_key = generate_cache_key

    cached = Redis.current.get(cache_key)
    if cached
      puts "[CACHE HIT] Using Redis cached result"
      @result = JSON.parse(cached, object_class: OpenStruct)
      return
    end

    puts "[CACHE MISS] Calling agent..."
    super

    Redis.current.setex(cache_key, CACHE_TTL, @result.to_json)
  end

  private

  def generate_cache_key
    Digest::MD5.hexdigest("agent:#{self.class.name}:#{@input}:#{@context.to_json}")
  end
end

# Usage
agent = RedisAgent.new(input: "Question")
agent.call
puts agent.result.output
```

## Caching with Rails.cache

```ruby
class RailsCachedAgent < ActiveHarness::Agent
  system_prompt RailsCachedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  CACHE_TTL = 1.hour

  def call
    cache_key = generate_cache_key

    cached_result = Rails.cache.read(cache_key)
    if cached_result
      puts "[CACHE HIT] Using Rails cache"
      @result = cached_result
      return
    end

    puts "[CACHE MISS] Calling agent..."
    super

    Rails.cache.write(cache_key, @result, expires_in: CACHE_TTL)
  end

  private

  def generate_cache_key
    "agent:#{self.class.name}:#{Digest::MD5.hexdigest(@input)}"
  end
end
```

## Caching with Invalidation

```ruby
class SmartCachedAgent < ActiveHarness::Agent
  system_prompt SmartCachedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  def call
    cache_key = generate_cache_key

    if cache_valid?(cache_key)
      puts "[CACHE HIT] Using valid cached result"
      @result = Rails.cache.read(cache_key)
      return
    end

    puts "[CACHE MISS] Calling agent..."
    super

    Rails.cache.write(cache_key, {
      result: @result,
      timestamp: Time.now
    }, expires_in: 1.hour)
  end

  def self.invalidate_cache(pattern)
    Rails.cache.delete_matched(pattern)
  end

  private

  def generate_cache_key
    "agent:#{self.class.name}:#{Digest::MD5.hexdigest(@input)}"
  end

  def cache_valid?(cache_key)
    cached = Rails.cache.read(cache_key)
    return false unless cached

    (Time.now - cached[:timestamp]) < 30.minutes
  end
end

# Cache invalidation
SmartCachedAgent.invalidate_cache("agent:SmartCachedAgent:*")
```

## Prompt-Level Caching

```ruby
class PromptCachedAgent < ActiveHarness::Agent
  system_prompt PromptCachedPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  on :before_call do
    @cached_system_prompt = cache_system_prompt
  end

  private

  def cache_system_prompt
    cache_key = "system_prompt:#{self.class.name}"

    cached = Rails.cache.read(cache_key)
    return cached if cached

    prompt = @system_prompt
    Rails.cache.write(cache_key, prompt, expires_in: 1.day)
    prompt
  end
end
```

## Caching with Analytics

```ruby
class AnalyticsAgent < ActiveHarness::Agent
  system_prompt AnalyticsPrompt

  model do
    use provider: :openrouter, model: "mistralai/mistral-nemo"
  end

  def call
    cache_key = generate_cache_key

    cached = Rails.cache.read(cache_key)
    if cached
      log_cache_hit(cache_key)
      @result = cached
      return
    end

    log_cache_miss(cache_key)
    super

    Rails.cache.write(cache_key, @result, expires_in: 1.hour)
  end

  private

  def generate_cache_key
    "agent:#{self.class.name}:#{Digest::MD5.hexdigest(@input)}"
  end

  def log_cache_hit(cache_key)
    CacheAnalytics.create!(
      key: cache_key,
      hit: true,
      timestamp: Time.now
    )
  end

  def log_cache_miss(cache_key)
    CacheAnalytics.create!(
      key: cache_key,
      hit: false,
      timestamp: Time.now
    )
  end
end
```

## Optimization with Batching

```ruby
class BatchedAgent
  def initialize(inputs)
    @inputs = inputs
  end

  def call
    grouped = group_similar_inputs(@inputs)

    results = {}
    grouped.each do |group_key, inputs|
      group_result = process_group(inputs)
      results.merge!(group_result)
    end

    results
  end

  private

  def group_similar_inputs(inputs)
    inputs.group_by do |input|
      Digest::MD5.hexdigest(input)
    end
  end

  def process_group(inputs)
    agent = AnalysisAgent.new(input: inputs.join("\n"))
    agent.call

    inputs.each_with_object({}) do |input, acc|
      acc[input] = agent.result.output
    end
  end
end
```

## Best Practices

1. **Use appropriate TTL** — don't cache for too long
2. **Invalidate the cache** — when underlying data changes
3. **Log cache hits** — track cache effectiveness
4. **Use Redis** — for distributed caching
5. **Test** — make sure the cache works correctly
