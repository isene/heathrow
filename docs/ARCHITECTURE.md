# Heathrow Architecture

**Design Philosophy:** Modularity, isolation, testability, and resilience.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Layer Architecture](#layer-architecture)
3. [Component Isolation](#component-isolation)
4. [Data Flow](#data-flow)
5. [Concurrency Model](#concurrency-model)
6. [Error Handling Strategy](#error-handling-strategy)
7. [Testing Strategy](#testing-strategy)
8. [Performance Considerations](#performance-considerations)

---

## System Overview

Heathrow is structured as a layered system where each layer has clear responsibilities and well-defined interfaces. No component can bypass its layer or access components outside its scope directly.

### Core Principles

1. **Single Responsibility** - Each component does one thing well
2. **Interface Segregation** - Components depend on abstractions, not implementations
3. **Dependency Inversion** - High-level modules don't depend on low-level modules
4. **Open/Closed** - Open for extension (plugins), closed for modification (core)
5. **Fail-Safe** - Component failure doesn't cascade to other components

### High-Level Architecture

```
┌───────────────────────────────────────────────────────────┐
│                      User                                 │
└─────────────────────────┬─────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────┐
│                    UI Layer                               │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  rcurses (TUI Framework)                            │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │  │
│  │  │  Panes   │ │  Input   │ │  Render  │            │  │
│  │  └──────────┘ └──────────┘ └──────────┘            │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────┬─────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────┐
│               Application Layer                           │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐  │
│  │   Message    │ │     View     │ │     Filter       │  │
│  │   Router     │ │   Manager    │ │     Engine       │  │
│  └──────────────┘ └──────────────┘ └──────────────────┘  │
│  ┌──────────────┐ ┌──────────────┐                       │
│  │   Stream     │ │   Search     │                       │
│  │   Manager    │ │   Engine     │                       │
│  └──────────────┘ └──────────────┘                       │
└─────────────────────────┬─────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────┐
│                    Core Layer                             │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐  │
│  │   Plugin     │ │    Config    │ │    Database      │  │
│  │   Manager    │ │   Manager    │ │     Layer        │  │
│  └──────────────┘ └──────────────┘ └──────────────────┘  │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐  │
│  │    Event     │ │    Logger    │ │      Cache       │  │
│  │     Bus      │ │              │ │                  │  │
│  └──────────────┘ └──────────────┘ └──────────────────┘  │
└─────────────────────────┬─────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────┐
│                   Plugin Layer                            │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ │
│  │ Gmail  │ │ Slack  │ │Discord │ │  RSS   │ │  IRC   │ │
│  └────────┘ └────────┘ └────────┘ └────────┘ └────────┘ │
│  ┌────────┐ ┌────────┐ ┌────────┐                        │
│  │WhatsApp│ │Telegram│ │ Reddit │        [...]           │
│  └────────┘ └────────┘ └────────┘                        │
└───────────────────────────────────────────────────────────┘
```

---

## Layer Architecture

### 1. UI Layer

**Responsibility:** User interaction and display

**Components:**
- Pane Manager (`lib/heathrow/ui/pane_manager.rb`)
- Input Handler (`lib/heathrow/ui/input_handler.rb`)
- Renderer (`lib/heathrow/ui/renderer.rb`)
- Key Binding Manager (`lib/heathrow/ui/key_bindings.rb`)

**Interface:**

```ruby
module Heathrow
  module UI
    class Application
      # Initialize UI with application layer dependencies
      def initialize(message_router, view_manager, event_bus)

      # Main event loop
      def run

      # Handle user input
      def handle_input(key)

      # Refresh display
      def refresh

      # Shutdown
      def shutdown
    end
  end
end
```

**Dependencies:**
- Down: Application Layer (message_router, view_manager)
- Up: None (top layer)

**Isolation:**
- UI crashes don't affect data layer
- Can be replaced with different UI (web, GUI) without changing logic
- No business logic in UI components

---

### 2. Application Layer

**Responsibility:** Business logic and workflows

**Components:**

#### Message Router

Routes messages to appropriate views based on filter rules.

**File:** `lib/heathrow/message_router.rb`

```ruby
module Heathrow
  class MessageRouter
    def initialize(filter_engine, view_manager, db)

    # Route a single message
    def route_message(message)

    # Route multiple messages (batch)
    def route_messages(messages)

    # Get messages for a specific view
    def messages_for_view(view_id)
  end
end
```

#### View Manager

Manages views (buffers) and their configurations.

**File:** `lib/heathrow/view_manager.rb`

```ruby
module Heathrow
  class ViewManager
    def initialize(db, filter_engine)

    # Get all views
    def all_views

    # Get view by ID
    def get_view(id)

    # Get view by key binding
    def get_view_by_key(key)

    # Create new view
    def create_view(name, filters, key_binding: nil)

    # Update view
    def update_view(id, attributes)

    # Delete view
    def delete_view(id)

    # Get remainder view (catch-all)
    def remainder_view
  end
end
```

#### Filter Engine

Evaluates filter rules against messages.

**File:** `lib/heathrow/filter_engine.rb`

```ruby
module Heathrow
  class FilterEngine
    def initialize

    # Check if message matches filter
    def matches?(message, filter)

    # Evaluate complex filter expression
    def evaluate(message, expression)

    # Parse filter string to AST
    def parse_filter(filter_string)
  end
end
```

#### Stream Manager

Manages real-time message streams from plugins.

**File:** `lib/heathrow/stream_manager.rb`

```ruby
module Heathrow
  class StreamManager
    def initialize(plugin_manager, event_bus, message_router)

    # Start streaming from plugin
    def start_stream(source_id)

    # Stop streaming
    def stop_stream(source_id)

    # Get active streams
    def active_streams
  end
end
```

#### Search Engine

Full-text search across all messages.

**File:** `lib/heathrow/search_engine.rb`

```ruby
module Heathrow
  class SearchEngine
    def initialize(db)

    # Search messages
    def search(query, filters: {})

    # Save search
    def save_search(name, query)

    # Get saved searches
    def saved_searches
  end
end
```

**Dependencies:**
- Down: Core Layer (database, event_bus, plugin_manager)
- Up: UI Layer

**Isolation:**
- Business logic independent of UI
- Can run headless (for testing, automation)
- No direct plugin access (only through plugin_manager)

---

### 3. Core Layer

**Responsibility:** Infrastructure services

**Components:**

#### Plugin Manager

**File:** `lib/heathrow/plugin_manager.rb`

```ruby
module Heathrow
  class PluginManager
    def initialize(event_bus, config, db)

    # Load all enabled plugins
    def load_all

    # Load specific plugin
    def load_plugin(plugin_type, source_id)

    # Unload plugin
    def unload_plugin(source_id)

    # Reload plugin
    def reload_plugin(source_id)

    # Get plugin instance
    def get_plugin(source_id)

    # List all loaded plugins
    def list_plugins
  end
end
```

#### Config Manager

**File:** `lib/heathrow/config.rb`

```ruby
module Heathrow
  class Config
    def initialize(config_path = "~/.heathrow/config.yml")

    # Get config value (supports dot notation: "ui.theme")
    def get(key_path, default = nil)

    # Set config value
    def set(key_path, value)

    # Save to disk
    def save

    # Reload from disk
    def reload

    # Validate configuration
    def validate
  end
end
```

#### Database Layer

**File:** `lib/heathrow/database.rb`

```ruby
module Heathrow
  class Database
    def initialize(db_path = "~/.heathrow/heathrow.db")

    # Execute statement (INSERT, UPDATE, DELETE)
    def exec(sql, params = [])

    # Query data (SELECT)
    def query(sql, params = [])

    # Transaction wrapper
    def transaction(&block)

    # Migrate to latest schema version
    def migrate_to_latest

    # Backup database
    def backup
  end
end
```

#### Event Bus

**File:** `lib/heathrow/event_bus.rb`

```ruby
module Heathrow
  class EventBus
    def initialize

    # Subscribe to event type
    # Returns handler_id for unsubscribing
    def subscribe(event_type, &handler)

    # Unsubscribe handler
    def unsubscribe(handler_id)

    # Publish event
    def publish(event_type, data)

    # Clear all handlers
    def clear

    # Get subscription count
    def subscription_count(event_type = nil)
  end
end
```

**Event Types:**

```ruby
# Message events
:message_received     # New message fetched
:message_sent         # Message sent successfully
:message_read         # Message marked as read
:message_starred      # Message starred
:message_archived     # Message archived

# Plugin events
:plugin_loaded        # Plugin loaded successfully
:plugin_unloaded      # Plugin unloaded
:plugin_error         # Plugin encountered error
:plugin_reconnecting  # Plugin attempting reconnect

# View events
:view_changed         # User switched views
:view_created         # New view created
:view_deleted         # View deleted

# UI events
:ui_refresh           # UI needs refresh
:ui_resize            # Terminal resized

# Sync events
:sync_started         # Sync began
:sync_completed       # Sync finished
:sync_failed          # Sync error

# Search events
:search_executed      # Search performed

# Log events
:log                  # Log message
```

#### Logger

**File:** `lib/heathrow/logger.rb`

```ruby
module Heathrow
  class Logger
    def initialize(log_path = "~/.heathrow/heathrow.log")

    # Log methods
    def debug(component, message)
    def info(component, message)
    def warn(component, message)
    def error(component, message, exception = nil)

    # Rotate log files
    def rotate

    # Set log level
    def level=(level)  # :debug, :info, :warn, :error
  end
end
```

#### Cache

**File:** `lib/heathrow/cache.rb`

```ruby
module Heathrow
  class Cache
    def initialize(ttl: 300)

    # Get cached value
    def get(key)

    # Set cached value
    def set(key, value, ttl: nil)

    # Delete cached value
    def delete(key)

    # Clear all cache
    def clear

    # Clear expired entries
    def prune
  end
end
```

**Dependencies:**
- Down: None (bottom layer - only system libraries)
- Up: Application Layer, Plugin Layer

**Isolation:**
- Infrastructure services used by all layers
- No business logic
- Highly tested and stable

---

### 4. Plugin Layer

**Responsibility:** External service integrations

**Components:**
- Individual plugins (Gmail, Slack, Discord, etc.)
- Plugin Base Class

**File Structure:**

```
lib/heathrow/plugins/
├── gmail.rb
├── slack.rb
├── discord.rb
├── telegram.rb
├── rss.rb
├── reddit.rb
├── irc.rb
└── ...
```

**Dependencies:**
- Down: None (external APIs only)
- Up: Core Layer (plugin_manager)

**Isolation:**
- Plugins are completely isolated from each other
- Plugin crash doesn't affect other plugins or core
- Plugins loaded/unloaded independently
- Plugins communicate only via Event Bus
- No direct plugin-to-plugin calls

---

## Component Isolation

### Isolation Guarantees

| Component      | Can Access         | Cannot Access        | Failure Impact |
|----------------|--------------------|----------------------|----------------|
| UI Layer       | Application Layer  | Core, Plugins        | UI only        |
| Message Router | Core Layer         | Plugins directly     | Routing only   |
| View Manager   | DB, Filter Engine  | Plugins, UI          | Views only     |
| Filter Engine  | None               | All others           | Filtering only |
| Plugin Manager | DB, Event Bus      | Plugins' internals   | Plugin mgmt    |
| Plugin (Gmail) | Core API only      | Other plugins, UI    | Gmail only     |
| Database       | SQLite only        | All others           | ✗ CRITICAL     |
| Event Bus      | Logger only        | All others           | ✗ CRITICAL     |

### Critical Components

These components **must never crash**:

1. **Database** - All data access
2. **Event Bus** - All inter-component communication
3. **Logger** - Debugging and audit trail
4. **Config Manager** - System configuration

**Protection Strategy:**
- Extensive unit testing (100% coverage)
- Integration testing
- Defensive programming (validate all inputs)
- Fallback mechanisms
- No external dependencies (use stdlib only)

### Safe Components

These components **can crash safely**:

1. **Plugins** - Isolated, can be restarted
2. **Filter Engine** - Defaults to "show all" if fails
3. **Search Engine** - Non-essential feature
4. **Cache** - Can be cleared and rebuilt

**Recovery Strategy:**
- Error boundaries catch exceptions
- Log error details
- Notify user
- Continue with degraded functionality
- Allow retry

---

## Data Flow

### Message Ingestion Flow

```
1. Plugin fetches messages from external service
   │
   ▼
2. Plugin.normalize_message() converts to Heathrow::Message
   │
   ▼
3. Plugin emits :message_received event
   │
   ▼
4. StreamManager receives event
   │
   ▼
5. StreamManager passes to MessageRouter
   │
   ▼
6. MessageRouter saves to Database
   │
   ▼
7. MessageRouter evaluates filter rules
   │
   ▼
8. MessageRouter updates view message counts
   │
   ▼
9. MessageRouter emits :ui_refresh event
   │
   ▼
10. UI refreshes display
```

### Message Sending Flow

```
1. User composes message in UI
   │
   ▼
2. UI creates Heathrow::Message object
   │
   ▼
3. UI calls MessageRouter.send_message()
   │
   ▼
4. MessageRouter determines target plugin
   │
   ▼
5. MessageRouter calls Plugin.send_message()
   │
   ▼
6. Plugin sends via external API
   │
   ▼
7. Plugin saves to Database (sent messages)
   │
   ▼
8. Plugin emits :message_sent event
   │
   ▼
9. UI shows confirmation
```

### View Switching Flow

```
1. User presses view key (e.g., "1")
   │
   ▼
2. UI calls ViewManager.get_view_by_key("1")
   │
   ▼
3. ViewManager queries Database for view
   │
   ▼
4. ViewManager returns View object
   │
   ▼
5. UI calls MessageRouter.messages_for_view(view.id)
   │
   ▼
6. MessageRouter queries Database with view filters
   │
   ▼
7. MessageRouter returns Message[]
   │
   ▼
8. UI renders messages in pane
   │
   ▼
9. UI emits :view_changed event
```

---

## Concurrency Model

### Threading Strategy

**Main Thread:**
- UI event loop
- User input handling
- Rendering

**Background Threads:**
- Plugin real-time streams (one thread per plugin)
- Periodic sync tasks
- Database operations (via connection pool)

**Thread Safety:**

```ruby
# Database: Thread-safe via mutex
class Database
  def initialize(db_path)
    @db = SQLite3::Database.new(db_path)
    @mutex = Mutex.new
  end

  def query(sql, params = [])
    @mutex.synchronize do
      @db.execute(sql, params)
    end
  end
end

# Event Bus: Thread-safe via Queue
class EventBus
  def initialize
    @handlers = {}
    @queue = Queue.new
    @mutex = Mutex.new

    # Start event processing thread
    start_processor
  end

  def publish(event_type, data)
    @queue.push([event_type, data])
  end

  private

  def start_processor
    Thread.new do
      loop do
        event_type, data = @queue.pop
        dispatch(event_type, data)
      end
    end
  end

  def dispatch(event_type, data)
    handlers = @mutex.synchronize { @handlers[event_type]&.dup || [] }
    handlers.each { |h| h.call(data) rescue nil }
  end
end

# Plugin Streams: Isolated threads
class StreamManager
  def start_stream(source_id)
    plugin = @plugin_manager.get_plugin(source_id)

    thread = Thread.new do
      loop do
        begin
          messages = plugin.fetch_messages
          messages.each { |m| @message_router.route_message(m) }
          sleep plugin.poll_interval
        rescue => e
          log_error(plugin, e)
          sleep 60  # Backoff on error
        end
      end
    end

    @streams[source_id] = thread
  end
end
```

### Synchronization Points

**Critical Sections:**
1. Database writes (protected by mutex)
2. Event handler registration (protected by mutex)
3. Plugin list modifications (protected by mutex)

**Lock-Free Sections:**
1. Reading messages from DB (read-only, no locks needed)
2. Filter evaluation (pure function, no state)
3. Message rendering (read-only)

---

## Error Handling Strategy

### Error Hierarchy

```
StandardError
│
├─ Heathrow::Error (base for all Heathrow errors)
│  │
│  ├─ Heathrow::ConfigError
│  │  ├─ InvalidConfigError
│  │  └─ MissingConfigError
│  │
│  ├─ Heathrow::DatabaseError
│  │  ├─ MigrationError
│  │  └─ QueryError
│  │
│  ├─ Heathrow::Plugin::Error
│  │  ├─ ConnectionError
│  │  ├─ AuthenticationError
│  │  ├─ RateLimitError
│  │  ├─ NotFoundError
│  │  └─ ValidationError
│  │
│  └─ Heathrow::UIError
│     ├─ RenderError
│     └─ InputError
```

### Error Boundaries

**UI Layer:**

```ruby
def run
  loop do
    begin
      key = get_input
      handle_input(key)
      refresh
    rescue UIError => e
      show_error_message(e.message)
      log(:error, "UI error: #{e.message}")
      # Continue running
    rescue => e
      log(:error, "Unexpected error: #{e.message}")
      show_crash_screen(e)
      # Attempt to continue or graceful shutdown
    end
  end
end
```

**Plugin Layer:**

```ruby
def fetch_messages_safe(plugin)
  plugin.fetch_messages
rescue Plugin::RateLimitError => e
  log(:warn, "Rate limited: #{plugin.name}")
  schedule_retry(plugin, delay: 60)
  []
rescue Plugin::ConnectionError => e
  log(:warn, "Connection error: #{plugin.name}")
  schedule_retry(plugin, delay: 30)
  []
rescue Plugin::AuthenticationError => e
  log(:error, "Auth failed: #{plugin.name}")
  notify_user("Please re-authenticate #{plugin.name}")
  disable_plugin(plugin)
  []
rescue => e
  log(:error, "Plugin crashed: #{plugin.name} - #{e.message}")
  disable_plugin(plugin)
  []
end
```

**Database Layer:**

```ruby
def query(sql, params = [])
  @mutex.synchronize do
    @db.execute(sql, params)
  end
rescue SQLite3::SQLException => e
  log(:error, "SQL error: #{e.message}")
  raise DatabaseError, "Query failed: #{e.message}"
rescue => e
  log(:error, "Unexpected DB error: #{e.message}")
  # Attempt to reconnect
  reconnect
  retry
end
```

### Recovery Strategies

| Error Type           | Strategy                          | User Impact |
|----------------------|-----------------------------------|-------------|
| Plugin crash         | Disable plugin, notify user       | Loss of one source |
| Database locked      | Retry with backoff                | Brief delay |
| Config invalid       | Use defaults, notify user         | Degraded UX |
| UI render error      | Clear screen, re-render           | Brief flicker |
| Network timeout      | Retry, then skip                  | Delayed sync |
| Rate limit           | Backoff, retry later              | Delayed sync |
| Auth expired         | Prompt re-auth                    | User action required |
| Out of memory        | Clear cache, log warning          | Slower performance |
| Disk full            | Notify user, stop syncing         | No new messages |

---

## Testing Strategy

### Test Pyramid

```
         ┌─────────────┐
         │  Manual     │  ← 5% (exploratory testing)
         │  Testing    │
       ┌─┴─────────────┴─┐
       │  Integration    │  ← 20% (component interaction)
       │  Tests          │
     ┌─┴─────────────────┴─┐
     │  Unit Tests         │  ← 75% (component isolation)
     └─────────────────────┘
```

### Unit Testing

**Goal:** Test individual components in isolation

**Coverage Target:** 90%+ for critical components, 70%+ overall

**Example:**

```ruby
# test/test_filter_engine.rb
class TestFilterEngine < Minitest::Test
  def setup
    @engine = Heathrow::FilterEngine.new
    @message = Heathrow::Message.new(
      sender: "test@example.com",
      subject: "Test message",
      content: "Hello world",
      read: false
    )
  end

  def test_simple_equality_filter
    filter = {field: "sender", op: "=", value: "test@example.com"}
    assert @engine.matches?(@message, filter)
  end

  def test_complex_and_filter
    filter = {
      rules: [
        {field: "read", op: "=", value: false},
        {field: "sender", op: "=", value: "test@example.com"}
      ],
      logic: "AND"
    }
    assert @engine.matches?(@message, filter)
  end
end
```

### Integration Testing

**Goal:** Test component interaction

**Coverage:** Key workflows and data flows

**Example:**

```ruby
# test/integration/test_message_flow.rb
class TestMessageFlow < Minitest::Test
  def setup
    @db = Database.new(":memory:")
    @event_bus = EventBus.new
    @config = Config.new
    @plugin_manager = PluginManager.new(@event_bus, @config, @db)
    @message_router = MessageRouter.new(@filter_engine, @view_manager, @db)
  end

  def test_message_ingestion_to_view
    # 1. Create test plugin
    source_id = create_test_source("test_plugin")
    plugin = @plugin_manager.load_plugin("test_plugin", source_id)

    # 2. Create test view
    view = @view_manager.create_view("Test", {field: "sender", op: "=", value: "test@example.com"})

    # 3. Fetch messages
    messages = plugin.fetch_messages

    # 4. Route to views
    messages.each { |m| @message_router.route_message(m) }

    # 5. Verify messages in view
    view_messages = @message_router.messages_for_view(view.id)
    assert view_messages.count > 0
  end
end
```

### End-to-End Testing

**Goal:** Test complete user workflows

**Coverage:** Critical paths only

**Example:**

```ruby
# test/e2e/test_user_workflows.rb
class TestUserWorkflows < Minitest::Test
  def test_read_and_reply_workflow
    # 1. Start application
    app = Heathrow::UI::Application.new

    # 2. Simulate view switch
    app.handle_input("1")  # Switch to view 1

    # 3. Simulate message selection
    app.handle_input("j")  # Move down
    app.handle_input("ENTER")  # Open message

    # 4. Verify message marked as read
    message = app.current_message
    assert message.read

    # 5. Simulate reply
    app.handle_input("r")  # Reply
    # ... compose and send

    # 6. Verify reply sent
    assert_event_published(:message_sent)
  end
end
```

### Test Helpers

```ruby
# test/test_helper.rb
module TestHelper
  def create_test_message(overrides = {})
    defaults = {
      external_id: SecureRandom.uuid,
      sender: "test@example.com",
      subject: "Test",
      content: "Test message",
      timestamp: Time.now.to_i,
      received_at: Time.now.to_i
    }
    Heathrow::Message.new(defaults.merge(overrides))
  end

  def create_test_source(plugin_type)
    @db.exec(
      "INSERT INTO sources (name, plugin_type, config, capabilities, enabled, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      ["Test Source", plugin_type, "{}", '["read"]', 1, Time.now.to_i, Time.now.to_i]
    )
    @db.query("SELECT last_insert_rowid()").first.first
  end
end
```

---

## Performance Considerations

### Performance Budget

| Operation              | Target     | Maximum   |
|------------------------|------------|-----------|
| UI refresh             | < 50ms     | < 100ms   |
| View switch            | < 100ms    | < 200ms   |
| Message fetch (100)    | < 2s       | < 5s      |
| Database query         | < 20ms     | < 50ms    |
| Search query           | < 100ms    | < 500ms   |
| Send message           | < 1s       | < 3s      |
| Memory (idle)          | < 50MB     | < 100MB   |
| Memory (active)        | < 100MB    | < 200MB   |

### Optimization Strategies

**Database:**
- Index frequently queried columns
- Use prepared statements
- Batch inserts in transactions
- Periodic VACUUM
- Archive old messages

**UI:**
- Lazy rendering (only visible messages)
- Virtual scrolling for long lists
- Debounce rapid input
- Cache rendered content

**Plugins:**
- Connection pooling
- Request batching
- Response caching
- Rate limit respect

**Memory:**
- Weak references for caches
- Periodic cache pruning
- Stream processing (don't load all at once)
- Profile for leaks

### Monitoring

```ruby
# lib/heathrow/performance_monitor.rb
module Heathrow
  class PerformanceMonitor
    def measure(operation)
      start = Time.now
      result = yield
      duration = ((Time.now - start) * 1000).round(2)

      log(:debug, "#{operation}: #{duration}ms")

      if duration > threshold_for(operation)
        log(:warn, "Slow operation #{operation}: #{duration}ms")
      end

      result
    end

    private

    def threshold_for(operation)
      {
        "ui_refresh" => 100,
        "database_query" => 50,
        "message_fetch" => 5000,
        "view_switch" => 200
      }[operation] || 1000
    end
  end
end
```

---

## Deployment Topology

### Single-User Desktop

```
┌────────────────────────────────┐
│  User's Computer               │
│  ┌──────────────────────────┐  │
│  │  Heathrow Process        │  │
│  │  ┌────────────────────┐  │  │
│  │  │  UI (Terminal)     │  │  │
│  │  ├────────────────────┤  │  │
│  │  │  Application       │  │  │
│  │  ├────────────────────┤  │  │
│  │  │  Core + Plugins    │  │  │
│  │  └────────────────────┘  │  │
│  │  ┌────────────────────┐  │  │
│  │  │  SQLite DB         │  │  │
│  │  │  ~/.heathrow/      │  │  │
│  │  └────────────────────┘  │  │
│  └──────────────────────────┘  │
└────────────────────────────────┘
```

### Client-Server (Future)

```
┌─────────────────┐          ┌──────────────────────┐
│  Client         │          │  Server              │
│  ┌───────────┐  │          │  ┌────────────────┐  │
│  │ UI Only   │  │  <───>   │  │  Application   │  │
│  └───────────┘  │   REST   │  │  + Core        │  │
│                 │          │  │  + Plugins     │  │
│                 │          │  └────────────────┘  │
│                 │          │  ┌────────────────┐  │
│                 │          │  │  PostgreSQL    │  │
│                 │          │  └────────────────┘  │
└─────────────────┘          └──────────────────────┘
```

---

This architecture ensures Heathrow is modular, testable, and resilient. Each component can be developed, tested, and deployed independently without breaking other parts of the system.
