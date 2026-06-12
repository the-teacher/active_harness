# 009 — Streaming with Rails SSE

## Topic

How to stream agent tokens to the browser using Rails Server-Sent Events (SSE).

## Why This Is Needed

SSE lets the browser receive tokens as they arrive, without polling or WebSockets. This is the standard approach for real-time LLM output in Rails applications.

## Rails Controller

```ruby
# app/controllers/ai/agents_controller.rb
class Ai::AgentsController < ApplicationController
  include ActionController::Live

  def stream_response
    set_sse_headers

    input = params.require(:input)
    sse = build_sse_writer
    run_agent_with_sse(input, sse)
  ensure
    sse&.close
  end

  private

  def set_sse_headers
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
  end

  def build_sse_writer
    ActionController::Live::SSE.new(response.stream, event: "token")
  end

  def build_token_stream(sse)
    ->(token) do
      sse.write({ token: token }.to_json)
    end
  end

  def send_final_event(sse, result)
    sse.write({
      done: true,
      model: result.model.name,
      time: result.execution_time,
      usage: result.usage
    }.to_json)
  end

  def run_agent_with_sse(input, sse)
    agent = StreamingAgent.new(
      input: input,
      streams: { token: build_token_stream(sse) }
    )
    agent.call
    send_final_event(sse, agent.result)
  rescue ActionController::Live::ClientDisconnected
    # client disconnected
  end
end
```

## JavaScript Client

```javascript
const eventSource = new EventSource("/ai/agents/stream_response?input=Hello");

let fullResponse = "";

eventSource.addEventListener("token", (event) => {
  const data = JSON.parse(event.data);

  if (data.done) {
    console.log("Done!");
    console.log("Model:", data.model);
    console.log("Time:", data.time);
    eventSource.close();
  } else {
    fullResponse += data.token;
    document.getElementById("response").textContent = fullResponse;
  }
});

eventSource.addEventListener("error", (event) => {
  console.error("Error:", event);
  eventSource.close();
});
```

## Best Practices

1. **Set SSE headers explicitly** — `Content-Type: text/event-stream`, `Cache-Control: no-cache`, `X-Accel-Buffering: no`
2. **Always close the stream in `ensure`** — prevents connection leaks even if the agent raises
3. **Rescue `ClientDisconnected`** — the browser can close the tab at any time; don't let it bubble up
4. **Send a `done` event** — lets the client know generation finished and it can close the `EventSource`
5. **Extract private helpers** — keep the action method short; delegate SSE setup and agent execution to private methods
