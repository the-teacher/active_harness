# Tribunal Streaming — Live Events via SSE

Tribunals run agents in parallel and produce a final verdict.
By passing a `tribunal_event_stream:` lambda, you can push each tribunal lifecycle event
to the browser in real time over a single SSE connection — without polling.
Pass `stream:` and/or `agent_event_stream:` to forward streaming callbacks to every agent the tribunal launches.

---

## How It Works

The tribunal accepts three optional streaming parameters:

- `tribunal_event_stream:` — lambda called on each tribunal lifecycle event (start, agent done, verdict, …)
- `agent_event_stream:` — forwarded to every agent as their `event_stream:` (per-agent hook events)
- `stream:` — forwarded to every agent as their `stream:` (raw token stream)

This lambda is called from inside lifecycle hooks as each event occurs:
agent launched, agent completed, agent failed, verdict computed.

On the Rails side you use `ActionController::Live` to keep the HTTP connection
open and push events as `text/event-stream` (SSE).

---

## Step 1 — Add tribunal_event_stream to the Tribunal

```ruby
class PolitenessLifecycleTribunal < ActiveHarness::Tribunal
  on(:before_agent) { |agent, index| @tribunal_event_stream&.call(:agent_start, index) }
  on(:after_agent)  { |result, index| @tribunal_event_stream&.call(:agent_done, result, index) }
  on(:agent_error)  { |name, err, index| @tribunal_event_stream&.call(:agent_error, name, err, index) }
  on(:after_call)   { |results, _errors| @tribunal_event_stream&.call(:all_done) }
  on(:after_verdict){ |verdict| @tribunal_event_stream&.call(:verdict, verdict) }

  def initialize(input:, tribunal_event_stream: nil)
    # build agents...
    super(input: input, agents: agents, tribunal_event_stream: tribunal_event_stream)
  end

  process do |results|
    results.all? { |r| r.parsed["result"] == true }
  end
end
```

The `&.` guard means the hooks are completely silent when `tribunal_event_stream` is `nil` —
the same tribunal class works for both the plain and the live-sidebar versions.

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

  input = params.require(:input)

  stream     = response.stream
  sse_events = ActionController::Live::SSE.new(stream, event: "lifecycle")
  sse_done   = ActionController::Live::SSE.new(stream, event: "message")

  event_stream = ->(name, *args) do
    sse_events.write(tribunal_event_message(name, args).to_json)
  rescue IOError, ActionController::Live::ClientDisconnected
  end

  tribunal = PolitenessLifecycleTribunal.new(input: input, tribunal_event_stream: event_stream)
  event_stream.call(:tribunal_start, tribunal_agent_count)
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
    polite = result.parsed&.dig("result") == true
    { event: "agent_done",
      text:  "Agent #{index + 1} done: #{result.model} (#{result.execution_time}s)",
      level: polite ? "success" : "warning",
      index: index,
      model: result.model,
      time:  result.execution_time,
      usage: result.usage,
      cost:  result.cost,
      result: polite,
      reason: result.parsed&.dig("reason") }
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
    { event: "verdict",
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

// Lifecycle events — update sidebar and panels in real time
es.addEventListener("lifecycle", function (ev) {
  const p = JSON.parse(ev.data);

  appendToSidebar(p); // show text + level in sidebar

  if (p.event === "agent_done" && p.index != null) {
    populatePanel(p.index, p); // fill panel immediately when agent finishes
  }

  if (p.event === "verdict") {
    showVerdict(p.verdict); // update final verdict box
  }
});

// Done signal — total time and any partial errors
es.onmessage = function (ev) {
  const p = JSON.parse(ev.data);
  if (p.done) {
    showTotalTime(p.time);

    // Agents that errored out
    (p.errors || []).forEach((e) =>
      appendToSidebar({ level: "error", text: e.agent + ": " + e.error }),
    );

    es.close();
  }
};
```

Key points:

- `es.addEventListener("lifecycle", ...)` handles named `lifecycle` SSE events.
- `es.onmessage` handles the unnamed default `message` events (the `done` signal).
- Panels are populated **as each agent finishes**, not after all are done — this is the
  key difference from the plain polling approach.
- `p.errors` in the `done` payload contains agents that failed, for display and debugging.

---

## SSE Event Flow

```
browser opens EventSource("/stream?input=…")
  ← event: lifecycle  {"event":"tribunal_start", "text":"launching 3 agents…"}
  ← event: lifecycle  {"event":"agent_start", "index":0, ...}
  ← event: lifecycle  {"event":"agent_start", "index":1, ...}
  ← event: lifecycle  {"event":"agent_start", "index":2, ...}
  ← event: lifecycle  {"event":"agent_done",  "index":2, "result":true, ...}
  ← event: lifecycle  {"event":"agent_done",  "index":0, "result":true, ...}
  ← event: lifecycle  {"event":"agent_error", "index":1, "text":"error…"}
  ← event: lifecycle  {"event":"all_done", ...}
  ← event: lifecycle  {"event":"verdict", "verdict":false}
  ← data: {"done":true, "time":2.4, "errors":[{"agent":"PolitenessAgent","error":"…"}]}
```

Agents complete in non-deterministic order — panels update as each one finishes.
