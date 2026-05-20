module ActiveHarness
  class Memory
    module Adapter
      # Contract that every adapter must implement.
      # Subclasses override these four methods.
      class Base
        # Load turns for the given session from the storage backend.
        # Must be called before read/write.
        def open(session_id)
          raise NotImplementedError, "#{self.class}#open not implemented"
        end

        # Return a plain Array of turn hashes.
        # Each turn has at minimum: { request:, response: }
        def read
          raise NotImplementedError, "#{self.class}#read not implemented"
        end

        # Persist a single turn hash.
        def write(turn)
          raise NotImplementedError, "#{self.class}#write not implemented"
        end

        # Flush buffers and release resources.
        def close
          raise NotImplementedError, "#{self.class}#close not implemented"
        end

        # Remove all data for the current session from the backend.
        def delete
          raise NotImplementedError, "#{self.class}#delete not implemented"
        end
      end
    end
  end
end
