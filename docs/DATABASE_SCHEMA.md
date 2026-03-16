# Heathrow Database Schema

**Database:** SQLite 3
**Location:** `~/.heathrow/heathrow.db`
**Version:** Schema version tracked in `schema_version` table

---

## Design Principles

1. **Normalization:** Avoid data duplication
2. **Flexibility:** JSON columns for plugin-specific data
3. **Performance:** Indices on frequently queried columns
4. **Migration:** Version-based schema upgrades
5. **Encryption:** Sensitive data encrypted at application layer

---

## Schema Version

```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL  -- Unix timestamp
);
```

**Purpose:** Track database migrations.

**Usage:**
```ruby
current_version = db.query("SELECT MAX(version) FROM schema_version").first[0]
```

---

## Messages Table

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL,
    external_id TEXT NOT NULL,           -- Source's message ID
    thread_id TEXT,                      -- For threading support
    parent_id INTEGER,                   -- Reply-to message (optional)

    -- Sender information
    sender TEXT NOT NULL,                -- Email/username/phone
    sender_name TEXT,                    -- Display name

    -- Recipients (JSON array)
    recipients TEXT NOT NULL,            -- ["user1", "user2"]
    cc TEXT,                             -- ["cc1", "cc2"]
    bcc TEXT,                            -- ["bcc1", "bcc2"]

    -- Content
    subject TEXT,
    content TEXT NOT NULL,
    html_content TEXT,                   -- Original HTML (if applicable)

    -- Metadata
    timestamp INTEGER NOT NULL,          -- Unix timestamp
    received_at INTEGER NOT NULL,        -- When we fetched it
    read BOOLEAN DEFAULT 0,
    starred BOOLEAN DEFAULT 0,
    archived BOOLEAN DEFAULT 0,

    -- Organization
    labels TEXT,                         -- JSON array: ["work", "important"]
    attachments TEXT,                    -- JSON array: [{"name": "file.pdf", "path": "/path"}]

    -- Plugin-specific data (JSON)
    metadata TEXT,                       -- {"slack_channel": "general", "discord_guild": "123"}

    -- Constraints
    UNIQUE(source_id, external_id),
    FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE,
    FOREIGN KEY(parent_id) REFERENCES messages(id) ON DELETE SET NULL
);

-- Indices for performance
CREATE INDEX idx_messages_source ON messages(source_id);
CREATE INDEX idx_messages_timestamp ON messages(timestamp DESC);
CREATE INDEX idx_messages_thread ON messages(thread_id);
CREATE INDEX idx_messages_read ON messages(read);
CREATE INDEX idx_messages_sender ON messages(sender);

-- Full-text search
CREATE VIRTUAL TABLE messages_fts USING fts5(
    subject,
    content,
    sender,
    content=messages,
    content_rowid=id
);

-- Triggers to keep FTS index updated
CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, subject, content, sender)
    VALUES (new.id, new.subject, new.content, new.sender);
END;

CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.id;
END;

CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
    UPDATE messages_fts
    SET subject = new.subject, content = new.content, sender = new.sender
    WHERE rowid = new.id;
END;
```

**JSON Column Examples:**

```ruby
# recipients
["user@example.com", "another@example.com"]

# labels
["work", "important", "follow-up"]

# attachments
[
  {"name": "report.pdf", "path": "~/.heathrow/attachments/abc123.pdf", "size": 102400},
  {"name": "image.png", "path": "~/.heathrow/attachments/def456.png", "size": 51200}
]

# metadata (Gmail example)
{
  "gmail_message_id": "<CABc123@mail.gmail.com>",
  "gmail_thread_id": "18abc123def",
  "gmail_labels": ["INBOX", "UNREAD"]
}

