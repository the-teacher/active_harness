# Tribunal Streaming — Live Events via SSE

Tribunals run agents in parallel and produce a final verdict.
By passing a `stream:` lambda, you can push each tribunal lifecycle event
to the browser in real time over a single SSE connection — without polling.

---

## How It Works

The tribunal accepts two optional streaming parameters:

| Parameter | Lambda signature           | What it receives                                  |
| --------- | -------------------------- | ------------------------------------------------- |
| `stream:` | `->(source, event, *args)` | `:tribunal` events and `:agent` events from every agent the tribunal launches |
| `token:`  | `->(chunk) {}`             | Raw token chunks (only if agents stream tokens)   |

The `stream:` lambda is called from inside lifecycle hooks as each event occurs:
agent launched, agent completed, agent failed, verdict computed.

On the Rails side you use `ActionController::Live` to keep the HTTP connection
open and push events as `text/event-stream` (SSE).

---

## Step 1 — Add stream hooks to the Tribunal

```ruby
class PolitenessLifecycleTribunal < ActiveHarness::Tribunal
  def initialize(input:, token: nil, stream: nil)
    agents = PolitenessTribunal::MODELS.map do |model|
      PolitenessAgent.new(models: [{ provider: :openrouter, model: model }])
    end
    super(input: input, agents: agents, token: token, stream: stream)
  end

  verdict :majority, may_fail: 1 do |result|
    result.processed["result"] == true
  end

  on(:before_agent) { |agent, index| @stream&.call(:tribunal, :agent_start, index) }
  on(:after_agent)  { |result, index| @stream&.call(:tribunal, :agent_done, result, index) }
  on(:agent_error)  { |name, err, index| @stream&.call(:tribunal, :agent_error, name, err, index) }
  on(:after_call)   { |results, _errors| @stream&.call(:tribunal, :all_done) }
  after(:verdict)   { |verdict| @stream&.call(:tribunal, :verdict, verdict) }
end
```

The `&.` guard means the hooks are completely silent when `stream` is `nil` —
the same tribunal class works for both plain and live-sidebar versions.

---

## Step 2 — Include ActionController::Live

```ruby
module Ai
  class TribunalsController < ApplicationController
    include ActionController::Live
    layout "ai"

    skip_before_action :verify_authenticity_token
  end
end
```

---

## Step 3 — Add routes

```ruby
scope :tribunals, as: :tribunals do
  get "politeness/lifecycle",        to: "tribunals#politeness_lifecycle"
  get "politeness/lifecycle/stream", to: "tribunals#politeness_lifecycle_stream",
                                     as: :politeness_lifecycle_stream
end
```

---

## Step 4 — The streaming action

```ruby
# GET /ai/tribunals/politeness/lifecycle/stream?input=...
def politeness_lifecycle_stream
  prepare_sse_response

  input      = params.require(:input)
  sse_events = ActionController::Live::SSE.new(response.stream, event: "lifecycle")
  sse_done   = ActionController::Live::SSE.new(response.stream, event: "message")

  stream = ->(source, event, *args) do
    payload = case source
              when :tribunal then tribunal_event_message(event, args).merge(source: "tribunal")
              when :agent    then agent_event_message(event, args).merge(source: "agent")
              end
    sse_events.write(payload.to_json) if payload
  rescue IOError, ActionController::Live::ClientDisconnected
  end

  tribunal = PolitenessLifecycleTribunal.new(input: input, stream: stream)
  stream.call(:tribunal, :tribunal_start, PolitenessTribunal::MODELS.size)
  tribunal.call

  sse_done.write({
    done:   true,
    time:   tribunal.execution_time,
    errors: tribunal.errors.map { |e| { agent: e[:agent], error: e[:error].message } }
  }.to_json)

rescue ActionController::Live::ClientDisconnected
rescue StandardError => e
  sse_done.write({ error: "#{e.class.name.split('::').last}: #{e.message}" }.to_json) rescue nil
  sse_done.write({ done: true }.to_json) rescue nil
ensure
  sse_done.close
end
```

Two SSE wrappers share the same raw stream but use different event names
(`lifecycle` vs `message`) so the browser routes them independently.

---

## Step 5 — Translate events to SSE payloads

```ruby
private

def tribunal_event_message(event, args)
  case event
  when :tribunal_start
    { event: "tribunal_start",
      text:  "Tribunal started — launching #{args[0]} agents in parallel…",
      level: "info" }
  when :agent_start
    index = args[0]
    { event: "agent_start",
      text:  "Agent #{index + 1} launched",
      level: "info",
      index: index }
  when :agent_done
    result, index = args
    polite = result.processed&.dig("result") == true
    { event:  "agent_done",
      text:   "Agent #{index + 1} done: #{result.model.name} (#{result.execution_time}s)",
      level:  polite ? "success" : "warning",
      index:  index,
      model:  result.model.name,
      time:   result.execution_time,
      result: polite,
      reason: result.processed&.dig("reason") }
  when :agent_error
    name, err, index = args
    { event: "agent_error",
      text:  "Agent #{(index || 0) + 1} error (#{name.split('::').last}): #{err.message}",
      level: "error",
      index: index }
  when :all_done
    { event: "all_done", text: "All agents finished — computing verdict…", level: "info" }
  when :verdict
    verdict = args[0]
    { event:   "verdict",
      text:    verdict ? "✓ Polite" : "✗ Not polite",
      level:   verdict ? "success" : "error",
      verdict: verdict }
  end
end
```

---

## Step 6 — JavaScript client

```js
const es = new EventSource(
  "/ai/tribunals/politeness/lifecycle/stream?input=" + encodeURIComponent(val),
);

es.addEventListener("lifecycle", function (ev) {
  const p = JSON.parse(ev.data);

  appendToSidebar(p);

  if (p.event === "agent_done" && p.index != null) {
    populatePanel(p.index, p);
  }

  if (p.event === "verdict") {
    showVerdict(p.verdict);
  }
});

es.onmessage = function (ev) {
  const p = JSON.parse(ev.data);
  if (p.done) {
    showTotalTime(p.time);
    (p.errors || []).forEach((e) =>
      appendToSidebar({ level: "error", text: e.agent + ": " + e.error }),
    );
    es.close();
  }
};
```

---

## SSE Event Flow

```
browser opens EventSource("/stream?input=…")
  ← event: lifecycle  {"event":"tribunal_start", "text":"launching 3 agents…", "source":"tribunal"}
  ← event: lifecycle  {"event":"agent_start", "index":0, "source":"tribunal"}
  ← event: lifecycle  {"event":"agent_start", "index":1, "source":"tribunal"}
  ← event: lifecycle  {"event":"agent_start", "index":2, "source":"tribunal"}
  ← event: lifecycle  {"event":"agent_done",  "index":2, "result":true, "source":"tribunal"}
  ← event: lifecycle  {"event":"agent_done",  "index":0, "result":true, "source":"tribunal"}
  ← event: lifecycle  {"event":"agent_error", "index":1, "source":"tribunal"}
  ← event: lifecycle  {"event":"all_done", "source":"tribunal"}
  ← event: lifecycle  {"event":"verdict", "verdict":false, "source":"tribunal"}
  ← data: {"done":true, "time":2.4, "errors":[...]}
```

Agents complete in non-deterministic order — panels update as each one finishes.
