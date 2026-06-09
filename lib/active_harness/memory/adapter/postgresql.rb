require "json"

module ActiveHarness
  class Memory
    module Adapter
      # PostgreSQL-backed memory adapter.
      #
      # Requires the 'pg' gem — add it to your Gemfile yourself:
      #   gem 'pg'
      #
      # Connection options (one of):
      #   connection:  — a PG::Connection instance you manage
      #   url:         — connection string; adapter opens and closes the connection
      #   host:, port:, dbname:, user:, password: — adapter opens and closes the connection
      #
      # Storage options:
      #   table_name:      — default "active_harness_memory_turns"
      #   storage_size:    — max turns per session kept in the table (default 1000)
      #   eviction_percent — % of oldest turns to drop when limit is hit (default 10)
      #   on_trim:         — Proc called with evicted turns
      #   namespace:       — isolates turns within a session
      class Postgresql < Base
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

          # Connection source — one of: instance, url, keyword args.
          @borrowed_conn = opts[:connection]
          @conn_url      = opts[:url]
          @conn_kwargs   = opts.slice(:host, :port, :dbname, :user, :password)

          @owned_conn  = nil
          @session_id  = nil
          @turns       = []
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
          conn.exec_params(
            "DELETE FROM #{@table} " \
            "WHERE session_id = $1 AND (namespace IS NOT DISTINCT FROM $2)",
            [@session_id, @namespace]
          )
          @turns = []
        end

        # -----------------------------------------------------------------------
        private
        # -----------------------------------------------------------------------

        def conn
          @borrowed_conn || @owned_conn ||
            raise("PostgreSQL connection not open — call open(session_id) first")
        end

        def ensure_connection!
          return if @borrowed_conn || @owned_conn

          load_pg!

          @owned_conn =
            if @conn_url
              PG.connect(@conn_url)
            elsif @conn_kwargs.any?
              PG.connect(**@conn_kwargs)
            else
              raise ArgumentError,
                "PostgreSQL adapter requires one of: connection:, url:, " \
                "or connection keyword args (host:, port:, dbname:, user:, password:)"
            end
        end

        def load_pg!
          require "pg"
        rescue LoadError
          raise LoadError,
            "The 'pg' gem is required for the PostgreSQL memory adapter. " \
            "Add it to your Gemfile:  gem 'pg'"
        end

        def fetch_turns
          result = conn.exec_params(
            "SELECT request, response, meta " \
            "FROM #{@table} " \
            "WHERE session_id = $1 AND (namespace IS NOT DISTINCT FROM $2) " \
            "ORDER BY id ASC",
            [@session_id, @namespace]
          )

          result.map do |row|
            turn = { request: row["request"], response: row["response"] }
            meta = JSON.parse(row["meta"] || "{}", symbolize_names: true)
            meta.empty? ? turn : turn.merge(meta)
          end
        end

        def insert_turn(turn)
          meta = turn.reject { |k, _| k == :request || k == :response }

          conn.exec_params(
            "INSERT INTO #{@table} (session_id, namespace, request, response, meta) " \
            "VALUES ($1, $2, $3, $4, $5::jsonb)",
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

          conn.exec_params(
            "DELETE FROM #{@table} WHERE id IN (" \
            "  SELECT id FROM #{@table} " \
            "  WHERE session_id = $1 AND (namespace IS NOT DISTINCT FROM $2) " \
            "  ORDER BY id ASC LIMIT $3" \
            ")",
            [@session_id, @namespace, to_delete]
          )

          @turns.shift(to_delete)
        end
      end
    end

    # Convenience Memory subclass for PostgreSQL-backed storage.
    #
    # Requires the 'pg' gem installed by the application:
    #   gem 'pg'
    #
    # Usage — plain Ruby (adapter owns the connection):
    #   mem = ActiveHarness::Memory::Postgresql.new(
    #     session_id: "user_42",
    #     url:        ENV["DATABASE_URL"],
    #     depth:      10
    #   )
    #   mem.load
    #   # ... use ...
    #   mem.close
    #
    # Usage — Rails (borrow the AR raw connection):
    #   mem = ActiveHarness::Memory::Postgresql.new(
    #     session_id: "user_42",
    #     connection: ActiveRecord::Base.connection.raw_connection
    #   )
    class Postgresql < Memory
      def initialize(session_id:, namespace: nil, on_trim: nil, **opts)
        mem_keys = %i[depth enabled read_only async]
        mem_opts = opts.slice(*mem_keys)
        pg_opts  = opts.reject { |k, _| mem_keys.include?(k) }

        pg_opts[:namespace] = namespace if namespace
        pg_opts[:on_trim]   = on_trim   if on_trim

        super(
          session_id: session_id,
          adapter:    Adapter::Postgresql.new(pg_opts),
          namespace:  namespace,
          on_trim:    on_trim,
          **mem_opts
        )
      end
    end
  end
end