# metadata (Slack example)
{
  "slack_channel": "general",
  "slack_team": "T0123ABC",
  "slack_ts": "1234567890.123456",
  "slack_reactions": [{"name": "thumbsup", "count": 3}]
}
```

---

## Sources Table

```sql
CREATE TABLE sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,           -- User-friendly name: "Work Email", "Personal Slack"
    plugin_type TEXT NOT NULL,           -- "gmail", "slack", "discord", etc.
    enabled BOOLEAN DEFAULT 1,

    -- Configuration (JSON, encrypted)
    config TEXT NOT NULL,                -- Plugin-specific settings

    -- Capabilities (JSON array)
    capabilities TEXT NOT NULL,          -- ["read", "write", "attachments"]

    -- Status
    last_sync INTEGER,                   -- Unix timestamp of last successful fetch
    last_error TEXT,                     -- Last error message (if any)

    -- Statistics
    message_count INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_sources_enabled ON sources(enabled);
CREATE INDEX idx_sources_plugin_type ON sources(plugin_type);
```

**Config Column Examples:**

```ruby
# Gmail
{
  "email": "user@gmail.com",
  "credentials": "ENCRYPTED:abc123...",  # OAuth2 token
  "sync_days": 30,
  "sync_labels": ["INBOX", "SENT"]
}

# Slack
{
  "workspace": "mycompany",
  "token": "ENCRYPTED:xoxb-...",
  "sync_channels": ["general", "random"],
  "sync_dms": true
}

# RSS
{
  "feed_url": "https://example.com/feed.xml",
  "update_interval": 3600
}
```

**Capabilities:**
- `read` - Can fetch messages
- `write` - Can send messages
- `real_time` - Supports live streaming
- `attachments` - Supports file attachments
- `threads` - Supports threaded conversations
- `search` - Supports server-side search
- `reactions` - Supports emoji reactions
- `typing` - Supports typing indicators
- `read_receipts` - Supports read receipts

---

## Views Table

```sql
CREATE TABLE views (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,           -- "All", "Unread", "Work", "Personal"
    key_binding TEXT UNIQUE,             -- "A", "N", "1", "2", etc.

    -- Filter rules (JSON)
    filters TEXT NOT NULL,               -- Complex filter logic

    -- Display options
    sort_order TEXT DEFAULT 'timestamp DESC',
    is_remainder BOOLEAN DEFAULT 0,      -- Catch-all view

    -- UI preferences
    show_count BOOLEAN DEFAULT 1,
    color INTEGER,                       -- Terminal color code
    icon TEXT,                           -- Unicode icon

    -- Metadata
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_views_key_binding ON views(key_binding);
```

**Filter Examples:**

```ruby
# Show only unread messages from work email
{
  "rules": [
    {"field": "read", "op": "=", "value": false},
    {"field": "source_id", "op": "=", "value": 1}
  ],
  "logic": "AND"
}

# Show messages from specific senders OR with specific labels
{
  "rules": [
    {
      "any": [
        {"field": "sender", "op": "IN", "value": ["boss@work.com", "client@company.com"]},
        {"field": "labels", "op": "CONTAINS", "value": "urgent"}
      ]
    }
  ]
}

# Complex: (unread OR starred) AND (from work OR personal email)
{
  "rules": [
    {
      "any": [
        {"field": "read", "op": "=", "value": false},
        {"field": "starred", "op": "=", "value": true}
      ]
    },
    {
      "any": [
        {"field": "source_id", "op": "=", "value": 1},
        {"field": "source_id", "op": "=", "value": 2}
      ]
    }
  ],
  "logic": "AND"
}

# Remainder view (matches everything not matched by other views)
{
  "rules": [],
  "is_remainder": true
}
```

**Supported Filter Operators:**
- `=`, `!=` - Equality
- `>`, `<`, `>=`, `<=` - Comparison
- `CONTAINS` - Substring/array contains
- `IN` - Value in array
- `MATCHES` - Regex match
- `BEFORE`, `AFTER` - Date comparisons

---

## Contacts Table

```sql
CREATE TABLE contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    primary_email TEXT,

    -- Platform identities (JSON)
    identities TEXT,                     -- {"slack": "@john", "discord": "john#1234"}

    -- Contact info
    phone TEXT,
    avatar_url TEXT,

    -- Organization
    tags TEXT,                           -- JSON array: ["work", "client"]
    notes TEXT,

    -- Statistics
    message_count INTEGER DEFAULT 0,
    last_contact INTEGER,                -- Unix timestamp

    -- Metadata
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_contacts_email ON contacts(primary_email);
CREATE INDEX idx_contacts_name ON contacts(name);
```

**Identities Example:**

```ruby
{
  "email": ["john@example.com", "john.doe@company.com"],
  "slack": {"workspace": "T0123", "user_id": "U456", "handle": "@john"},
  "discord": {"user_id": "123456789", "tag": "john#1234"},
  "telegram": {"user_id": "987654", "username": "@johndoe"},
  "phone": ["+1234567890"]
}
```

---

## Drafts Table

```sql
CREATE TABLE drafts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER,                   -- Which source to send from
    reply_to_id INTEGER,                 -- If replying to a message

    -- Content
    recipients TEXT NOT NULL,
    cc TEXT,
    bcc TEXT,
    subject TEXT,
    content TEXT NOT NULL,
    attachments TEXT,

    -- Metadata
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,

    FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE SET NULL,
    FOREIGN KEY(reply_to_id) REFERENCES messages(id) ON DELETE SET NULL
);

