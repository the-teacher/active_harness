module ActiveHarness
  # Base class for goal checks — the judge of an Agent's final answer.
  # Subclass it and override #call:
  #
  #   class TestsPassedGoal < ActiveHarness::GoalCheck
  #     def call(candidate:, goal:, state:)
  #       ok = system("bin/rails test")
  #       ActiveHarness::GoalCheckResult.new(status: ok ? :achieved : :continue, feedback: "Tests are failing")
  #     end
  #   end
  #
  #   class DevelopmentAgent < ActiveHarness::Agent
  #     goal TestsPassedGoal
  #   end
  #
  # The base class exists to fail loudly: forgetting to define #call raises an error
  # that names the class, instead of an obscure NoMethodError mid-run. It is optional —
  # any object (or a block) with call(candidate:, goal:, state:) is accepted by `goal`.
  class GoalCheck
    def call(candidate:, goal:, state:)
      raise NotImplementedError,
            "#{self.class.name || 'GoalCheck'} must define #call(candidate:, goal:, state:) " \
            "returning an ActiveHarness::GoalCheckResult"
    end
  end
end
