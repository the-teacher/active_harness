require_relative "../requests/support_guard_request"

# Runs SupportGuardRequest in parallel (single request here, extendable).
# Verdict is true (safe) when no spam is detected.
class SupportGuardTribunal < ActiveHarness::Tribunal
  requests SupportGuardRequest

  process do |results|
    results.none? { |r| r.processed["spam"] == true }
  end
end
