require 'active_record/connection_adapters/postgresql/schema_statements'

module ActiveRecord
  module ConnectionAdapters
    module CockroachDB
      module SchemaStatements
        include ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaStatements
        # NOTE(joey): This was ripped from PostgresSQL::SchemaStatements, with a
        # slight modification to change setval(string, int, bool) to just
        # setval(string, int) for CockroachDB compatbility.
        # See https://github.com/cockroachdb/cockroach/issues/19723
        #
        # Resets the sequence of a table's primary key to the maximum value.
        def reset_pk_sequence!(table, pk = nil, sequence = nil) #:nodoc:
          unless pk && sequence
            default_pk, default_sequence = pk_and_sequence_for(table)

            pk ||= default_pk
            sequence ||= default_sequence
          end

          if @logger && pk && !sequence
            @logger.warn "#{table} has primary key #{pk} with no default sequence."
          end

          if pk && sequence
            quoted_sequence = quote_table_name(sequence)
            max_pk = query_value("SELECT MAX(#{quote_column_name pk}) FROM #{quote_table_name(table)}", "SCHEMA")
            if max_pk.nil?
              if postgresql_version >= 100000
                minvalue = query_value("SELECT seqmin FROM pg_sequence WHERE seqrelid = #{quote(quoted_sequence)}::regclass", "SCHEMA")
              else
                minvalue = query_value("SELECT min_value FROM #{quoted_sequence}", "SCHEMA")
              end
            end
            if max_pk
              # NOTE(joey): This is done to replace the call:
              #
              #    SELECT setval(..., max_pk, false)
              #
              # with
              #
              #    SELECT setval(..., max_pk-1)
              #
              # These two statements are semantically equivilant, but
              # setval(string, int, bool) is not supported by CockroachDB.
              #
              # FIXME(joey): This is incorrect if the sequence is not 1
              # incremented. We would need to pull out the custom increment value.
              max_pk - 1
            end
            query_value("SELECT setval(#{quote(quoted_sequence)}, #{max_pk ? max_pk : minvalue})", "SCHEMA")
          end
        end

        # copied from ConnectionAdapters::SchemaStatements
        #
        # modified insert into statement to always wrap the version value into single quotes for cockroachdb.
        def assume_migrated_upto_version(version, migrations_paths)
          migrations_paths = Array(migrations_paths)
          logger.debug "testing logging"
          version = version.to_i

          migrated = ActiveRecord::SchemaMigration.all_versions.map(&:to_i)
          versions = migration_context.migration_files.map do |file|
            migration_context.parse_migration_filename(file).first.to_i
          end

          unless migrated.include?(version)
            execute insert_versions_sql(version)
          end

          inserting = (versions - migrated).select { |v| v < version }
          if inserting.any?
            if (duplicate = inserting.detect { |v| inserting.count(v) > 1 })
              raise "Duplicate migration #{duplicate}. Please renumber your migrations to resolve the conflict."
            end
            if supports_multi_insert?
              execute insert_versions_sql(inserting)
            else
              inserting.each do |v|
                execute insert_versions_sql(v)
              end
            end
          end
        end

        def insert_versions_sql(versions)
          sm_table = quote_table_name(ActiveRecord::SchemaMigration.table_name)
          if versions.is_a?(Array)
            sql = "INSERT INTO #{sm_table} (version) VALUES\n".dup
            sql << versions.map { |v| "('#{quote(v)}')" }.join(",\n")
            sql << ";\n\n"
            sql
          else
            "INSERT INTO #{sm_table} (version) VALUES ('#{quote(versions)}');"
          end
        end
      end
    end
  end
end
