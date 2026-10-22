# Shared by every *Tracing concern: ONE place that decides where trace lines go.
# Today: Rails.logger. Swap this method to emit OpenTelemetry spans, StatsD
# metrics or database rows, and every request/tribunal/pipeline/agent/tool that
# includes a tracing concern follows — the examples themselves stay untouched.
module TracingLog
  private

  def trace_log(message, level: :info)
    logger = defined?(Rails) && Rails.logger ? Rails.logger : Logger.new($stdout)
    logger.public_send(level, "[#{tracing_label}] #{message}")
  end

  # Override in a class to rename it in the logs.
  def tracing_label
    klass = self.class
    klass.respond_to?(:full_name) ? klass.full_name : klass.name
  end
end
