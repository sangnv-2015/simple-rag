class FakeLLM
  attr_reader :calls

  def initialize(&reply)
    @reply = reply
    @calls = []
  end

  def chat(messages, &on_delta)
    @calls << { messages: messages, streamed: !on_delta.nil? }
    out = @reply.call(messages)
    raise out if out.is_a?(Exception)
    out = [out] if out.is_a?(String)
    out.each { |d| on_delta.call(d) } if on_delta
    out.join
  end
end
