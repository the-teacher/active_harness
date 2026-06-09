require_relative "../agents/support_guard_agent"

# Runs SupportGuardAgent in parallel (single agent here, extendable).
# Verdict is true (safe) when no spam is detected.
class SupportGuardTribunal < ActiveHarness::Tribunal
  agents SupportGuardAgent

  process do |results|
    results.none? { |r| r.processed["spam"] == true }
  end
end
