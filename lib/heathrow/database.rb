require 'sqlite3'
require 'time'
require 'json'

module Heathrow
  class Database
    attr_reader :db

    SCHEMA_VERSION = 1

    def initialize(db_path = HEATHROW_DB)
      @db_path = db_path
      @db = SQLite3::Database.new(@db_path)
      @db.results_as_hash = true
      @db.execute("PRAGMA journal_mode=WAL")
      @db.execute("PRAGMA busy_timeout=5000")
      @mutex = Mutex.new
      setup_schema
      run_migrations
    end

    def setup_schema
      # Schema version tracking
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS schema_version (
          version INTEGER PRIMARY KEY,
          applied_at INTEGER NOT NULL
        )
      SQL
      # Main messages table (following DATABASE_SCHEMA.md spec)
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER NOT NULL,
          external_id TEXT NOT NULL,
          thread_id TEXT,
          parent_id INTEGER,

          sender TEXT NOT NULL,
          sender_name TEXT,

          recipients TEXT NOT NULL,
          cc TEXT,
          bcc TEXT,

          subject TEXT,
          content TEXT NOT NULL,
          html_content TEXT,

          timestamp INTEGER NOT NULL,
          received_at INTEGER NOT NULL,
          read INTEGER DEFAULT 0,
          starred INTEGER DEFAULT 0,
          archived INTEGER DEFAULT 0,

          labels TEXT,
          attachments TEXT,
          metadata TEXT,

          UNIQUE(source_id, external_id),
          FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE,
          FOREIGN KEY(parent_id) REFERENCES messages(id) ON DELETE SET NULL
        )
      SQL
      
      # Indexes for performance
      @db.execute "CREATE INDEX IF NOT EXISTS idx_messages_source ON messages(source_id)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_messages_read ON messages(read)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_messages_read_timestamp ON messages(read, timestamp DESC)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender)"
      
      # Sources table (configured communication sources)
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS sources (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          plugin_type TEXT NOT NULL,
          enabled INTEGER DEFAULT 1,

          config TEXT NOT NULL,
          capabilities TEXT NOT NULL,

          last_sync INTEGER,
          last_error TEXT,

          message_count INTEGER DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_sources_enabled ON sources(enabled)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_sources_plugin_type ON sources(plugin_type)"
      
      # Views table (user-defined filtered views)
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS views (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          key_binding TEXT UNIQUE,

          filters TEXT NOT NULL,

          sort_order TEXT DEFAULT 'timestamp DESC',
          is_remainder INTEGER DEFAULT 0,

          show_count INTEGER DEFAULT 1,
          color INTEGER,
          icon TEXT,

          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_views_key_binding ON views(key_binding)"

      # Additional tables from spec
      create_additional_tables
      create_default_views
    end

    def create_additional_tables
      # Contacts table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS contacts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          primary_email TEXT,
          identities TEXT,
          phone TEXT,
          avatar_url TEXT,
          tags TEXT,
          notes TEXT,
          message_count INTEGER DEFAULT 0,
          last_contact INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_contacts_email ON contacts(primary_email)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts(name)"

      # Drafts table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS drafts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER,
          reply_to_id INTEGER,
          recipients TEXT NOT NULL,
          cc TEXT,
          bcc TEXT,
          subject TEXT,
          content TEXT NOT NULL,
          attachments TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE SET NULL,
          FOREIGN KEY(reply_to_id) REFERENCES messages(id) ON DELETE SET NULL
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_drafts_updated ON drafts(updated_at DESC)"

      # Filters table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS filters (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          enabled INTEGER DEFAULT 1,
          priority INTEGER DEFAULT 0,
          conditions TEXT NOT NULL,
          actions TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      SQL

      @db.execute "CREATE INDEX IF NOT EXISTS idx_filters_enabled ON filters(enabled)"
      @db.execute "CREATE INDEX IF NOT EXISTS idx_filters_priority ON filters(priority DESC)"

      # Settings table
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      SQL
    end
    
    def run_migrations
      current_version = @db.get_first_value("SELECT MAX(version) FROM schema_version") || 0

      # Migration: add folder column for fast folder lookups
      # Migration: add poll_interval and color columns to sources
      source_cols = @db.execute("PRAGMA table_info(sources)").map { |c| c['name'] }
      unless source_cols.include?('poll_interval')
        @db.execute("ALTER TABLE sources ADD COLUMN poll_interval INTEGER DEFAULT 900")
        # Maildir is fast local scan, default to 30s
        @db.execute("UPDATE sources SET poll_interval = 30 WHERE plugin_type = 'maildir'")
      end
      unless source_cols.include?('color')
        @db.execute("ALTER TABLE sources ADD COLUMN color TEXT")
      end

      cols = @db.execute("PRAGMA table_info(messages)").map { |c| c['name'] }
      unless cols.include?('folder')
        @db.execute("ALTER TABLE messages ADD COLUMN folder TEXT")
        @db.execute("CREATE INDEX IF NOT EXISTS idx_messages_folder ON messages(folder)")
        # Populate from labels JSON (first element)
        @db.execute("UPDATE messages SET folder = json_extract(labels, '$[0]') WHERE labels IS NOT NULL AND labels != '[]'")
      end

      unless cols.include?('replied')
        @db.execute("ALTER TABLE messages ADD COLUMN replied INTEGER DEFAULT 0")
      end

      # Postponed messages (drafts)
      @db.execute <<-SQL
        CREATE TABLE IF NOT EXISTS postponed (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER,
          data TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      SQL

      if current_version < SCHEMA_VERSION
        @db.transaction do
          @db.execute("INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     [SCHEMA_VERSION, Time.now.to_i])
        end
      end
    end

    def create_default_views
      # Check if default views exist
      count = @db.get_first_value("SELECT COUNT(*) FROM views")
      return if count && count > 0

      now = Time.now.to_i

      # Built-in views (A, N, * are hardcoded in the app, but stored for reference)
      @db.execute("INSERT OR IGNORE INTO views (name, key_binding, filters, is_remainder, created_at, updated_at) VALUES ('All', 'A', '{\"rules\": []}', 0, ?, ?)", [now, now])
      @db.execute("INSERT OR IGNORE INTO views (name, key_binding, filters, created_at, updated_at) VALUES ('Unread', 'N', '{\"rules\": [{\"field\": \"read\", \"op\": \"=\", \"value\": false}]}', ?, ?)", [now, now])
      @db.execute("INSERT OR IGNORE INTO views (name, key_binding, filters, created_at, updated_at) VALUES ('Starred', '*', '{\"rules\": [{\"field\": \"starred\", \"op\": \"=\", \"value\": true}]}', ?, ?)", [now, now])

      # User-configurable views are defined in heathrowrc via the `view` DSL
    end
    
    # Message operations
    def insert_message(data)
      # Support both hash and array formats for backward compatibility
      if data.is_a?(Hash)
        now = Time.now.to_i
        folder = data[:labels].is_a?(Array) ? data[:labels].first : nil
        @db.execute(
          "INSERT INTO messages
          (source_id, external_id, thread_id, parent_id, sender, sender_name,
           recipients, cc, bcc, subject, content, html_content,
           timestamp, received_at, read, starred, archived,
           labels, attachments, metadata, folder, replied)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, external_id) DO UPDATE SET
            subject = excluded.subject,
            content = excluded.content,
            html_content = excluded.html_content,
            metadata = excluded.metadata,
            attachments = excluded.attachments
            -- Preserve read, starred, archived, replied (user modifications)",
          [
            data[:source_id],
            data[:external_id],
            data[:thread_id],
            data[:parent_id],
            data[:sender],
            data[:sender_name],
            data[:recipients].is_a?(Array) ? data[:recipients].to_json : data[:recipients],
            data[:cc]&.to_json,
            data[:bcc]&.to_json,
            data[:subject],
            data[:content],
            data[:html_content],
            data[:timestamp] || now,
            data[:received_at] || now,
            data[:read] ? 1 : 0,
            data[:starred] ? 1 : 0,
            data[:archived] ? 1 : 0,
            data[:labels]&.to_json,
            data[:attachments]&.to_json,
            data[:metadata]&.to_json,
            folder,
            data[:replied] ? 1 : 0
          ]
        )
      else
        # Legacy array format - convert to new schema as best we can
        source_id, source_type, external_id, sender, recipient, subject, content, raw_data, attachments, timestamp, is_read = data
        now = Time.now.to_i
        ts = timestamp.is_a?(Time) ? timestamp.to_i : (timestamp.is_a?(String) ? Time.parse(timestamp).to_i : timestamp)

        @db.execute(
          "INSERT INTO messages
          (source_id, external_id, thread_id, parent_id, sender, sender_name,
           recipients, cc, bcc, subject, content, html_content,
           timestamp, received_at, read, starred, archived,
           labels, attachments, metadata)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, external_id) DO UPDATE SET
            subject = excluded.subject,
            content = excluded.content,
            html_content = excluded.html_content,
            metadata = excluded.metadata,
            attachments = excluded.attachments
            -- Preserve read, starred, archived (user modifications)",
          [
            source_id,
            external_id || "legacy-#{now}",
            nil, nil,
            sender || "unknown",
            nil,
            [recipient].compact.to_json,
            nil, nil,
            subject,
            content || "",
            nil,
            ts || now,
            now,
            is_read ? 1 : 0,
            0, 0,
            nil,
            attachments,
            raw_data
          ]
        )
      end
    end
    
    def get_messages(filters = {}, limit = nil, offset = 0, light: false)
      cols = if light
        "id, source_id, external_id, thread_id, parent_id, sender, sender_name, recipients, subject, substr(content, 1, 200) as content, timestamp, received_at, read, starred, archived, labels, metadata, attachments, folder, replied"
      else
        "*"
      end
      query = "SELECT #{cols} FROM messages WHERE 1=1"
      params = []

      # Exclude archived/deleted messages by default
      unless filters.key?(:archived)
        query += " AND (archived = 0 OR archived IS NULL)"
      end

      if filters[:source_id]
        query += " AND source_id = ?"
        params << filters[:source_id]
      end

      if filters[:source_ids].is_a?(Array) && !filters[:source_ids].empty?
        ph = filters[:source_ids].map { '?' }.join(',')
        query += " AND source_id IN (#{ph})"
        params += filters[:source_ids]
      end

      if filters[:source_name]
        patterns = filters[:source_name].split('|').map(&:strip)
        conditions = patterns.map { "name LIKE ?" }.join(' OR ')
        query += " AND source_id IN (SELECT id FROM sources WHERE #{conditions})"
        params += patterns.map { |p| "%#{p}%" }
      end
      
      # Handle sender pattern (supports regex via pipe separation)
      if filters[:sender_pattern]
        patterns = filters[:sender_pattern].split('|')
        conditions = patterns.map { "(sender LIKE ? OR sender_name LIKE ?)" }.join(' OR ')
        query += " AND (#{conditions})"
        patterns.each { |p| params += ["%#{p}%", "%#{p}%"] }
      end
      
      # Handle subject pattern
      if filters[:subject_pattern]
        patterns = filters[:subject_pattern].split('|')
        conditions = patterns.map { "subject LIKE ?" }.join(' OR ')
        query += " AND (#{conditions})"
        params += patterns.map { |p| "%#{p}%" }
      end
      
      # Handle content patterns (each can be a pattern with | for OR, separated by comma for AND)
      if filters[:content_patterns]
        filters[:content_patterns].each do |pattern_group|
          if pattern_group.include?('|')
            # OR logic within this group
            or_patterns = pattern_group.split('|').map(&:strip)
            conditions = or_patterns.map { "content LIKE ?" }.join(' OR ')
            query += " AND (#{conditions})"
            params += or_patterns.map { |p| "%#{p}%" }
          else
            # Simple keyword
            query += " AND content LIKE ?"
            params << "%#{pattern_group}%"
          end
        end
      end
      
      # Legacy support for old filter formats
      if filters[:content_keywords]
        filters[:content_keywords].each do |keyword|
          query += " AND content LIKE ?"
          params << "%#{keyword}%"
        end
      end
      
      if filters[:content_regex]
        query += " AND content LIKE ?"
        params << "%#{filters[:content_regex]}%"
      end
      
      # Search across sender, subject, content (supports | for OR)
      if filters[:search]
        terms = filters[:search].split('|').map(&:strip).reject(&:empty?)
        if terms.size == 1
          query += " AND (sender LIKE ? OR subject LIKE ? OR content LIKE ? OR recipients LIKE ?)"
          search_term = "%#{terms.first}%"
          params += [search_term, search_term, search_term, search_term]
        else
          conditions = terms.map { |_t|
            "(sender LIKE ? OR subject LIKE ? OR content LIKE ? OR recipients LIKE ?)"
          }.join(' OR ')
          query += " AND (#{conditions})"
          terms.each { |t| term = "%#{t}%"; params += [term, term, term, term] }
        end
      end
      
      # Support both old and new column names for read status
      if filters[:is_read] != nil || filters[:read] != nil
        query += " AND read = ?"
        params << ((filters[:read] || filters[:is_read]) ? 1 : 0)
      end

      if filters[:starred] != nil
        query += " AND starred = ?"
        params << (filters[:starred] ? 1 : 0)
      end

      if filters[:archived] != nil
        query += " AND archived = ?"
        params << (filters[:archived] ? 1 : 0)
      end

      if filters[:maildir_folder]
        query += " AND folder = ?"
        params << filters[:maildir_folder]
      end

      if filters[:label]
        # Match label anywhere in the JSON labels array
        query += " AND labels LIKE ?"
        params << "%\"#{filters[:label]}\"%"
      end

      query += " ORDER BY timestamp DESC"

      if limit
        query += " LIMIT ? OFFSET ?"
        params += [limit, offset]
      end

      results = @db.execute(query, params)
      results.map { |row| normalize_message_row(row) }
    end

    def get_message(id)
      row = @db.execute("SELECT * FROM messages WHERE id = ?", [id]).first
      return nil unless row
      normalize_message_row(row)
    end

    def mark_as_read(message_id)
      @db.execute("UPDATE messages SET read = 1 WHERE id = ?", message_id)
      @db.changes > 0
    end

    # Bulk mark all unread messages as read, optionally filtered by folder.
    # Returns array of [id, metadata_json] for maildir flag sync.
    def mark_all_as_read(folder: nil)
      if folder
        rows = @db.execute(
          "SELECT id, metadata FROM messages WHERE read = 0 AND folder >= ? AND folder < ?",
          [folder, folder.chomp('.') + '/']
        )
        @db.execute(
          "UPDATE messages SET read = 1 WHERE read = 0 AND folder >= ? AND folder < ?",
          [folder, folder.chomp('.') + '/']
        )
      else
        rows = @db.execute("SELECT id, metadata FROM messages WHERE read = 0")
        @db.execute("UPDATE messages SET read = 1 WHERE read = 0")
      end
      rows
    end

    def mark_as_unread(message_id)
      @db.execute("UPDATE messages SET read = 0 WHERE id = ?", message_id)
      @db.changes > 0
    end

    def toggle_star(message_id)
      @db.execute("UPDATE messages SET starred = NOT starred WHERE id = ?", message_id)
    end
    
    def delete_message(message_id)
      @db.execute("DELETE FROM messages WHERE id = ?", message_id)
    end
    
    # Postponed messages (drafts)
    def save_postponed(source_id, data)
      @db.execute("INSERT INTO postponed (source_id, data, created_at) VALUES (?, ?, ?)",
                  [source_id, JSON.generate(data), Time.now.to_i])
    end

    def list_postponed
      @db.execute("SELECT * FROM postponed ORDER BY created_at DESC")
    end

    def get_postponed(id)
      @db.get_first_row("SELECT * FROM postponed WHERE id = ?", [id])
    end

    def delete_postponed(id)
      @db.execute("DELETE FROM postponed WHERE id = ?", [id])
    end

    def postponed_count
      @db.get_first_value("SELECT COUNT(*) FROM postponed") || 0
    end

    # Source operations
    def add_source(name, plugin_type, config, capabilities = ["read"], enabled = true)
      config_json = config.is_a?(Hash) ? config.to_json : config
      capabilities_json = capabilities.is_a?(Array) ? capabilities.to_json : capabilities
      now = Time.now.to_i

      @db.execute <<-SQL, [name, plugin_type, enabled ? 1 : 0, config_json, capabilities_json, 0, now, now]
        INSERT OR REPLACE INTO sources
        (name, plugin_type, enabled, config, capabilities, message_count, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL

      @db.last_insert_row_id
    end
    
    def get_sources(enabled_only = true)
      query = enabled_only ? "SELECT * FROM sources WHERE enabled = 1 ORDER BY id" : "SELECT * FROM sources ORDER BY id"
      @db.execute(query).each { |s| normalize_source_row(s) }
    end

    def get_all_sources
      get_sources(false)
    end

    # Batch query: returns { source_id => {count:, unread:} }
    def get_source_stats
      rows = @db.execute(
        "SELECT source_id, COUNT(*) as cnt, SUM(CASE WHEN read = 0 THEN 1 ELSE 0 END) as unread
         FROM messages WHERE archived = 0 OR archived IS NULL GROUP BY source_id"
      )
      stats = {}
      rows.each { |r| stats[r['source_id']] = { count: r['cnt'], unread: r['unread'] } }
      stats
    end

    # Returns { source_id => plugin_type } for all sources
    def get_source_type_map
      rows = @db.execute("SELECT id, plugin_type FROM sources")
      rows.each_with_object({}) { |r, h| h[r['id']] = r['plugin_type'] }
    end

    def get_source_by_name(name)
      source = @db.execute("SELECT * FROM sources WHERE name = ? LIMIT 1", name).first
      source ? normalize_source_row(source) : nil
    end

    def get_source_by_id(id)
      source = @db.execute("SELECT * FROM sources WHERE id = ? LIMIT 1", id).first
      source ? normalize_source_row(source) : nil
    end

    def update_source(source_id, updates = {})
      now = Time.now.to_i
      updates.each do |key, value|
        case key
        when :config
          value = value.to_json if value.is_a?(Hash)
          @db.execute("UPDATE sources SET config = ?, updated_at = ? WHERE id = ?", [value, now, source_id])
        when :last_sync
          @db.execute("UPDATE sources SET last_sync = ?, updated_at = ? WHERE id = ?", [value, now, source_id])
        when :last_error
          @db.execute("UPDATE sources SET last_error = ?, updated_at = ? WHERE id = ?", [value, now, source_id])
        when :enabled
          @db.execute("UPDATE sources SET enabled = ?, updated_at = ? WHERE id = ?", [value ? 1 : 0, now, source_id])
        end
      end
    end

    def update_source_poll_time(source_id)
      now = Time.now.to_i
      @db.execute("UPDATE sources SET last_sync = ?, updated_at = ? WHERE id = ?", [now, now, source_id])
    end
    
    # View operations
    def save_view(view_data)
      now = Time.now.to_i
      filters_json = view_data[:filters].is_a?(Hash) ? view_data[:filters].to_json : view_data[:filters]

      if view_data[:id]
        # Update existing view by id
        @db.execute(
          "UPDATE views SET name = ?, key_binding = ?, filters = ?, sort_order = ?, updated_at = ? WHERE id = ?",
          [view_data[:name], view_data[:key_binding], filters_json,
           view_data[:sort_order] || 'timestamp DESC', now, view_data[:id]]
        )
      elsif view_data[:key_binding]
        # UPSERT by key_binding (for F1-F12 and 0-9)
        existing = @db.get_first_row("SELECT id FROM views WHERE key_binding = ?", view_data[:key_binding])
        if existing
          @db.execute(
            "UPDATE views SET name = ?, filters = ?, sort_order = ?, updated_at = ? WHERE key_binding = ?",
            [view_data[:name], filters_json, view_data[:sort_order] || 'timestamp DESC', now, view_data[:key_binding]]
          )
          existing['id']
        else
          @db.execute(
            "INSERT INTO views (name, key_binding, filters, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            [view_data[:name], view_data[:key_binding], filters_json,
             view_data[:sort_order] || 'timestamp DESC', now, now]
          )
          @db.last_insert_row_id
        end
      else
        # Insert new view
        @db.execute(
          "INSERT INTO views (name, key_binding, filters, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
          [view_data[:name], view_data[:key_binding], filters_json,
           view_data[:sort_order] || 'timestamp DESC', now, now]
        )
        @db.last_insert_row_id
      end
    end

    def delete_view(view_id)
      @db.execute("DELETE FROM views WHERE id = ?", view_id)
    end

    def get_view(view_id)
      result = @db.get_first_row("SELECT * FROM views WHERE id = ?", view_id)
      if result
        result['filters'] = JSON.parse(result['filters']) if result['filters']
      end
      result
    end

    def get_all_views
      views = @db.execute("SELECT * FROM views ORDER BY id")
      views.each do |view|
        view['filters'] = JSON.parse(view['filters']) if view['filters']
      end
      views
    end

    # Statistics
    def get_stats
      {
        total_messages: @db.get_first_value("SELECT COUNT(*) FROM messages"),
        unread_messages: @db.get_first_value("SELECT COUNT(*) FROM messages WHERE read = 0"),
        starred_messages: @db.get_first_value("SELECT COUNT(*) FROM messages WHERE starred = 1"),
        archived_messages: @db.get_first_value("SELECT COUNT(*) FROM messages WHERE archived = 1"),
        total_sources: @db.get_first_value("SELECT COUNT(*) FROM sources"),
        active_sources: @db.get_first_value("SELECT COUNT(*) FROM sources WHERE enabled = 1")
      }
    end
    
    # Returns hash of { base_id => {id:, external_id:, read:, starred:} } for a folder
    def get_folder_index(source_id, folder_name)
      rows = @db.execute(
        "SELECT id, external_id, read, starred, replied FROM messages WHERE source_id = ? AND folder = ?",
        [source_id, folder_name]
      )
      index = {}
      rows.each do |row|
        base_id = row['external_id'].to_s.split(':2,', 2).first
        index[base_id] = { id: row['id'], external_id: row['external_id'],
                           read: row['read'], starred: row['starred'], replied: row['replied'] }
      end
      index
    end

    # Bulk delete messages by their IDs
    def delete_messages_by_ids(ids)
      return if ids.empty?
      placeholders = ids.map { '?' }.join(',')
      @db.execute("DELETE FROM messages WHERE id IN (#{placeholders})", ids)
    end

    private

    def normalize_message_row(row)
      r = row.dup
      %w[recipients cc bcc labels attachments metadata].each do |field|
        r[field] = JSON.parse(r[field]) if r.key?(field) && r[field].is_a?(String)
      end
      r['is_read'] = r['read']
      r['is_starred'] = r['starred']
      r
    rescue JSON::ParserError
      row.dup
    end

    def normalize_source_row(source)
      s = source.dup
      s['config'] = JSON.parse(s['config']) if s['config'].is_a?(String)
      s['capabilities'] = JSON.parse(s['capabilities']) if s['capabilities'].is_a?(String)
      s
    rescue JSON::ParserError
      source.dup
    end

    public

    def execute(query, *params)
      @db.execute(query, params)
    end

    def transaction(&block)
      @db.transaction(&block)
    end

    def close
      @db.close if @db
    end
  end
end