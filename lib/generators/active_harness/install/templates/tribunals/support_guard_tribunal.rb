require_relative "../requests/support_guard_request"
require_relative "../concerns/tribunal_tracing"

# Runs SupportGuardRequest in parallel (single request here, extendable).
# Verdict is true (safe) when no spam is detected.
class SupportGuardTribunal < ActiveHarness::Tribunal
  include TribunalTracing

  # The requests that run IN PARALLEL on the same input. Several different checks —
  # or the same check on different models — give a more reliable decision than one call.
  requests SupportGuardRequest

  # Reduces all successful results to the verdict (true/false). Built-in shortcuts:
  # `verdict :unanimous { ... }` and `verdict :majority { ... }`.
  process do |results|
    results.none? { |r| r.processed["spam"] == true }
  end
end
