require_relative "../agents/test_support_guard_agent"

# Runs TestSupportGuardAgent in parallel (single agent here, extendable).
# Verdict is true (safe) when no spam is detected.
class TestSupportGuardTribunal < ActiveHarness::Tribunal
  agents TestSupportGuardAgent

  process do |results|
    results.none? { |r| r.parsed["spam"] == true }
  end
end
