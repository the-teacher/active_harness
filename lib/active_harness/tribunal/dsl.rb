module ActiveHarness
  class Tribunal
    class << self
      # Declare agents at the class level.
      #
      #   agents PolitenessAgent, ConstructivenessAgent
      #   agents [PolitenessAgent, ConstructivenessAgent]
      def agents(*list)
        tribunal_config[:agents] = list.flatten
      end

      # Class-level process block — defines how to compute the verdict from results.
      #
      #   process { |results| results.all? { |r| r.parsed["result"] == true } }
      #   process { |results| results.count { |r| r.parsed["result"] == true } >= 2 }
      def process(&block)
        tribunal_config[:process] = block
      end
    end
  end
end
