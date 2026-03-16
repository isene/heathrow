# Heathrow - Universal Communication Terminal
## Complete Implementation Plan

**Vision:** Replace mutt, weechat, newsboat, messenger, discord, reddit, whatsapp, slack, teams, and more with one unified terminal application.

**Metaphor:** Like Heathrow Airport - all communication "flights" route through one central hub with multiple terminals (platforms), gates (channels), arrivals (inbox), and departures (outbox).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Phase 0: Foundation](#phase-0-foundation)
3. [Phase 1: Email Mastery](#phase-1-email-mastery)
4. [Phase 2: Chat Platforms](#phase-2-chat-platforms)
5. [Phase 3: Social & News](#phase-3-social--news)
6. [Phase 4: Proprietary Messengers](#phase-4-proprietary-messengers)
5. [Phase 5: Advanced Features](#phase-5-advanced-features)
6. [Phase 6: Polish & Distribution](#phase-6-polish--distribution)
7. [Development Principles](#development-principles)
8. [Timeline](#timeline)

---

## Architecture Overview

### Core Principle: Modular Isolation

Every component is a self-contained LEGO piece:
- **No shared state** between plugins
- **Clear interfaces** defined via contracts
- **Independent testing** for each module
- **Graceful degradation** if one plugin fails
- **Hot-reload capability** for plugins without restart

### System Layers

```
┌─────────────────────────────────────────────────────────┐
│                    UI Layer (rcurses)                   │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐  │
│  │  Panes  │ │  Input  │ │ Render  │ │  Key Binding │  │
│  └─────────┘ └─────────┘ └─────────┘ └──────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                   Application Layer                     │
│  ┌──────────────┐ ┌─────────────┐ ┌─────────────────┐  │
│  │   Message    │ │    View     │ │     Filter      │  │
│  │   Router     │ │   Manager   │ │     Engine      │  │
│  └──────────────┘ └─────────────┘ └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                     Core Layer                          │
│  ┌──────────────┐ ┌─────────────┐ ┌─────────────────┐  │
│  │   Plugin     │ │   Config    │ │    Database     │  │
│  │   Manager    │ │   Manager   │ │     Layer       │  │
│  └──────────────┘ └─────────────┘ └─────────────────┘  │
│  ┌──────────────┐ ┌─────────────┐ ┌─────────────────┐  │
│  │    Event     │ │   Logger    │ │     Cache       │  │
│  │    Bus       │ │             │ │                 │  │
│  └──────────────┘ └─────────────┘ └─────────────────┘  │
└─────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────┐
│                    Plugin Layer                         │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐ │
│  │ Gmail  │ │ Slack  │ │Discord │ │  RSS   │ │ etc. │ │
│  └────────┘ └────────┘ └────────┘ └────────┘ └──────┘ │
└─────────────────────────────────────────────────────────┘
```

### Component Isolation Matrix

| Component      | Depends On           | Used By              | Can Break? |
|----------------|----------------------|----------------------|------------|
| Plugin         | Core API only        | Plugin Manager       | ✓ Safe     |
| Plugin Manager | Event Bus, Logger    | Application Layer    | ✗ Critical |
| Message Router | Database, Event Bus  | Application Layer    | ✗ Critical |
| Filter Engine  | Message Router       | View Manager         | ✓ Safe     |
| View Manager   | Filter Engine, DB    | UI Layer             | ✓ Safe     |
| UI Layer       | Application Layer    | User                 | ✗ Critical |
| Database       | None                 | All layers           | ✗ Critical |
| Event Bus      | Logger               | All components       | ✗ Critical |

**Legend:**
- ✓ Safe: Can crash without bringing down the system
- ✗ Critical: Must never crash (extensive testing required)

---

## Phase 0: Foundation

**Goal:** Build unbreakable core that all future features rely on.

**Duration:** 2-4 weeks

**Success Criteria:** Can add new plugin without touching core code.

### 0.1: Project Rename (Heathrow → Heathrow)

**Files to modify:**
- `bin/heathrow` → `bin/heathrow`
- `lib/heathrow.rb` → `lib/heathrow.rb`
- `lib/heathrow/*` → `lib/heathrow/*`
- `README.md`
- `CLAUDE.md`
- All require statements

**Testing:** Ensure app still runs after rename.

**Isolation:** This is purely cosmetic, no logic changes.

### 0.2: Database Layer (Critical Component)

**File:** `lib/heathrow/database.rb`

**Interface:**
```ruby
module Heathrow
  class Database
    def initialize(db_path)
    def exec(sql, params = [])
    def query(sql, params = [])
    def transaction(&block)
    def migrate(version)
  end
end
```

**Schema:** See `docs/DATABASE_SCHEMA.md`

**Testing:**
- Unit tests for each method
- Transaction rollback tests
- Concurrent access tests
- Migration tests

**Isolation:** Only this class touches SQLite directly.

### 0.3: Configuration Manager (Critical Component)

**File:** `lib/heathrow/config.rb`

**Interface:**
```ruby
module Heathrow
  class Config
    def initialize(config_path = "~/.heathrow/config.yml")
    def get(key_path)  # e.g., "plugins.gmail.enabled"
    def set(key_path, value)
    def save
    def reload
    def validate
  end
end
```

**Configuration Structure:** See `docs/CONFIGURATION.md`

**Testing:**
- Load/save round-trip
- Nested key access
- Validation rules
- Default values

**Isolation:** Only this class reads config files.

### 0.4: Event Bus (Critical Component)

**File:** `lib/heathrow/event_bus.rb`

**Interface:**
```ruby
module Heathrow
  class EventBus
    def subscribe(event_type, &handler)
    def unsubscribe(handler_id)
    def publish(event_type, data)
    def clear
  end
end
```

**Events:**
- `message:received`
- `message:sent`
- `message:read`
- `plugin:loaded`
- `plugin:error`
- `view:changed`
- `ui:refresh`

**Testing:**
- Subscribe/unsubscribe
- Multiple handlers
- Error in handler doesn't crash bus
- Performance (1000+ events/sec)

**Isolation:** Async event delivery, handlers can't block each other.

### 0.5: Plugin Manager (Critical Component)

**File:** `lib/heathrow/plugin_manager.rb`

**Interface:**
```ruby
module Heathrow
  class PluginManager
    def initialize(event_bus, config, db)
    def load_all
    def load_plugin(name)
    def unload_plugin(name)
    def get_plugin(name)
    def list_plugins
    def reload_plugin(name)
  end
end
```

**Plugin Discovery:**
- Scan `lib/heathrow/plugins/*.rb`
- Auto-register classes inheriting from `Heathrow::Plugin::Base`

**Testing:**
- Load valid plugin
- Handle invalid plugin gracefully
- Reload without memory leak
- Plugin crash doesn't crash manager

**Isolation:** Each plugin runs in its own error boundary.

### 0.6: Plugin Base Class (Critical Component)

**File:** `lib/heathrow/plugin/base.rb`

**Interface:**
```ruby
module Heathrow
  module Plugin
    class Base
      attr_reader :name, :config, :capabilities

      def initialize(config, event_bus, db)
      def start  # Called when plugin loads
      def stop   # Called when plugin unloads
      def fetch_messages  # Returns Message[]
      def send_message(message, target)
      def capabilities  # Returns Symbol[]
      def status  # Returns Hash (connected, last_sync, etc.)

      protected
      def log(level, message)
      def emit_event(type, data)
      def store_credential(key, value)
      def retrieve_credential(key)
    end
  end
end
```

**Capabilities:**
- `:read` - Can fetch messages
- `:write` - Can send messages
- `:real_time` - Can stream messages (websocket/long-poll)
- `:attachments` - Supports file attachments
- `:threads` - Supports threaded conversations
- `:search` - Supports server-side search
- `:reactions` - Supports emoji reactions
- `:typing` - Supports typing indicators

**Testing:**
- Base class provides defaults
- Subclass can override
- Error handling wrapper

**Isolation:** Plugins can only access core via this interface.

### 0.7: Message Model (Critical Component)

**File:** `lib/heathrow/message.rb`

**Interface:**
```ruby
module Heathrow
  class Message
    attr_accessor :id, :source_id, :external_id, :thread_id
    attr_accessor :sender, :recipients, :subject, :content
    attr_accessor :html_content, :timestamp, :read, :starred
    attr_accessor :labels, :metadata

    def initialize(attributes = {})
    def to_h
    def self.from_h(hash)
    def save(db)
    def self.find(db, id)
    def self.where(db, conditions)
  end
end
```

**Testing:**
- Serialization round-trip
- Database persistence
- Query methods
- Validation

**Isolation:** All plugins return this normalized format.

### 0.8: Logger (Critical Component)

**File:** `lib/heathrow/logger.rb`

**Interface:**
```ruby
module Heathrow
  class Logger
    def initialize(log_path = "~/.heathrow/heathrow.log")
    def debug(component, message)
    def info(component, message)
    def warn(component, message)
    def error(component, message, exception = nil)
    def rotate
  end
end
```

**Features:**
- Thread-safe
- Automatic rotation (10MB files, keep 5)
- Structured logging (JSON lines)
- Performance tracking

**Testing:**
- Concurrent writes
- Rotation logic
- Exception formatting

**Isolation:** Never crashes, swallows its own errors.

---

## Phase 1: Email Mastery

**Goal:** Replace mutt entirely.

**Duration:** 6-8 weeks

**Success Criteria:** Daily email workflow works better than mutt.

### 1.1: Gmail Plugin (Two-way)

**File:** `lib/heathrow/plugins/gmail.rb`

**Dependencies:**
- `google-api-client` gem
- OAuth2 token storage

**Features:**
- OAuth2 authentication flow
- Fetch emails (IMAP-like)
- Send emails (SMTP)
- Thread support
- Label management
- Search

**Testing:**
- Mock Gmail API responses
- Integration test with test account
- Rate limit handling

**Isolation:** Crashes don't affect other plugins.

### 1.2: Generic IMAP/SMTP Plugin (Two-way)

**File:** `lib/heathrow/plugins/imap_smtp.rb`

**Dependencies:**
- `net/imap` (stdlib)
- `net/smtp` (stdlib)

**Features:**
- Multi-account support
- TLS/SSL
- Folder management
- Server-side search

**Testing:**
- Mock IMAP server
- Various auth methods (PLAIN, LOGIN, CRAM-MD5)
- Connection failures

**Isolation:** Independent from Gmail plugin.

### 1.3: Email Composer UI

**File:** `lib/heathrow/ui/composer.rb`

**Interface:**
```ruby
module Heathrow
  module UI
    class Composer
      def initialize(pane, message = nil)  # nil for new, Message for reply
      def edit  # Returns Message or nil (cancelled)
      def add_attachment(path)
      def set_recipients(to, cc = [], bcc = [])
    end
  end
end
```

**Features:**
- Multi-line editor
- To/Cc/Bcc fields
- Subject line
- Attachment list
- Send/Cancel/Draft

**Testing:**
- Manual testing in terminal
- Key binding tests

**Isolation:** Only reads/writes Message objects.

### 1.4: Thread View

**File:** `lib/heathrow/ui/thread_view.rb`

**Features:**
- Group messages by thread_id
- Indent replies
- Collapse/expand threads
- Navigate within thread

**Testing:**
- Sample email threads
- UI rendering tests

**Isolation:** Independent component.

### 1.5: Attachment Handling

**File:** `lib/heathrow/attachment.rb`

**Features:**
- View in external program
- Save to disk
- Attach files to outgoing
- MIME type detection

**Testing:**
- Various file types
- Large files
- Missing files

**Isolation:** Separate module.

### 1.6: HTML Rendering

**File:** `lib/heathrow/html_renderer.rb`

**Dependencies:**
- `w3m` or `lynx` (external)

**Features:**
- Convert HTML to plain text
- Preserve links
- Handle images (show URLs)

**Testing:**
- Various HTML emails
- Fallback if w3m missing

**Isolation:** External process, can't crash app.

---

## Phase 2: Chat Platforms

**Goal:** Replace weechat for real-time chat.

**Duration:** 8-10 weeks

**Success Criteria:** Can chat on Slack/Discord/Telegram without switching apps.

### 2.1: Slack Plugin (Two-way)

**File:** `lib/heathrow/plugins/slack.rb`

**Dependencies:**
- `slack-ruby-client` gem or manual REST/RTM API

**Features:**
- OAuth authentication
- Real-time messaging (WebSocket)
- Channel list
- Direct messages
- File sharing
- Reactions
- Thread support

**Testing:**
- Mock Slack API
- Test workspace integration

**Isolation:** Independent plugin.

### 2.2: Discord Plugin (Two-way)

**File:** `lib/heathrow/plugins/discord.rb`

**Dependencies:**
- `discordrb` gem or manual gateway API

**Features:**
- Bot token auth
- Real-time messaging (gateway)
- Server/channel list
- Direct messages
- Embeds
- Reactions

**Testing:**
- Mock Discord gateway
- Test server integration

**Isolation:** Independent plugin.

### 2.3: Telegram Plugin (Two-way)

**File:** `lib/heathrow/plugins/telegram.rb`

**Dependencies:**
- `telegram-bot-ruby` gem

**Features:**
- Bot API
- User messaging
- Group chats
- Media handling
- Bot commands

**Testing:**
- Mock Telegram API
- Test bot integration

**Isolation:** Independent plugin.

### 2.4: Real-time Message Streaming

**File:** `lib/heathrow/stream_manager.rb`

**Interface:**
```ruby
module Heathrow
  class StreamManager
    def initialize(plugin_manager, event_bus)
    def start_stream(plugin_name)
    def stop_stream(plugin_name)
    def list_active_streams
  end
end
```

**Features:**
- Background threads for each plugin
- Auto-reconnect on disconnect
- Rate limit handling
- Message queue

**Testing:**
- Connection drops
- Rapid messages
- Thread safety

**Isolation:** Each stream in separate thread.

### 2.5: IRC Plugin (Two-way)

**File:** `lib/heathrow/plugins/irc.rb`

**Dependencies:**
- Manual TCP socket implementation (no gem)

**Features:**
- Multi-server connections
- Channel management
- Private messages
- CTCP
- SSL/TLS

**Testing:**
- Mock IRC server
- Integration with freenode test

**Isolation:** Independent plugin.

---

## Phase 3: Social & News

**Goal:** Replace newsboat and reddit clients.

**Duration:** 4-6 weeks

**Success Criteria:** Can read RSS feeds and browse reddit.

### 3.1: RSS/Atom Plugin (One-way)

**File:** `lib/heathrow/plugins/rss.rb`

**Dependencies:**
- `rss` (stdlib)

**Features:**
- Feed parsing
- Auto-discovery
- Update scheduling
- OPML import/export

**Testing:**
- Various feed formats
- Malformed feeds
- Network errors

**Isolation:** Independent plugin.

### 3.2: Reddit Plugin (Two-way)

**File:** `lib/heathrow/plugins/reddit.rb`

**Dependencies:**
- `redd` gem or manual OAuth2

**Features:**
- OAuth2 authentication
- Subreddit subscriptions
- Post/comment viewing
- Voting
- Posting/commenting
- Multireddits

**Testing:**
- Mock Reddit API
- Test account integration

**Isolation:** Independent plugin.

### 3.3: Mastodon/Fediverse Plugin (Two-way)

**File:** `lib/heathrow/plugins/mastodon.rb`

**Dependencies:**
- Manual API calls

**Features:**
- OAuth authentication
- Timeline viewing
- Tooting/replying
- Boost/favorite
- Notifications

**Testing:**
- Mock Mastodon API
- Test instance integration

**Isolation:** Independent plugin.

### 3.4: Hacker News Plugin (One-way, optional two-way)

**File:** `lib/heathrow/plugins/hackernews.rb`

**Dependencies:**
- Manual API calls (algolia HN API)

**Features:**
- Front page stories
- Comments
- Search
- User profile

**Testing:**
- Mock HN API

**Isolation:** Independent plugin.

---

## Phase 4: Proprietary Messengers

**Goal:** Bridge to WhatsApp, Messenger, Signal.

**Duration:** 6-8 weeks (reverse engineering required)

**Success Criteria:** Can message on WhatsApp without phone.

### 4.1: WhatsApp Plugin (Two-way)

**File:** `lib/heathrow/plugins/whatsapp.rb`

**Dependencies:**
- `whatsmeow` (Go binary wrapped) or Ruby port

**Features:**
- QR code auth
- Contact list
- Group chats
- Media handling
- End-to-end encryption maintained

**Testing:**
- Test account integration
- Connection stability

**Isolation:** Independent plugin, may require external process.

### 4.2: Facebook Messenger Plugin (Two-way)

**File:** `lib/heathrow/plugins/messenger.rb`

**Dependencies:**
- Unofficial API or bridge

**Features:**
- Cookie-based auth
- Message threads
- Group chats

**Testing:**
- Test account integration

**Isolation:** Independent plugin.

### 4.3: Signal Plugin (Two-way, if possible)

**File:** `lib/heathrow/plugins/signal.rb`

**Dependencies:**
- `signal-cli` (Java binary wrapped)

**Features:**
- Linked device
- Message send/receive
- Group support
- E2E encryption maintained

**Testing:**
- Test account integration

**Isolation:** External process wrapper.

---

## Phase 5: Advanced Features

**Goal:** Beyond replacement - innovation.

**Duration:** 4-6 weeks

**Success Criteria:** Power users can automate workflows.

### 5.1: Unified Search

**File:** `lib/heathrow/search.rb`

**Interface:**
```ruby
module Heathrow
  class Search
    def initialize(db)
    def query(search_string, filters = {})
    def save_search(name, search_string)
    def saved_searches
  end
end
```

**Features:**
- Full-text search (SQLite FTS5)
- Search syntax: `from:user subject:important after:2024-01-01`
- Saved searches
- Search across all sources

**Testing:**
- Various search queries
- Performance with large dataset

**Isolation:** Standalone module.

### 5.2: Filter Suggestion Engine

**File:** `lib/heathrow/filter_suggester.rb`

**Features:**
- Analyze message patterns
- Suggest automatic filters
- Learn from user actions

**Testing:**
- Sample datasets
- Suggestion quality

**Isolation:** Optional feature.

### 5.3: Scripting System

**File:** `lib/heathrow/scripting.rb`

**Interface:**
```ruby
# User scripts in ~/.heathrow/scripts/*.rb
# Example: auto-reply to specific senders

Heathrow.on :message_received do |msg|
  if msg.sender == "boss@company.com"
    reply = Heathrow::Message.new(
      subject: "Re: #{msg.subject}",
      content: "I'll look into this!",
      recipients: [msg.sender]
    )
    Heathrow.send_message(reply)
  end
end
```

**Features:**
- Ruby DSL for automation
- Safe sandbox
- Event hooks

**Testing:**
- Sample scripts
- Sandboxing effectiveness

**Isolation:** Scripts run in separate context.

### 5.4: Notification System

**File:** `lib/heathrow/notifier.rb`

**Features:**
- Desktop notifications (libnotify)
- Custom notification rules
- Sound alerts
- Urgency levels

**Testing:**
- Notification display
- Rule matching

**Isolation:** External process.

---

## Phase 6: Polish & Distribution

**Goal:** Production-ready, easy to install.

**Duration:** 2-4 weeks

**Success Criteria:** Non-technical users can install and use.

### 6.1: Installation Script

**File:** `install.sh`

**Features:**
- Detect OS
- Install dependencies
- Setup directories
- Initial configuration wizard

**Testing:**
- Fresh Ubuntu/Debian
- Fresh Fedora/RHEL
- macOS

**Isolation:** Standalone script.

### 6.2: Configuration Wizard

**File:** `lib/heathrow/wizard.rb`

**Features:**
- Interactive setup
- Source configuration
- View creation
- Test connections

**Testing:**
- Manual testing

**Isolation:** Only runs once.

### 6.3: Migration Tools

**File:** `lib/heathrow/migration/*.rb`

**Features:**
- Import from mutt config
- Import from weechat config
- Import from newsboat config

**Testing:**
- Sample config files

**Isolation:** Standalone tools.

### 6.4: Documentation

**Files:**
- `docs/USER_MANUAL.md`
- `docs/SETUP_GUIDE.md`
- `docs/TROUBLESHOOTING.md`
- `docs/API.md`
- `docs/PLUGIN_DEVELOPMENT.md`

**Testing:**
- Technical review
- User testing

### 6.5: Package Distribution

**Targets:**
- RubyGems: `gem install heathrow`
- Debian/Ubuntu: `.deb` package
- Fedora/RHEL: `.rpm` package
- macOS: Homebrew formula
- Arch Linux: AUR package
- Docker: `docker pull heathrow/heathrow`

**Testing:**
- Install on fresh systems

---

## Development Principles

### 1. One File = One Responsibility

Each file should have a single, clear purpose.

### 2. Interfaces First

Define the interface before implementation.

### 3. Test Before Merge

Every component needs tests before integration.

### 4. Error Boundaries

Plugins must not crash core. Core must not crash UI.

### 5. Backward Compatibility

Database migrations must be reversible.

### 6. Documentation as Code

Update docs with code changes, not after.

### 7. Security by Design

- Encrypt credentials at rest
- No passwords in logs
- Rate limit API calls
- Validate all inputs

### 8. Performance Budget

- UI must refresh < 100ms
- Message fetch < 5s
- Database query < 50ms
- Memory < 100MB idle

---

## Timeline

### Aggressive (6 months)

- **Month 1:** Phase 0 complete
- **Month 2:** Phase 1 (Email) complete
- **Month 3:** Phase 2 (Chat) 50% done
- **Month 4:** Phase 2 complete, Phase 3 (Social) complete
- **Month 5:** Phase 4 (Messengers) complete
- **Month 6:** Phase 5 & 6 complete

### Realistic (12 months)

- **Month 1-2:** Phase 0 complete (with extensive testing)
- **Month 3-4:** Phase 1 (Email) complete
- **Month 5-7:** Phase 2 (Chat) complete
- **Month 8-9:** Phase 3 (Social) complete
- **Month 10-11:** Phase 4 (Messengers) complete
- **Month 12:** Phase 5 & 6 complete

### Minimum Viable Product (3 months)

- **Month 1:** Phase 0 + Gmail plugin only
- **Month 2:** Phase 1 (Email only, Gmail + IMAP)
- **Month 3:** Phase 2 (Slack + Discord only)

**Recommendation:** Start with MVP, iterate based on user feedback.

---

## Next Steps

1. Review and approve this plan
2. Create GitHub milestones for each phase
3. Begin Phase 0.1: Rename project
4. Set up CI/CD pipeline
5. Create test framework

**Questions for user:**
- Prefer aggressive, realistic, or MVP timeline?
- Any platforms to prioritize/deprioritize?
- Any specific features critical for your workflow?