CREATE INDEX idx_drafts_updated ON drafts(updated_at DESC);
```

---

## Filters Table

```sql
CREATE TABLE filters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    enabled BOOLEAN DEFAULT 1,
    priority INTEGER DEFAULT 0,          -- Higher priority = runs first

    -- Conditions (JSON)
    conditions TEXT NOT NULL,

    -- Actions (JSON)
    actions TEXT NOT NULL,

    -- Metadata
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX idx_filters_enabled ON filters(enabled);
CREATE INDEX idx_filters_priority ON filters(priority DESC);
```

**Filter Examples:**

```ruby
# Auto-archive newsletters
{
  "name": "Archive newsletters",
  "conditions": {
    "any": [
      {"field": "sender", "op": "CONTAINS", "value": "newsletter"},
      {"field": "subject", "op": "CONTAINS", "value": "unsubscribe"}
    ]
  },
  "actions": [
    {"type": "set_field", "field": "archived", "value": true},
    {"type": "set_field", "field": "read", "value": true}
  ]
}

# Auto-label messages from boss as important
{
  "name": "Important from boss",
  "conditions": {
    "field": "sender",
    "op": "=",
    "value": "boss@company.com"
  },
  "actions": [
    {"type": "add_label", "label": "important"},
    {"type": "set_field", "field": "starred", "value": true}
  ]
}
```

---

## Settings Table

```sql
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
```

**Common Settings:**

```ruby
# UI preferences
{"key": "ui.theme", "value": "dark"}
{"key": "ui.split_ratio", "value": "0.3"}  # Left pane width
{"key": "ui.show_borders", "value": "true"}

# Behavior
{"key": "auto_mark_read", "value": "true"}
{"key": "notification_enabled", "value": "true"}
{"key": "sync_interval", "value": "300"}  # 5 minutes

# Security
{"key": "encryption_key", "value": "ENCRYPTED:..."}
```

---

## Migrations

**Migration Files:** `lib/heathrow/migrations/001_initial.rb`, `002_add_contacts.rb`, etc.

**Migration Template:**

```ruby
# lib/heathrow/migrations/001_initial.rb
module Heathrow
  module Migrations
    class Initial
      VERSION = 1

      def self.up(db)
        db.exec <<-SQL
          CREATE TABLE schema_version (
              version INTEGER PRIMARY KEY,
              applied_at INTEGER NOT NULL
          );
        SQL

        db.exec <<-SQL
          CREATE TABLE messages (
              -- ... schema here
          );
        SQL

        # Record migration
        db.exec "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                [VERSION, Time.now.to_i]
      end

      def self.down(db)
        db.exec "DROP TABLE messages"
        db.exec "DELETE FROM schema_version WHERE version = ?", [VERSION]
      end
    end
  end
