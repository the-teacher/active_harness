require "rails/generators"
require "rails/generators/active_record"

module ActiveHarness
  module Generators
    class MemoryPostgresqlGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the ActiveHarness PostgreSQL memory migration"

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_migration_file
        migration_template "create_active_harness_memory_turns.rb.tt",
                           "db/migrate/create_active_harness_memory_turns.rb"
      end
    end
  end
end
