# Rails Streaming — SSE with Tokens and Lifecycle Events

This guide shows how to stream AI agent output token-by-token to the browser
and simultaneously push real-time lifecycle events (setup, retry, errors)
over a single HTTP connection — without WebSockets or background jobs.

---

## How it works

ActiveHarness exposes two streaming parameters:

| Parameter | Lambda signature           | Fires when                       | Carries                           |
| --------- | -------------------------- | -------------------------------- | --------------------------------- |
| `token:`  | `->(chunk) {}`             | Each token arrives from the LLM  | `String` — the raw token          |
| `stream:` | `->(source, event, *args)` | Each lifecycle hook fires        | source (`:agent`/`:tribunal`/`:pipeline`), event name, optional args |

Both are optional and independent — pass only what you need.

On the Rails side you use `ActionController::Live` to keep the HTTP connection
open and push data as `text/event-stream` (SSE).  
Two `ActionController::Live::SSE` objects share the **same raw stream** but
use different **SSE event names** (`message` vs `lifecycle`), so the browser
can route them independently with `es.onmessage` and `es.addEventListener`.

---

## Step 1 — Include ActionController::Live

```ruby
# app/controllers/ai/agents_controller.rb
module Ai
  class AgentsController < ApplicationController
    include ActionController::Live
    layout "ai"

    skip_before_action :verify_authenticity_token
  end
end
```

`skip_before_action :verify_authenticity_token` is required because SSE
endpoints are reached via `EventSource`, not a form POST.

---

## Step 2 — Add the streaming route

```ruby
# config/routes.rb
namespace :ai do
  scope :agents, as: :agents do
    get "lifecycle",        to: "agents#lifecycle"
    get "lifecycle/stream", to: "agents#lifecycle_stream", as: :lifecycle_stream
  end
end
```

Two routes: one for the HTML page, one for the SSE data stream.

---

## Step 3 — Prepare the SSE response headers

```ruby
private

def prepare_sse_response
  # Rails 8 + ActionController::Live: ServerTiming middleware crashes when
  # the events array is nil on the streaming thread — initialize it first.
  request.env["action_dispatch.server_timing_events"] ||= []

  response.headers["Content-Type"]      = "text/event-stream"
  response.headers["Cache-Control"]     = "no-cache"
  response.headers["X-Accel-Buffering"] = "no"   # disable nginx/proxy buffering
end
```

These three headers tell the browser and all intermediaries (nginx, CDN,
load balancers) that this is a live stream, not a cacheable response.

---

## Step 4 — Build the token and event stream lambdas

```ruby
# Wraps one SSE object — called per token by the agent.
def build_token_stream(sse)
  ->(chunk) { sse.write({ token: chunk }.to_json) }
end

# Wraps another SSE object — called per lifecycle hook by the agent.
# source is :agent for standalone agents; :tribunal or :pipeline when called from those.
def build_event_stream(sse)
  ->(_source, event, *args) do
    payload = lifecycle_event_message(event, args)
    sse.write(payload.to_json) if payload
  rescue IOError, ActionController::Live::ClientDisconnected
    # browser disconnected mid-stream — ignore silently
  end
end
```

Each lambda is a "sink": it receives data from the agent and pushes it
into the SSE pipe. The lambdas are created fresh per request.

---

## Step 5 — The streaming action

```ruby
# GET /ai/agents/lifecycle/stream?input=...
def lifecycle_stream
  prepare_sse_response

  input = params.require(:input)

  # One raw TCP stream, two SSE wrappers with different event names.
  stream        = response.stream
  sse_tokens    = ActionController::Live::SSE.new(stream, event: "message")
  sse_lifecycle = ActionController::Live::SSE.new(stream, event: "lifecycle")

  SupportAgent.call(
    input:  input,
    token:  build_token_stream(sse_tokens),
    stream: build_event_stream(sse_lifecycle)
  )

  # Signal to the browser that the stream is complete.
  sse_tokens.write({ done: true }.to_json)

rescue ActionController::Live::ClientDisconnected
  # Browser closed the tab — nothing to do.
rescue StandardError => e
  sse_tokens.write({ error: "#{e.class.name.split('::').last}: #{e.message}" }.to_json) rescue nil
  sse_tokens.write({ done: true }.to_json) rescue nil
ensure
  sse_tokens.close   # always close — releases the thread
end
```

Key points:

- `sse_tokens` and `sse_lifecycle` **share the same** `response.stream` object.
  SSE framing adds `event: message\n` or `event: lifecycle\n` before each
  `data:` line so the browser can tell them apart.
- Call `sse_tokens.close` in `ensure` — never in `rescue` — so it always
  runs even when no error occurs.
