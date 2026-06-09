require "json"

module ActiveHarness
  class Memory
    module Adapter
      # SQLite-backed memory adapter.
      #
      # Requires the 'sqlite3' gem — add it to your Gemfile yourself:
      #   gem 'sqlite3'
      #
      # Connection options (one of):
      #   database:   — path to the SQLite file; adapter opens and closes the connection
      #               use ":memory:" for an in-process, non-persistent database
      #   connection: — an existing SQLite3::Database instance you manage
      #
      # Storage options:
      #   table_name:      — default "active_harness_memory_turns"
      #   storage_size:    — max turns per session kept in the table (default 1000)
      #   eviction_percent — % of oldest turns to drop when limit is hit (default 10)
      #   on_trim:         — Proc called with evicted turns
      #   namespace:       — isolates turns within a session
      class Sqlite < Base
        DEFAULT_TABLE        = "active_harness_memory_turns"
        DEFAULT_STORAGE_SIZE = 1000
        DEFAULT_TRIM_PERCENT = 10

        TABLE_NAME_RE = /\A[a-zA-Z_][a-zA-Z0-9_.]*\z/

        def initialize(opts = {})
          @table        = opts.fetch(:table_name, DEFAULT_TABLE).to_s
          @storage_size = opts.fetch(:storage_size, DEFAULT_STORAGE_SIZE)
          @trim_percent = opts.fetch(:eviction_percent, DEFAULT_TRIM_PERCENT)
          @on_trim      = opts[:on_trim]
          @namespace    = opts[:namespace]

          unless @table.match?(TABLE_NAME_RE)
            raise ArgumentError, "Invalid table_name: #{@table.inspect}"
          end

          @borrowed_conn = opts[:connection]
          @db_path       = opts[:database]
          @owned_conn    = nil
          @session_id    = nil
          @turns         = []
        end

        def open(session_id)
          @session_id = session_id
          ensure_connection!
          @turns = fetch_turns
        end

        def read
          @turns.dup
        end

        def write(turn)
          insert_turn(turn)
          @turns << turn
          trim_if_needed!
        end

        def close
          if @owned_conn
            @owned_conn.close rescue nil
            @owned_conn = nil
          end
        end

        def delete
          db.execute(
            "DELETE FROM #{@table} WHERE session_id = ? AND (namespace IS ?)",
            [@session_id, @namespace]
          )
          @turns = []
        end

        # -----------------------------------------------------------------------
        private
        # -----------------------------------------------------------------------

        def db
          @borrowed_conn || @owned_conn ||
            raise("SQLite connection not open — call open(session_id) first")
        end

        def ensure_connection!
          return if @borrowed_conn || @owned_conn

          load_sqlite3!

          unless @db_path
            raise ArgumentError,
              "SQLite adapter requires database: (file path or ':memory:')"
          end

          conn = SQLite3::Database.new(@db_path)
          conn.execute("PRAGMA journal_mode=WAL")
          @owned_conn = conn
        end

        def load_sqlite3!
          require "sqlite3"
        rescue LoadError
          raise LoadError,
            "The 'sqlite3' gem is required for the SQLite memory adapter. " \
            "Add it to your Gemfile:  gem 'sqlite3'"
        end

        def fetch_turns
          rows = db.execute(
            "SELECT request, response, meta " \
            "FROM #{@table} " \
            "WHERE session_id = ? AND (namespace IS ?) " \
            "ORDER BY id ASC",
            [@session_id, @namespace]
          )
          rows.map do |row|
            # row is Array (default) or Hash (results_as_hash=true) — handle both
            req, resp, meta_str =
              row.is_a?(Hash) ? row.values_at("request", "response", "meta") : row
            turn = { request: req, response: resp }
            meta = JSON.parse(meta_str || "{}", symbolize_names: true)
            meta.empty? ? turn : turn.merge(meta)
          end
        end

        def insert_turn(turn)
          meta = turn.reject { |k, _| k == :request || k == :response }
          db.execute(
            "INSERT INTO #{@table} (session_id, namespace, request, response, meta) " \
            "VALUES (?, ?, ?, ?, ?)",
            [
              @session_id,
              @namespace,
              turn[:request].to_s,
              turn[:response].to_s,
              JSON.generate(meta)
            ]
          )
        end

        def trim_if_needed!
          return unless @storage_size
          return if @turns.size <= @storage_size

          to_delete = [@turns.size * @trim_percent / 100, 1].max

          if @on_trim
            trimmed = @turns.first(to_delete)
            @on_trim.call(trimmed)
          end

          db.execute(
            "DELETE FROM #{@table} WHERE id IN (" \
            "  SELECT id FROM #{@table} " \
            "  WHERE session_id = ? AND (namespace IS ?) " \
            "  ORDER BY id ASC LIMIT ?" \
            ")",
            [@session_id, @namespace, to_delete]
          )

          @turns.shift(to_delete)
        end
      end
    end

    # Convenience Memory subclass for SQLite-backed storage.
    #
    # Usage — plain Ruby (adapter owns the connection):
    #   mem = ActiveHarness::Memory::Sqlite.new(
    #     session_id: "user_42",
    #     database:   "storage/ai/memory.sqlite3",
    #     depth:      10
    #   )
    #   mem.load
    #   # ... use ...
    #   mem.close
    #
    # Usage — Rails (borrow AR raw connection for SQLite3 adapter):
    #   mem = ActiveHarness::Memory::Sqlite.new(
    #     session_id: "user_42",
    #     connection: ActiveRecord::Base.connection.raw_connection
    #   )
    #
    # Plain Ruby schema setup (run once before first use):
    #   ActiveHarness::Memory::Sqlite.create_schema!("storage/ai/memory.sqlite3")
    class Sqlite < Memory
      # SQL to create the schema — run once before first use in plain Ruby.
      SCHEMA_SQL = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS active_harness_memory_turns (
          id         INTEGER  PRIMARY KEY AUTOINCREMENT,
          session_id TEXT     NOT NULL,
          namespace  TEXT,
          request    TEXT     NOT NULL,
          response   TEXT     NOT NULL,
          meta       TEXT     NOT NULL DEFAULT '{}',
          created_at TEXT     NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_ah_memory_turns_session
          ON active_harness_memory_turns (session_id, namespace, id);
      SQL

      # Create the schema on an existing database or a file path.
      # Safe to call multiple times — uses CREATE TABLE IF NOT EXISTS.
      def self.create_schema!(db_or_path)
        require "sqlite3"
        conn = db_or_path.is_a?(String) ? SQLite3::Database.new(db_or_path) : db_or_path
        SCHEMA_SQL.split(";").map(&:strip).reject(&:empty?).each { |sql| conn.execute(sql) }
      rescue LoadError
        raise LoadError,
          "The 'sqlite3' gem is required. Add it to your Gemfile:  gem 'sqlite3'"
      end

      def initialize(session_id:, namespace: nil, on_trim: nil, **opts)
        mem_keys = %i[depth enabled read_only async]
        mem_opts = opts.slice(*mem_keys)
        sq_opts  = opts.reject { |k, _| mem_keys.include?(k) }

        sq_opts[:namespace] = namespace if namespace
        sq_opts[:on_trim]   = on_trim   if on_trim

        super(
          session_id: session_id,
          adapter:    Adapter::Sqlite.new(sq_opts),
          namespace:  namespace,
          on_trim:    on_trim,
          **mem_opts
        )
      end
    end
  end
end
