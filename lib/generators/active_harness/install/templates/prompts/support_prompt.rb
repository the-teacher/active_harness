# A prompt is a plain Ruby class with #call returning the system prompt text.
# Before #call the Request injects @input, @context, @params, @memory and
# @context_window, so a prompt can be built from them.
class SupportPrompt
  def call
    "You are a concise and helpful assistant. Answer in 1-2 sentences."
  end
end
