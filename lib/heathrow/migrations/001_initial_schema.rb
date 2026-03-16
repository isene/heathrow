# Initial Heathrow database schema
# Migration version 1

module Heathrow
  module Migrations
    class InitialSchema
      VERSION = 1

      def self.up(db)
        # Schema version tracking
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS schema_version (
              version INTEGER PRIMARY KEY,
              applied_at INTEGER NOT NULL
          );
        SQL

        # Messages table - normalized structure
        db.exec <<-SQL
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
              read BOOLEAN DEFAULT 0,
              starred BOOLEAN DEFAULT 0,
              archived BOOLEAN DEFAULT 0,

              labels TEXT,
              attachments TEXT,
              metadata TEXT,

              UNIQUE(source_id, external_id),
              FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE,
              FOREIGN KEY(parent_id) REFERENCES messages(id) ON DELETE SET NULL
          );
        SQL

        # Indices for performance
        db.exec "CREATE INDEX IF NOT EXISTS idx_messages_source ON messages(source_id)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_messages_read ON messages(read)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender)"

        # Full-text search
        db.exec <<-SQL
          CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
              subject,
              content,
              sender,
              content='messages',
              content_rowid='id'
          );
        SQL

        # FTS triggers
        db.exec <<-SQL
          CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, subject, content, sender)
              VALUES (new.id, new.subject, new.content, new.sender);
          END;
        SQL

        db.exec <<-SQL
          CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
              DELETE FROM messages_fts WHERE rowid = old.id;
          END;
        SQL

        db.exec <<-SQL
          CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
              UPDATE messages_fts
              SET subject = new.subject, content = new.content, sender = new.sender
              WHERE rowid = new.id;
          END;
        SQL

        # Sources table
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS sources (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE,
              plugin_type TEXT NOT NULL,
              enabled BOOLEAN DEFAULT 1,

              config TEXT NOT NULL,
              capabilities TEXT NOT NULL,

              last_sync INTEGER,
              last_error TEXT,

              message_count INTEGER DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
          );
        SQL

        db.exec "CREATE INDEX IF NOT EXISTS idx_sources_enabled ON sources(enabled)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_sources_plugin_type ON sources(plugin_type)"

        # Views table
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS views (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE,
              key_binding TEXT UNIQUE,

              filters TEXT NOT NULL,

              sort_order TEXT DEFAULT 'timestamp DESC',
              is_remainder BOOLEAN DEFAULT 0,

              show_count BOOLEAN DEFAULT 1,
              color INTEGER,
              icon TEXT,

              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
          );
        SQL

        db.exec "CREATE INDEX IF NOT EXISTS idx_views_key_binding ON views(key_binding)"

        # Contacts table
        db.exec <<-SQL
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
          );
        SQL

        db.exec "CREATE INDEX IF NOT EXISTS idx_contacts_email ON contacts(primary_email)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_contacts_name ON contacts(name)"

        # Drafts table
        db.exec <<-SQL
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
          );
        SQL

        db.exec "CREATE INDEX IF NOT EXISTS idx_drafts_updated ON drafts(updated_at DESC)"

        # Filters table
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS filters (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              enabled BOOLEAN DEFAULT 1,
              priority INTEGER DEFAULT 0,

              conditions TEXT NOT NULL,
              actions TEXT NOT NULL,

              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
          );
        SQL

        db.exec "CREATE INDEX IF NOT EXISTS idx_filters_enabled ON filters(enabled)"
        db.exec "CREATE INDEX IF NOT EXISTS idx_filters_priority ON filters(priority DESC)"

        # Settings table
        db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL,
              updated_at INTEGER NOT NULL
          );
        SQL

        # Record migration
        db.exec "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                [VERSION, Time.now.to_i]
      end

      def self.down(db)
        # Reverse migration (drop all tables)
        db.exec "DROP TABLE IF EXISTS settings"
        db.exec "DROP TABLE IF EXISTS filters"
        db.exec "DROP TABLE IF EXISTS drafts"
        db.exec "DROP TABLE IF EXISTS contacts"
        db.exec "DROP TABLE IF EXISTS views"
        db.exec "DROP TABLE IF EXISTS sources"

        # Drop FTS triggers
        db.exec "DROP TRIGGER IF EXISTS messages_au"
        db.exec "DROP TRIGGER IF EXISTS messages_ad"
        db.exec "DROP TRIGGER IF EXISTS messages_ai"

        # Drop FTS table
        db.exec "DROP TABLE IF EXISTS messages_fts"

        # Drop messages table
        db.exec "DROP TABLE IF EXISTS messages"

        # Remove migration record
        db.exec "DELETE FROM schema_version WHERE version = ?", [VERSION]
      end
    end
  end
end
