# Heathrow Plugin System

**Philosophy:** Every communication platform is a self-contained plugin with zero coupling to other plugins.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Plugin Lifecycle](#plugin-lifecycle)
3. [Plugin Interface](#plugin-interface)
4. [Plugin Discovery](#plugin-discovery)
5. [Error Handling](#error-handling)
6. [Testing Plugins](#testing-plugins)
7. [Example Plugins](#example-plugins)
8. [Plugin Development Guide](#plugin-development-guide)

---

## Architecture

### Core Principles

1. **Zero Coupling** - Plugins cannot interact with each other directly
2. **Fail Independently** - Plugin crash must not crash core or other plugins
3. **Hot Reload** - Plugins can be loaded/unloaded without restart
4. **Version Compatibility** - Old plugins work with new core (within major version)
5. **Sandboxed** - Plugins have limited access to system resources

### Plugin Isolation

```
┌─────────────────────────────────────────────┐
│           Core Application                  │
│  ┌────────────────────────────────────┐     │
│  │      Plugin Manager                │     │
│  │  ┌──────────────────────────────┐  │     │
│  │  │   Error Boundary (rescue)    │  │     │
│  │  │  ┌────────────────────────┐  │  │     │
│  │  │  │   Plugin Instance      │  │  │     │
│  │  │  │   - fetch_messages     │  │  │     │
│  │  │  │   - send_message       │  │  │     │
│  │  │  └────────────────────────┘  │  │     │
│  │  └──────────────────────────────┘  │     │
│  └────────────────────────────────────┘     │
└─────────────────────────────────────────────┘
```

**If plugin crashes:**
1. Error caught by boundary
2. Error logged
3. Plugin marked as failed
4. Other plugins continue working
5. UI shows error notification
6. User can retry or disable plugin

---

## Plugin Lifecycle

### States

```
┌──────────┐
│ Unloaded │
└────┬─────┘
     │ load_plugin(name)
     ▼
┌──────────┐  start() fails  ┌────────┐
│  Loaded  │────────────────>│ Failed │
└────┬─────┘                 └────┬───┘
     │ start() succeeds           │
     ▼                            │ retry
┌──────────┐                      │
│ Running  │<─────────────────────┘
└────┬─────┘
     │ stop() or error
     ▼
┌──────────┐
│ Stopped  │
└────┬─────┘
     │ unload_plugin(name)
     ▼
┌──────────┐
│ Unloaded │
└──────────┘
```

### Lifecycle Methods

```ruby
class MyPlugin < Heathrow::Plugin::Base
  # Called once when plugin is loaded
  def initialize(config, event_bus, db)
    super
    @connection = nil
  end

  # Called when plugin is started (connects to service)
  def start
    @connection = connect_to_service
    log(:info, "Connected successfully")
  end

  # Called when plugin is stopped (cleanup)
  def stop
    @connection&.close
    log(:info, "Disconnected")
  end

  # Main work methods
  def fetch_messages
    # ...
  end

  def send_message(message, target)
    # ...
  end
end
```

---

## Plugin Interface

### Base Class: `Heathrow::Plugin::Base`

**File:** `lib/heathrow/plugin/base.rb`

```ruby
module Heathrow
  module Plugin
    class Base
      attr_reader :name, :config, :capabilities, :state

      # Initialize plugin (do not connect to service here)
      # @param config [Hash] Plugin-specific configuration
      # @param event_bus [Heathrow::EventBus] For emitting events
      # @param db [Heathrow::Database] For storing data
      def initialize(config, event_bus, db)
        @config = config
        @event_bus = event_bus
        @db = db
        @state = :stopped
        @name = self.class.name.split('::').last.downcase
      end

      # Start the plugin (connect to service)
      # @raise [PluginError] If connection fails
      def start
        @state = :running
      end

      # Stop the plugin (disconnect, cleanup)
      def stop
        @state = :stopped
      end

      # Fetch new messages from the service
      # @param since [Integer, nil] Unix timestamp to fetch from
      # @return [Array<Heathrow::Message>] Array of messages
      def fetch_messages(since: nil)
        raise NotImplementedError, "#{self.class} must implement #fetch_messages"
      end

      # Send a message through this service
      # @param message [Heathrow::Message] Message to send
      # @param target [String, Hash] Target identifier (email, channel, etc.)
      # @return [Boolean] True if sent successfully
      # @raise [PluginError] If send fails
      def send_message(message, target)
        raise NotImplementedError, "#{self.class} must implement #send_message"
      end

      # Get plugin capabilities
      # @return [Array<Symbol>] Capability symbols
      def capabilities
        []
      end

      # Get current plugin status
      # @return [Hash] Status information
      def status
        {
          state: @state,
          name: @name,
          connected: @state == :running,
          last_sync: @last_sync,
          last_error: @last_error
        }
      end

      # Get plugin configuration schema (for UI)
      # @return [Hash] JSON Schema for config
      def self.config_schema
        {}
      end

      # Get plugin metadata
      # @return [Hash] Plugin information
      def self.metadata
        {
          name: name.split('::').last,
          description: "A Heathrow plugin",
          version: "1.0.0",
          author: "Unknown",
          two_way: false
        }
      end

      protected

      # Log a message
      # @param level [Symbol] :debug, :info, :warn, :error
      # @param message [String] Log message
      def log(level, message)
        @event_bus.publish(:log, {
          level: level,
          component: @name,
          message: message,
          timestamp: Time.now.to_i
        })
      end

      # Emit an event
      # @param type [Symbol] Event type
      # @param data [Hash] Event data
      def emit_event(type, data)
        @event_bus.publish(type, data.merge(plugin: @name))
      end

      # Store encrypted credential
      # @param key [String] Credential key
      # @param value [String] Credential value
      def store_credential(key, value)
        # Encrypt and store in database
        encrypted = Heathrow::Crypto.encrypt(value, encryption_key)
        @db.exec(
          "UPDATE sources SET config = json_set(config, '$.credentials.#{key}', ?) WHERE plugin_type = ?",
          [encrypted, @name]
        )
      end

      # Retrieve encrypted credential
      # @param key [String] Credential key
      # @return [String, nil] Decrypted credential
      def retrieve_credential(key)
        result = @db.query(
          "SELECT json_extract(config, '$.credentials.#{key}') FROM sources WHERE plugin_type = ?",
          [@name]
        ).first&.first

        return nil unless result
        Heathrow::Crypto.decrypt(result, encryption_key)
      end

      # Get encryption key from keychain
      # @return [String] Encryption key
      def encryption_key
        Heathrow::Keychain.get_or_create("heathrow.encryption_key")
      end

      # Normalize external message to Heathrow::Message format
      # @param external_msg [Object] Platform-specific message object
      # @return [Heathrow::Message] Normalized message
      def normalize_message(external_msg)
        raise NotImplementedError, "#{self.class} must implement #normalize_message"
      end
    end
  end
end
```

### Required Methods

Plugins **must** implement:

1. `fetch_messages(since: nil)` - Return array of `Heathrow::Message` objects
2. `capabilities` - Return array of capability symbols

Plugins **should** implement (if two-way):

3. `send_message(message, target)` - Send a message

### Optional Methods

Plugins **may** implement:

1. `start` - Custom connection logic
2. `stop` - Custom cleanup logic
3. `normalize_message(external)` - Convert platform format to Heathrow format
4. `search(query)` - Server-side search
5. `mark_read(message_id)` - Mark message as read on server
6. `delete_message(message_id)` - Delete message on server
7. `get_thread(thread_id)` - Fetch entire thread

---

## Plugin Discovery

### Automatic Discovery

Plugins are automatically discovered from:

1. `lib/heathrow/plugins/*.rb` (built-in)
2. `~/.heathrow/plugins/*.rb` (user-installed)
3. Gem plugins: `heathrow-plugin-*` (community)

### Registration

```ruby
# lib/heathrow/plugin/registry.rb
module Heathrow
  module Plugin
    class Registry
      @plugins = {}

      # Auto-register on class definition
      def self.register(plugin_class)
        name = plugin_class.name.split('::').last.downcase
        @plugins[name] = plugin_class
      end

      def self.get(name)
        @plugins[name]
      end

      def self.all
        @plugins.values
      end
    end

    class Base
      # Automatically register when subclassed
      def self.inherited(subclass)
        Registry.register(subclass)
      end
    end
  end
end
```

### Plugin Loading

```ruby
# lib/heathrow/plugin_manager.rb
module Heathrow
  class PluginManager
    def initialize(event_bus, config, db)
      @event_bus = event_bus
      @config = config
      @db = db
      @plugins = {}
    end

    def load_all
      # Load built-in plugins
      Dir["lib/heathrow/plugins/*.rb"].each { |f| require f }

      # Load user plugins
      user_plugin_dir = File.expand_path("~/.heathrow/plugins")
      Dir["#{user_plugin_dir}/*.rb"].each { |f| require f } if Dir.exist?(user_plugin_dir)

      # Load gem plugins
      Gem.find_files("heathrow/plugin/*.rb").each { |f| require f }

      # Instantiate configured plugins
      sources = @db.query("SELECT * FROM sources WHERE enabled = 1")
      sources.each do |source|
        load_plugin(source['plugin_type'], source['id'])
      end
    end

    def load_plugin(plugin_type, source_id)
      plugin_class = Plugin::Registry.get(plugin_type)
      raise "Unknown plugin: #{plugin_type}" unless plugin_class

      # Get source configuration
      source = @db.query("SELECT * FROM sources WHERE id = ?", [source_id]).first
      config = JSON.parse(source['config'])

      # Instantiate plugin with error boundary
      plugin = plugin_class.new(config, @event_bus, @db)
      plugin.start

      @plugins[source_id] = plugin
      @event_bus.publish(:plugin_loaded, {plugin: plugin_type, source_id: source_id})

    rescue => e
      @event_bus.publish(:plugin_error, {
        plugin: plugin_type,
        source_id: source_id,
        error: e.message,
        backtrace: e.backtrace
      })
      nil
    end

    def get_plugin(source_id)
      @plugins[source_id]
    end

    def unload_plugin(source_id)
      plugin = @plugins.delete(source_id)
      return unless plugin

      plugin.stop rescue nil  # Ignore errors during shutdown
      @event_bus.publish(:plugin_unloaded, {source_id: source_id})
    end

    def reload_plugin(source_id)
      unload_plugin(source_id)

      # Get plugin type for this source
      source = @db.query("SELECT plugin_type FROM sources WHERE id = ?", [source_id]).first
      load_plugin(source['plugin_type'], source_id)
    end
  end
end
```

---

## Error Handling

### Error Boundary Pattern

```ruby
# Every plugin method is wrapped in error boundary
def safe_fetch_messages(plugin, since: nil)
  plugin.fetch_messages(since: since)
rescue => e
  log_plugin_error(plugin, e)
  [] # Return empty array, don't crash
end

def log_plugin_error(plugin, error)
  @db.exec(
    "UPDATE sources SET last_error = ?, updated_at = ? WHERE id = ?",
    [error.message, Time.now.to_i, plugin.source_id]
  )

  @event_bus.publish(:plugin_error, {
    plugin: plugin.name,
    error: error.message,
    backtrace: error.backtrace.first(5)
  })
end
```

### Plugin-Specific Errors

```ruby
# lib/heathrow/plugin/errors.rb
module Heathrow
  module Plugin
    class Error < StandardError; end
    class ConnectionError < Error; end
    class AuthenticationError < Error; end
    class RateLimitError < Error; end
    class NotFoundError < Error; end
    class ValidationError < Error; end
  end
end
```

### Retry Strategy

```ruby
def fetch_with_retry(plugin, max_retries: 3)
  retries = 0

  begin
    plugin.fetch_messages
  rescue Plugin::RateLimitError => e
    # Wait and retry
    sleep_time = 2 ** retries
    log(:warn, "Rate limited, waiting #{sleep_time}s")
    sleep(sleep_time)
    retries += 1
    retry if retries < max_retries

    raise
  rescue Plugin::ConnectionError => e
    # Temporary network issue, retry
    retries += 1
    retry if retries < max_retries

    raise
  rescue Plugin::AuthenticationError => e
    # Don't retry, needs user intervention
    raise
  end
end
```

---

## Testing Plugins

### Unit Testing

```ruby
# test/plugins/test_gmail.rb
require 'minitest/autorun'
require_relative '../test_helper'

class TestGmailPlugin < Minitest::Test
  def setup
    @config = {
      'email' => 'test@example.com',
      'credentials' => 'mock_token'
    }
    @event_bus = MockEventBus.new
    @db = MockDatabase.new

    @plugin = Heathrow::Plugin::Gmail.new(@config, @event_bus, @db)
  end

  def test_capabilities
    assert_includes @plugin.capabilities, :read
    assert_includes @plugin.capabilities, :write
    assert_includes @plugin.capabilities, :attachments
  end

  def test_fetch_messages
    # Mock Gmail API response
    stub_gmail_api do
      messages = @plugin.fetch_messages
      assert_instance_of Array, messages
      assert messages.all? { |m| m.is_a?(Heathrow::Message) }
    end
  end

  def test_send_message
    message = Heathrow::Message.new(
      recipients: ['recipient@example.com'],
      subject: 'Test',
      content: 'Test message'
    )

    stub_gmail_api do
      assert @plugin.send_message(message, nil)
    end
  end

  def test_error_handling
    # Simulate network error
    stub_gmail_api_error(Net::ReadTimeout) do
      assert_raises(Heathrow::Plugin::ConnectionError) do
        @plugin.fetch_messages
      end
    end
  end
end
```

### Integration Testing

```ruby
# test/integration/test_gmail_live.rb
# These tests require real credentials and are skipped in CI

class TestGmailLive < Minitest::Test
  def setup
    skip unless ENV['HEATHROW_GMAIL_TEST_TOKEN']

    @config = {
      'email' => ENV['HEATHROW_GMAIL_TEST_EMAIL'],
      'credentials' => ENV['HEATHROW_GMAIL_TEST_TOKEN']
    }
    # ... setup
  end

  def test_real_connection
    @plugin.start
    assert_equal :running, @plugin.status[:state]
  end

  def test_real_fetch
    messages = @plugin.fetch_messages
    # Just verify it doesn't crash, actual count varies
    assert_instance_of Array, messages
  end
end
```

### Mock Helpers

```ruby
# test/mocks.rb
class MockEventBus
  def initialize
    @events = []
  end

  def publish(type, data)
    @events << {type: type, data: data}
  end

  def events_of_type(type)
    @events.select { |e| e[:type] == type }
  end
end

class MockDatabase
  def initialize
    @data = {}
  end

  def query(sql, params = [])
    # Simple mock implementation
    []
  end

  def exec(sql, params = [])
    # No-op
  end
end
```

---

## Example Plugins

### 1. Gmail Plugin (Two-way)

**File:** `lib/heathrow/plugins/gmail.rb`

```ruby
require 'google/apis/gmail_v1'
require 'googleauth'

module Heathrow
  module Plugin
    class Gmail < Base
      def self.metadata
        {
          name: "Gmail",
          description: "Gmail email integration via Google API",
          version: "1.0.0",
          author: "Heathrow Team",
          two_way: true
        }
      end

      def self.config_schema
        {
          type: "object",
          required: ["email"],
          properties: {
            email: {
              type: "string",
              format: "email",
              description: "Gmail address"
            },
            sync_labels: {
              type: "array",
              items: {type: "string"},
              default: ["INBOX"],
              description: "Labels to sync"
            },
            sync_days: {
              type: "integer",
              default: 30,
              description: "Days of history to sync"
            }
          }
        }
      end

      def initialize(config, event_bus, db)
        super
        @service = nil
      end

      def start
        super

        # Initialize Gmail API service
        @service = Google::Apis::GmailV1::GmailService.new
        @service.authorization = get_authorization

        # Test connection
        @service.get_user_profile('me')

        log(:info, "Connected to Gmail: #{@config['email']}")
      rescue Google::Apis::AuthorizationError => e
        raise Plugin::AuthenticationError, "Gmail auth failed: #{e.message}"
      rescue => e
        raise Plugin::ConnectionError, "Gmail connection failed: #{e.message}"
      end

      def stop
        super
        @service = nil
      end

      def capabilities
        [:read, :write, :attachments, :threads, :search]
      end

      def fetch_messages(since: nil)
        query = build_query(since)

        message_ids = fetch_message_ids(query)
        messages = message_ids.map { |id| fetch_message_detail(id) }

        messages.compact.map { |m| normalize_message(m) }

      rescue Google::Apis::RateLimitError => e
        raise Plugin::RateLimitError, "Gmail rate limit: #{e.message}"
      rescue => e
        log(:error, "Fetch failed: #{e.message}")
        raise Plugin::Error, e.message
      end

      def send_message(message, target = nil)
        raw_message = build_raw_message(message)

        @service.send_user_message(
          'me',
          Google::Apis::GmailV1::Message.new(raw: raw_message)
        )

        emit_event(:message_sent, {
          recipients: message.recipients,
          subject: message.subject
        })

        true
      rescue => e
        log(:error, "Send failed: #{e.message}")
        raise Plugin::Error, e.message
      end

      def search(query)
        # Implement Gmail search syntax
        fetch_messages(query: query)
      end

      private

      def get_authorization
        token = retrieve_credential('oauth_token')
        refresh_token = retrieve_credential('refresh_token')

        # Create OAuth2 credentials
        credentials = Google::Auth::UserRefreshCredentials.new(
          client_id: ENV['GMAIL_CLIENT_ID'],
          client_secret: ENV['GMAIL_CLIENT_SECRET'],
          refresh_token: refresh_token,
          access_token: token
        )

        # Refresh if needed
        credentials.refresh! if credentials.expired?

        # Store new token
        store_credential('oauth_token', credentials.access_token) if credentials.access_token != token

        credentials
      end

      def build_query(since)
        parts = []

        # Sync specific labels
        labels = @config['sync_labels'] || ['INBOX']
        parts << "label:(#{labels.join(' OR ')})"

        # Since timestamp
        if since
          date = Time.at(since).strftime('%Y/%m/%d')
          parts << "after:#{date}"
        else
          # Default: last N days
          days = @config['sync_days'] || 30
          parts << "newer_than:#{days}d"
        end

        parts.join(' ')
      end

      def fetch_message_ids(query)
        ids = []
        page_token = nil

        loop do
          result = @service.list_user_messages('me', q: query, page_token: page_token)
          ids.concat(result.messages.map(&:id)) if result.messages

          page_token = result.next_page_token
          break unless page_token
        end

        ids
      end

      def fetch_message_detail(message_id)
        @service.get_user_message('me', message_id, format: 'full')
      end

      def normalize_message(gmail_msg)
        headers = headers_to_hash(gmail_msg.payload.headers)

        Heathrow::Message.new(
          external_id: gmail_msg.id,
          thread_id: gmail_msg.thread_id,
          sender: headers['from'],
          recipients: parse_recipients(headers['to']),
          subject: headers['subject'],
          content: extract_body(gmail_msg.payload),
          html_content: extract_html(gmail_msg.payload),
          timestamp: gmail_msg.internal_date / 1000,
          received_at: Time.now.to_i,
          labels: gmail_msg.label_ids,
          metadata: {
            gmail_message_id: headers['message-id'],
            gmail_thread_id: gmail_msg.thread_id,
            gmail_labels: gmail_msg.label_ids
          }.to_json
        )
      end

      def headers_to_hash(headers)
        headers.each_with_object({}) do |h, hash|
          hash[h.name.downcase] = h.value
        end
      end

      def parse_recipients(to_header)
        return [] unless to_header
        to_header.split(',').map(&:strip)
      end

      def extract_body(payload)
        if payload.parts
          text_part = payload.parts.find { |p| p.mime_type == 'text/plain' }
          return decode_body(text_part.body.data) if text_part
        end

        decode_body(payload.body.data) if payload.body&.data
      end

      def extract_html(payload)
        if payload.parts
          html_part = payload.parts.find { |p| p.mime_type == 'text/html' }
          return decode_body(html_part.body.data) if html_part
        end

        nil
      end

      def decode_body(data)
        return nil unless data
        Base64.urlsafe_decode64(data)
      end

      def build_raw_message(message)
        # Build RFC 2822 email
        mail = <<~EMAIL
          From: #{@config['email']}
          To: #{message.recipients.join(', ')}
          Subject: #{message.subject}
          Content-Type: text/plain; charset=UTF-8

          #{message.content}
        EMAIL

        Base64.urlsafe_encode64(mail, padding: false)
      end
    end
  end
end
```

### 2. RSS Plugin (One-way)

**File:** `lib/heathrow/plugins/rss.rb`

```ruby
require 'rss'
require 'open-uri'

module Heathrow
  module Plugin
    class Rss < Base
      def self.metadata
        {
          name: "RSS",
          description: "RSS/Atom feed reader",
          version: "1.0.0",
          author: "Heathrow Team",
          two_way: false
        }
      end

      def self.config_schema
        {
          type: "object",
          required: ["feed_url"],
          properties: {
            feed_url: {
              type: "string",
              format: "uri",
              description: "RSS feed URL"
            },
            update_interval: {
              type: "integer",
              default: 3600,
              description: "Update interval in seconds"
            }
          }
        }
      end

      def capabilities
        [:read]
      end

      def fetch_messages(since: nil)
        feed = fetch_feed
        items = feed.items

        # Filter by timestamp if provided
        items = items.select { |i| i.pubDate.to_i > since } if since

        items.map { |item| normalize_message(item) }

      rescue => e
        log(:error, "Feed fetch failed: #{e.message}")
        []
      end

      private

      def fetch_feed
        URI.open(@config['feed_url']) do |rss|
          RSS::Parser.parse(rss)
        end
      end

      def normalize_message(item)
        Heathrow::Message.new(
          external_id: item.guid&.content || item.link,
          sender: @config['feed_url'],
          recipients: [],
          subject: item.title,
          content: strip_html(item.description || item.content_encoded),
          html_content: item.description || item.content_encoded,
          timestamp: item.pubDate.to_i,
          received_at: Time.now.to_i,
          metadata: {
            rss_link: item.link,
            rss_categories: item.categories.map(&:content)
          }.to_json
        )
      end

      def strip_html(html)
        return '' unless html
        html.gsub(/<[^>]+>/, '').strip
      end
    end
  end
end
```

### 3. Slack Plugin (Two-way, Real-time)

**File:** `lib/heathrow/plugins/slack.rb`

```ruby
require 'slack-ruby-client'

module Heathrow
  module Plugin
    class Slack < Base
      def self.metadata
        {
          name: "Slack",
          description: "Slack workspace integration",
          version: "1.0.0",
          author: "Heathrow Team",
          two_way: true
        }
      end

      def capabilities
        [:read, :write, :real_time, :threads, :reactions]
      end

      def start
        super

        # Initialize Slack client
        ::Slack.configure do |config|
          config.token = retrieve_credential('token')
        end

        @client = ::Slack::Web::Client.new
        @rtm_client = ::Slack::RealTime::Client.new

        # Test connection
        auth = @client.auth_test
        log(:info, "Connected to Slack: #{auth.team}")

        # Start real-time client
        start_rtm

      rescue ::Slack::Web::Api::Errors::SlackError => e
        raise Plugin::AuthenticationError, "Slack auth failed: #{e.message}"
      end

      def stop
        super
        @rtm_client&.stop!
      end

      def fetch_messages(since: nil)
        messages = []

        # Fetch from configured channels
        channels = @config['sync_channels'] || []
        channels.each do |channel_name|
          channel = find_channel(channel_name)
          next unless channel

          history = @client.conversations_history(
            channel: channel['id'],
            oldest: since || (Time.now.to_i - 86400)  # Default: last 24h
          )

          messages.concat(history.messages.map { |m| normalize_message(m, channel) })
        end

        messages
      end

      def send_message(message, target)
        channel = find_channel(target)
        raise Plugin::NotFoundError, "Channel not found: #{target}" unless channel

        @client.chat_postMessage(
          channel: channel['id'],
          text: message.content,
          thread_ts: message.metadata&.dig('slack_thread_ts')
        )

        true
      end

      private

      def start_rtm
        @rtm_client.on :message do |data|
          next if data.subtype  # Skip edited, deleted, etc.

          channel = find_channel_by_id(data.channel)
          message = normalize_message(data, channel)

          emit_event(:message_received, {message: message})
        end

        Thread.new { @rtm_client.start! }
      end

      def find_channel(name)
        @channels_cache ||= @client.conversations_list.channels
        @channels_cache.find { |c| c.name == name }
      end

      def find_channel_by_id(id)
        @channels_cache ||= @client.conversations_list.channels
        @channels_cache.find { |c| c.id == id }
      end

      def normalize_message(slack_msg, channel)
        Heathrow::Message.new(
          external_id: slack_msg.ts,
          thread_id: slack_msg.thread_ts || slack_msg.ts,
          sender: get_user_name(slack_msg.user),
          recipients: [channel['name']],
          subject: "#{channel['name']} - Slack",
          content: slack_msg.text,
          timestamp: slack_msg.ts.to_f.to_i,
          received_at: Time.now.to_i,
          metadata: {
            slack_channel: channel['name'],
            slack_channel_id: channel['id'],
            slack_ts: slack_msg.ts,
            slack_thread_ts: slack_msg.thread_ts
          }.to_json
        )
      end

      def get_user_name(user_id)
        @users_cache ||= {}
        @users_cache[user_id] ||= begin
          user = @client.users_info(user: user_id).user
          user.profile.display_name.empty? ? user.name : user.profile.display_name
        end
      end
    end
  end
end
```

---

## Plugin Development Guide

### Step-by-Step: Creating a New Plugin

#### 1. Create Plugin File

```bash
touch lib/heathrow/plugins/myservice.rb
```

#### 2. Define Plugin Class

```ruby
module Heathrow
  module Plugin
    class Myservice < Base
      def self.metadata
        {
          name: "MyService",
          description: "Integration with MyService platform",
          version: "1.0.0",
          author: "Your Name",
          two_way: true  # or false for read-only
        }
      end

      def capabilities
        [:read, :write]  # Adjust based on what you implement
      end

      # Implement required methods...
    end
  end
end
```

#### 3. Implement Required Methods

```ruby
def fetch_messages(since: nil)
  # 1. Connect to service API
  # 2. Fetch messages since timestamp
  # 3. Convert to Heathrow::Message objects
  # 4. Return array
  []
end

def send_message(message, target)
  # 1. Connect to service API
  # 2. Send message to target
  # 3. Return true on success
  # 4. Raise Plugin::Error on failure
  true
end
```

#### 4. Add Configuration Schema

```ruby
def self.config_schema
  {
    type: "object",
    required: ["api_key"],
    properties: {
      api_key: {
        type: "string",
        description: "MyService API key"
      },
      sync_interval: {
        type: "integer",
        default: 300,
        description: "Sync interval in seconds"
      }
    }
  }
end
```

#### 5. Test Your Plugin

```ruby
# test/plugins/test_myservice.rb
class TestMyservice < Minitest::Test
  def test_fetch_messages
    # Mock API, test fetch logic
  end

  def test_send_message
    # Mock API, test send logic
  end
end
```

#### 6. Document Your Plugin

```ruby
# Add to docs/PLUGINS.md
## MyService Plugin

**Type:** Two-way
**Capabilities:** read, write

### Configuration

- `api_key` (required): Your MyService API key
- `sync_interval` (optional): Sync interval in seconds (default: 300)

### Setup

1. Get API key from https://myservice.com/api
2. Add source in Heathrow configuration
3. Test connection
```

---

## Best Practices

### 1. Error Handling

Always use specific error types:

```ruby
def fetch_messages(since: nil)
  response = api_call

  case response.code
  when 401
    raise Plugin::AuthenticationError, "Invalid credentials"
  when 429
    raise Plugin::RateLimitError, "Rate limit exceeded"
  when 404
    raise Plugin::NotFoundError, "Resource not found"
  when 500..599
    raise Plugin::ConnectionError, "Server error: #{response.code}"
  end

  # Process response...
rescue Timeout::Error
  raise Plugin::ConnectionError, "Request timeout"
rescue JSON::ParserError => e
  raise Plugin::Error, "Invalid response format: #{e.message}"
end
```

### 2. Credentials

Never log or expose credentials:

```ruby
def start
  api_key = retrieve_credential('api_key')

  # Good
  log(:info, "Connecting to service...")

  # Bad - leaks credential
  # log(:info, "Using API key: #{api_key}")

  connect(api_key)
end
```

### 3. Rate Limiting

Respect API rate limits:

```ruby
def fetch_messages(since: nil)
  # Implement backoff
  sleep(rate_limit_delay) if rate_limited?

  # Batch requests
  message_ids.each_slice(100) do |batch|
    fetch_batch(batch)
  end
end
```

### 4. Caching

Cache expensive operations:

```ruby
def get_user_name(user_id)
  @user_cache ||= {}
  @user_cache[user_id] ||= fetch_user_from_api(user_id).name
end
```

### 5. Logging

Log important events:

```ruby
def fetch_messages(since: nil)
  log(:debug, "Fetching messages since #{since || 'beginning'}")

  messages = do_fetch

  log(:info, "Fetched #{messages.count} messages")

  messages
rescue => e
  log(:error, "Fetch failed: #{e.message}")
  raise
end
```

---

## Plugin Testing Checklist

Before submitting a plugin, test:

- [ ] Connection/authentication
- [ ] Fetch messages (empty, small, large batches)
- [ ] Send message
- [ ] Handle network errors gracefully
- [ ] Handle rate limits
- [ ] Handle authentication errors
- [ ] Plugin can be stopped and restarted
- [ ] No memory leaks on long runs
- [ ] Credentials are encrypted
- [ ] No credentials in logs
- [ ] Works with proxy (if applicable)
- [ ] Handles malformed API responses
- [ ] Thread-safe (if using real-time)

---

## Community Plugins

To publish a community plugin:

1. Create gem: `heathrow-plugin-myservice`
2. Include plugin class in `lib/heathrow/plugin/myservice.rb`
3. Add README with setup instructions
4. Publish to RubyGems
5. Submit PR to add to official plugin directory

**Plugin Gem Template:**

```
heathrow-plugin-myservice/
├── lib/
│   └── heathrow/
│       └── plugin/
│           └── myservice.rb
├── test/
│   └── test_myservice.rb
├── README.md
├── LICENSE
└── heathrow-plugin-myservice.gemspec
```

---

This plugin system ensures every integration is isolated, testable, and can fail independently without bringing down Heathrow.