- Rescue `ClientDisconnected` separately and **silently** to avoid a 500 in
  your logs every time a user closes the tab.

---

## Step 6 — Map lifecycle hook names to UI messages

```ruby
def lifecycle_event_message(event, args)
  case event
  when :setup
    { event: "setup",             text: "Agent initialized",     level: "info" }
  when :before_system_prompt
    { event: "before_system_prompt", text: "Building system prompt…", level: "info" }
  when :after_system_prompt
    { event: "after_system_prompt",  text: "System prompt ready",     level: "info" }
  when :before_call
    { event: "before_call",       text: "Sending request…",      level: "info" }
  when :after_call
    result = args[0]
    { event: "after_call",
      text:  "Response received (#{result.execution_time}s)",
      level: "success",
      model: result.model.name,
      time:  result.execution_time }
  when :retry
    entry, error = args
    { event: "retry",
      text:  "Retry: #{entry[:model]} — #{error.class.name.split('::').last}",
      level: "warning" }
  when :failure
    { event: "failure",           text: "All models failed",     level: "error" }
  else
    nil
  end
end
```

This method translates internal Ruby symbols (`:setup`, `:after_call`, …)
into plain JSON hashes the browser can render directly.

---

## Step 7 — The view (HTML page)

```erb
<%# app/views/ai/agents/lifecycle.html.erb %>
<div class="ah-container">
  <aside class="ah-sidebar">
    <p class="ah-sidebar-title">Agent Events</p>
    <div id="ah-events" class="ah-events"></div>
  </aside>

  <div class="ah-main">
    <form id="ah-form" class="ah-form">
      <textarea id="ah-input" class="ah-textarea" rows="3">Hello!</textarea>
      <button type="submit" id="ah-btn">Ask</button>
    </form>

    <div id="ah-result">
      <div id="ah-output"></div>
      <div id="ah-meta"></div>
    </div>
  </div>
</div>

<% content_for :scripts do %>
  <%= javascript_include_tag "ai_agent_lifecycle" %>
<% end %>
```

---

## Step 8 — The JavaScript (no framework)

```js
// app/javascript/ai_agent_lifecycle.js
(function () {
  var frm = document.getElementById("ah-form");
  if (!frm) return; // guard: runs only when this page is loaded

  frm.addEventListener("submit", function (e) {
    e.preventDefault();
    var val = document.getElementById("ah-input").value.trim();
    if (!val) return;

    var es = new EventSource(
      "/ai/agents/lifecycle/stream?input=" + encodeURIComponent(val),
    );
    var done = false;

    function end() {
      done = true;
      es.close();
    }

    // "message" events carry tokens.
    es.onmessage = function (ev) {
      var p = JSON.parse(ev.data);
      if (p.done) { end(); return; }
      if (p.error) { /* show error */ end(); return; }
      document.getElementById("ah-output").textContent += p.token;
    };

    // "lifecycle" events carry agent hook data.
    es.addEventListener("lifecycle", function (ev) {
      var p = JSON.parse(ev.data);
      appendLifecycleEvent(p);
      if (p.event === "after_call" && p.model)
        document.getElementById("ah-meta").textContent =
          "Model: " + p.model + " · " + p.time + "s";
    });

    es.onerror = function () {
      if (done) return;
      end();
    };
  });
})();
```

---

## SSE wire format

A single request to `/ai/agents/lifecycle/stream` produces a mixed stream:

```
event: lifecycle
data: {"event":"setup","text":"Agent initialized","level":"info"}

event: lifecycle
data: {"event":"before_call","text":"Sending request…","level":"info"}

event: message
data: {"token":"Hello"}

event: message
data: {"token":"!"}

event: lifecycle
data: {"event":"after_call","text":"Response received (0.9s)","level":"success","model":"mistralai/mistral-nemo","time":0.9}

event: message
data: {"done":true}
```

The browser routes `event: message` to `es.onmessage` and
`event: lifecycle` to the `es.addEventListener("lifecycle", ...)` handler.

---

## Common pitfalls

| Problem                                            | Cause                               | Fix                                                                |
| -------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------ |
| `500 Internal Server Error` on every browser close | `ClientDisconnected` not rescued    | Add `rescue ActionController::Live::ClientDisconnected`            |
| Tokens delayed / arrive in batches                 | nginx buffering                     | Add `X-Accel-Buffering: no` header                                 |
| `NoMethodError` on `server_timing_events`          | Rails 8 + Live middleware race      | Add `request.env["action_dispatch.server_timing_events"] \|\|= []` |
| Duplicate requests                                 | JS listener attached multiple times | Use an IIFE + `if (!frm) return` guard                             |
| CSRF error on SSE GET                              | `verify_authenticity_token` runs    | `skip_before_action :verify_authenticity_token`                    |
