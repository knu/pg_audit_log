module PgAuditLog
  class Function < PgAuditLog::ActiveRecord
    class << self
      def name
        "audit_changes"
      end

      def users_table_name
        "users"
      end

      def user_id_field
        "user_id"
      end

      def user_name_field
        "user_unique_name"
      end

      def users_access_column
        "last_accessed_at"
      end

      def user_identifier_temporary_function(user_id)
        sql = <<-SQL
          CREATE OR REPLACE FUNCTION pg_temp.pg_audit_log_user_identifier() RETURNS integer
          LANGUAGE plpgsql
          AS $_$
            BEGIN
              RETURN #{user_id};
            END
            $_$;
        SQL
      end

      def user_unique_name_temporary_function(username)
        sql = <<-SQL
          CREATE OR REPLACE FUNCTION pg_temp.pg_audit_log_user_unique_name() RETURNS varchar
          LANGUAGE plpgsql
          AS $_$
            BEGIN
              RETURN '#{username}';
            END
            $_$;
        SQL
      end

      def install
        execute <<-SQL
        CREATE OR REPLACE PROCEDURAL LANGUAGE plpgsql;
        CREATE OR REPLACE FUNCTION #{name}() RETURNS trigger
        LANGUAGE plpgsql
        AS $_$
            DECLARE
              col information_schema.columns %ROWTYPE;
              new_value text;
              old_value text;
              primary_key_column varchar;
              primary_key_value varchar;
              user_identifier integer;
              unique_name varchar;
              column_name varchar;
            BEGIN
              primary_key_column := NULL;
              EXECUTE 'SELECT pg_attribute.attname
                       FROM pg_index, pg_class, pg_attribute
                       WHERE pg_class.oid = $1::regclass
                       AND indrelid = pg_class.oid
                       AND pg_attribute.attrelid = pg_class.oid
                       AND pg_attribute.attnum = any(pg_index.indkey)
                       AND indisprimary'
              INTO primary_key_column USING TG_RELNAME;
              user_identifier := pg_temp.pg_audit_log_user_identifier();
              unique_name := pg_temp.pg_audit_log_user_unique_name();
              primary_key_value := NULL;

              FOR col IN SELECT * FROM information_schema.columns WHERE table_name = TG_RELNAME LOOP
                new_value := NULL;
                old_value := NULL;
                column_name := col.column_name;
                IF TG_RELNAME = '#{users_table_name}' AND column_name = '#{users_access_column}' THEN
                  NULL;
                ELSE
                  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
                    EXECUTE 'SELECT CAST($1 . '|| column_name ||' AS TEXT)' INTO new_value USING NEW;
                    IF primary_key_value IS NULL AND primary_key_column IS NOT NULL THEN
                      EXECUTE 'SELECT CAST($1 . '|| primary_key_column ||' AS VARCHAR)' INTO primary_key_value USING NEW;
                    END IF;
                  END IF;
                  IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
                    EXECUTE 'SELECT CAST($1 . '|| column_name ||' AS TEXT)' INTO old_value USING OLD;
                    IF primary_key_value IS NULL AND primary_key_column IS NOT NULL THEN
                      EXECUTE 'SELECT CAST($1 . '|| primary_key_column ||' AS VARCHAR)' INTO primary_key_value USING OLD;
                    END IF;
                  END IF;

                  IF TG_OP != 'UPDATE' OR new_value != old_value OR (TG_OP = 'UPDATE' AND ( (new_value IS NULL AND old_value IS NOT NULL) OR (new_value IS NOT NULL AND old_value IS NULL))) THEN
                    INSERT INTO audit_log("operation",
                                          "table_name",
                                          "primary_key",
                                          "field_name",
                                          "field_value_old",
                                          "field_value_new",
                                          "user_id",
                                          "user_unique_name",
                                          "occurred_at"
                                         )
                    VALUES(TG_OP,
                          TG_RELNAME,
                          primary_key_value,
                          column_name,
                          old_value,
                          new_value,
                          user_identifier,
                          unique_name,
                          current_timestamp);
                  END IF;
                END IF;
              END LOOP;
              RETURN NULL;
            END
            $_$;
        SQL
      end

      def uninstall
        execute "DROP FUNCTION #{name}()"
      end

      def installed?
        connection.select_values(<<-SQL).first.to_i == 1
          SELECT COUNT(pg_proc.proname)
          FROM pg_proc
          WHERE pg_proc.proname = '#{name}'
        SQL
      end
    end
  end
end