end
```

**Running Migrations:**

```ruby
# lib/heathrow/database.rb
def migrate_to_latest
  current = query("SELECT MAX(version) FROM schema_version").first&.first || 0

  Dir["lib/heathrow/migrations/*.rb"].sort.each do |file|
    require file
    migration = # ... load migration class
    next if migration::VERSION <= current

    transaction do
      migration.up(self)
      log.info "Applied migration #{migration::VERSION}"
    end
  end
end
```

---

## Backup & Recovery

**Automatic Backups:**
- Daily backup to `~/.heathrow/backups/heathrow-YYYYMMDD.db`
- Keep last 7 days
- Weekly backup kept for 4 weeks
- Monthly backup kept for 12 months

**Recovery:**
```bash
cp ~/.heathrow/backups/heathrow-20240115.db ~/.heathrow/heathrow.db
```

**Export:**
```bash
sqlite3 ~/.heathrow/heathrow.db .dump > backup.sql
```

**Import:**
```bash
sqlite3 ~/.heathrow/heathrow-new.db < backup.sql
```

---

## Performance Considerations

### Query Optimization

**Slow Query Log:**
- Log queries > 100ms
- Review monthly for optimization

**Common Optimizations:**
1. Use indices on WHERE clauses
2. Limit result sets with LIMIT
3. Use prepared statements
4. Batch inserts in transactions
5. Periodic VACUUM to reclaim space

### Size Management

**Estimated Growth:**
- 100 messages/day = ~50KB/day = ~18MB/year
- 1000 messages/day = ~500KB/day = ~180MB/year

**Cleanup Strategies:**
1. Archive old messages (> 1 year) to separate DB
2. Delete archived messages after 5 years
3. Compress attachments
4. Purge deleted messages permanently

---

## Security

### Encryption

**Encrypted Fields:**
- `sources.config` (credentials)
- `settings.encryption_key` (master key)

**Encryption Method:**
- AES-256-GCM
- Key derived from user password via PBKDF2
- Stored in system keychain (macOS/Linux)

**Implementation:**

```ruby
require 'openssl'

class Crypto
  def self.encrypt(plaintext, key)
    cipher = OpenSSL::Cipher.new('aes-256-gcm')
    cipher.encrypt
    cipher.key = key
    iv = cipher.random_iv
    encrypted = cipher.update(plaintext) + cipher.final
    auth_tag = cipher.auth_tag

    # Return: iv + auth_tag + encrypted
    [iv, auth_tag, encrypted].map { |d| Base64.strict_encode64(d) }.join(':')
  end

  def self.decrypt(ciphertext, key)
    iv, auth_tag, encrypted = ciphertext.split(':').map { |d| Base64.strict_decode64(d) }

    decipher = OpenSSL::Cipher.new('aes-256-gcm')
    decipher.decrypt
    decipher.key = key
    decipher.iv = iv
    decipher.auth_tag = auth_tag

    decipher.update(encrypted) + decipher.final
  end
end
```

### Access Control

- Database file permissions: `0600` (user read/write only)
- Config file permissions: `0600`
- Attachment directory: `0700`

---

## Testing Data

**Test Database:** `~/.heathrow/heathrow-test.db`

**Seed Script:** `lib/heathrow/seeds.rb`

```ruby
# Create test sources
gmail = Source.create(
  name: "Test Gmail",
  plugin_type: "gmail",
  config: {email: "test@example.com"}.to_json,
  capabilities: ["read", "write"].to_json
)

# Create test messages
100.times do |i|
  Message.create(
    source_id: gmail.id,
    external_id: "msg-#{i}",
    sender: "sender#{i % 10}@example.com",
    recipients: ["you@example.com"].to_json,
    subject: "Test message #{i}",
    content: "This is test message number #{i}.",
    timestamp: Time.now.to_i - (i * 3600),
    received_at: Time.now.to_i
  )
end
```

---

## Future Enhancements

1. **Message Sync State Table**
   - Track sync progress per source
   - Resume interrupted syncs

2. **Attachment Metadata Table**
   - Separate table for attachment details
   - Deduplication by hash

3. **Search History Table**
   - Save frequently used searches
   - Autocomplete suggestions

4. **Statistics Table**
   - Daily/weekly/monthly stats
   - Message counts by source
   - Response time tracking
