require 'sqlite3'
require 'time'
require 'thread'

module Heathrow
  class Database
    attr_reader :db_path

    def initialize(db_path = HEATHROW_DB)
      @db_path = db_path
      @db = nil
      @mutex = Mutex.new
      connect
      migrate_to_latest
    end

    # Execute a SQL statement (INSERT, UPDATE, DELETE)
    # @param sql [String] SQL statement
    # @param params [Array] Parameters for prepared statement
    # @return [Integer] Number of rows affected
    def exec(sql, params = [])
      @mutex.synchronize do
        @db.execute(sql, params)
        @db.changes
      end
    rescue SQLite3::Exception => e
      raise DatabaseError, "SQL execution failed: #{e.message}"
    end

    # Query data (SELECT)
    # @param sql [String] SQL query
    # @param params [Array] Parameters for prepared statement
    # @return [Array<Hash>] Array of result hashes
    def query(sql, params = [])
      @mutex.synchronize do
        @db.execute(sql, params)
      end
    rescue SQLite3::Exception => e
      raise DatabaseError, "SQL query failed: #{e.message}"
    end

    # Get first row of query result
    # @param sql [String] SQL query
    # @param params [Array] Parameters
    # @return [Hash, nil] First result or nil
    def query_one(sql, params = [])
      query(sql, params).first
    end

    # Get single value from query
    # @param sql [String] SQL query
    # @param params [Array] Parameters
    # @return [Object, nil] Single value or nil
    def query_value(sql, params = [])
      result = query_one(sql, params)
      result&.values&.first
    end

    # Execute block in a transaction
    # @yield Block to execute within transaction
    # @return [Object] Return value of block
    def transaction
      @mutex.synchronize do
        @db.transaction do
          yield
        end
      end
    rescue SQLite3::Exception => e
      raise DatabaseError, "Transaction failed: #{e.message}"
    end

    # Migrate to latest schema version
    def migrate_to_latest
      # Create schema_version table if it doesn't exist
      exec <<-SQL
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        );
      SQL

      current = query_value("SELECT MAX(version) FROM schema_version") || 0

      # Load and run migrations
      Dir[File.join(__dir__, 'migrations', '*.rb')].sort.each do |file|
        require file
        migration_class = extract_migration_class(file)
        next unless migration_class
        next if migration_class::VERSION <= current

        puts "Applying migration #{migration_class::VERSION}..."
        transaction do
          migration_class.up(self)
        end
        puts "Migration #{migration_class::VERSION} applied successfully"
      end
    end

    # Backup database to file
    # @param backup_path [String] Path to backup file
    def backup(backup_path = nil)
      backup_path ||= "#{@db_path}.backup.#{Time.now.to_i}"

      @mutex.synchronize do
        backup_db = SQLite3::Database.new(backup_path)
        @db.backup('main', backup_db, 'main')
        backup_db.close
      end

      backup_path
    end

    # Close database connection
    def close
      @mutex.synchronize do
        @db.close if @db
        @db = nil
      end
    end

    # Reconnect to database
    def reconnect
      close
      connect
    end

    # Get database statistics
    # @return [Hash] Statistics about database
    def stats
      {
        total_messages: query_value("SELECT COUNT(*) FROM messages") || 0,
        unread_messages: query_value("SELECT COUNT(*) FROM messages WHERE read = 0") || 0,
        starred_messages: query_value("SELECT COUNT(*) FROM messages WHERE starred = 1") || 0,
        total_sources: query_value("SELECT COUNT(*) FROM sources") || 0,
        active_sources: query_value("SELECT COUNT(*) FROM sources WHERE enabled = 1") || 0,
        total_views: query_value("SELECT COUNT(*) FROM views") || 0,
        db_size: File.size(@db_path)
      }
    end

    # Optimize database (VACUUM)
    def optimize
      @mutex.synchronize do
        @db.execute("VACUUM")
      end
    end

    # === LEGACY COMPATIBILITY METHODS ===
    # These maintain compatibility with existing code

    def get_messages(filters = {}, limit = nil, offset = 0)
      query_sql = "SELECT * FROM messages WHERE 1=1"
      params = []

      # Source filters
      if filters[:source_id]
        query_sql += " AND source_id = ?"
        params << filters[:source_id]
      end

      if filters[:source_type]
        # Map old source_type to plugin_type via sources table
        source_ids = query("SELECT id FROM sources WHERE plugin_type = ?", [filters[:source_type]])
        if source_ids.any?
          placeholders = source_ids.map { '?' }.join(',')
          query_sql += " AND source_id IN (#{placeholders})"
          params += source_ids.map { |s| s['id'] }
        end
      end

      if filters[:source_types] && filters[:source_types].is_a?(Array)
        source_ids = query("SELECT id FROM sources WHERE plugin_type IN (#{filters[:source_types].map{'?'}.join(',')})",
                          filters[:source_types])
        if source_ids.any?
          placeholders = source_ids.map { '?' }.join(',')
          query_sql += " AND source_id IN (#{placeholders})"
          params += source_ids.map { |s| s['id'] }
        end
      end

      # Sender filters
      if filters[:sender_pattern]
        patterns = filters[:sender_pattern].split('|')
        conditions = patterns.map { "sender LIKE ?" }.join(' OR ')
        query_sql += " AND (#{conditions})"
        params += patterns.map { |p| "%#{p}%" }
      end

      # Subject filters
      if filters[:subject_pattern]
        patterns = filters[:subject_pattern].split('|')
        conditions = patterns.map { "subject LIKE ?" }.join(' OR ')
        query_sql += " AND (#{conditions})"
        params += patterns.map { |p| "%#{p}%" }
      end

      # Content filters
      if filters[:content_patterns]
        filters[:content_patterns].each do |pattern_group|
          if pattern_group.include?('|')
            or_patterns = pattern_group.split('|').map(&:strip)
            conditions = or_patterns.map { "content LIKE ?" }.join(' OR ')
            query_sql += " AND (#{conditions})"
            params += or_patterns.map { |p| "%#{p}%" }
          else
            query_sql += " AND content LIKE ?"
            params << "%#{pattern_group}%"
          end
        end
      end

      # Search filter
      if filters[:search]
        query_sql += " AND (sender LIKE ? OR subject LIKE ? OR content LIKE ?)"
        search_term = "%#{filters[:search]}%"
        params += [search_term, search_term, search_term]
      end

      # Read status
      if filters[:is_read] != nil
        query_sql += " AND read = ?"
        params << (filters[:is_read] ? 1 : 0)
      end

      # Sorting
      query_sql += " ORDER BY timestamp DESC"

      # Pagination
      if limit
        query_sql += " LIMIT ? OFFSET ?"
        params += [limit, offset]
      end

      query(query_sql, params)
    end

    def insert_message(message_data)
      # Legacy method - convert array format to hash and use new method
      exec <<-SQL, message_data
        INSERT OR REPLACE INTO messages
        (source_id, source_type, external_id, sender, recipient, subject, content,
         raw_data, attachments, timestamp, read)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end

    def mark_as_read(message_id)
      exec("UPDATE messages SET read = 1 WHERE id = ?", [message_id]) > 0
    end

    def mark_as_unread(message_id)
      exec("UPDATE messages SET read = 0 WHERE id = ?", [message_id]) > 0
    end

    def toggle_star(message_id)
      exec("UPDATE messages SET starred = NOT starred WHERE id = ?", [message_id])
    end

    def delete_message(message_id)
      exec("DELETE FROM messages WHERE id = ?", [message_id])
    end

    def add_source(id, type, name, config, polling_interval, color = 15, enabled = true)
      config_json = config.is_a?(Hash) ? config.to_json : config
      now = Time.now.to_i

      # Check if source exists
      existing = query_one("SELECT id FROM sources WHERE name = ?", [name])

      if existing
        # Update existing
        exec <<-SQL, [type, config_json, enabled ? 1 : 0, now, existing['id']]
          UPDATE sources
          SET plugin_type = ?, config = ?, enabled = ?, updated_at = ?
          WHERE id = ?
        SQL
      else
        # Insert new
        exec <<-SQL, [name, type, config_json, '["read"]', enabled ? 1 : 0, now, now]
          INSERT INTO sources (name, plugin_type, config, capabilities, enabled, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
      end
    end

    def get_sources(enabled_only = true)
      sql = "SELECT * FROM sources"
      sql += " WHERE enabled = 1" if enabled_only

      sources = query(sql)
      sources.each do |source|
        source['config'] = JSON.parse(source['config']) if source['config']
        source['capabilities'] = JSON.parse(source['capabilities']) if source['capabilities']
      end
      sources
    end

    def get_all_sources
      get_sources(false)
    end

    def get_source_by_name(name)
      source = query_one("SELECT * FROM sources WHERE name = ? LIMIT 1", [name])
      if source
        source['config'] = JSON.parse(source['config']) if source['config']
        source['capabilities'] = JSON.parse(source['capabilities']) if source['capabilities']
      end
      source
    end

    def get_source_by_id(id)
      source = query_one("SELECT * FROM sources WHERE id = ? LIMIT 1", [id])
      if source
        source['config'] = JSON.parse(source['config']) if source['config']
        source['capabilities'] = JSON.parse(source['capabilities']) if source['capabilities']
      end
      source
    end

    def update_source(source_id, updates = {})
      if updates[:config]
        exec("UPDATE sources SET config = ?, updated_at = ? WHERE id = ?",
             [updates[:config], Time.now.to_i, source_id])
      end
    end

    def update_source_poll_time(source_id)
      exec("UPDATE sources SET last_sync = ? WHERE id = ?", [Time.now.to_i, source_id])
    end

    def save_view(view_id, view_data)
      now = Time.now.to_i
      exec <<-SQL, [view_data[:name], view_data[:filters].to_json, view_data[:sort_order],
                    view_data.fetch(:key_binding, nil), now, view_id]
        INSERT OR REPLACE INTO views (name, filters, sort_order, key_binding, updated_at, id)
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
    end

    def delete_view(view_id)
      exec("DELETE FROM views WHERE id = ?", [view_id])
    end

    def get_view(view_id)
      view = query_one("SELECT * FROM views WHERE id = ?", [view_id])
      if view
        view['filters'] = JSON.parse(view['filters']) if view['filters']
      end
      view
    end

    def get_all_views
      views = query("SELECT * FROM views ORDER BY id")
      views.each do |view|
        view['filters'] = JSON.parse(view['filters']) if view['filters']
      end
      views
    end

    def get_stats
      stats
    end

    def execute(query, *params)
      exec(query, params)
    end

    private

    def connect
      @db = SQLite3::Database.new(@db_path)
      @db.results_as_hash = true
      @db.busy_timeout = 5000  # Wait up to 5 seconds if database is locked
    end

    def extract_migration_class(file)
      # Extract migration class from filename
      # e.g., "001_initial_schema.rb" -> Heathrow::Migrations::InitialSchema
      basename = File.basename(file, '.rb')
      class_name = basename.split('_')[1..-1].map(&:capitalize).join

      begin
        Heathrow::Migrations.const_get(class_name)
      rescue NameError
        nil
      end
    end
  end

  # Custom error class
  class DatabaseError < StandardError; end
end
