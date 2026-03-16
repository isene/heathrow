#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

module Heathrow
  class SourceManager
    attr_reader :sources, :db, :source_instances
    
    def initialize(database)
      @db = database
      @sources = {}
      @source_instances = {}
      load_sources
    end
    
    def load_sources
      # Load all configured sources from database
      db_sources = @db.get_all_sources
      db_sources.each do |source|
        @sources[source['id']] = source

        # Create source instance if module exists
        if source['enabled']
          instance = create_source_instance(source)
          @source_instances[source['id']] = instance if instance
        end
      end
    end

    def reload
      @sources = {}
      @source_instances = {}
      load_sources
    end
    
    def create_source_instance(source)
      source_type = (source['plugin_type'] || source['type']).to_s.downcase
      
      # Try to load the source module
      begin
        # Handle 'web' as 'webpage' for the module
        module_name = source_type == 'web' ? 'webpage' : source_type
        require_relative module_name
        
        # Get the class (e.g., Heathrow::Sources::RSS, Heathrow::Sources::Webpage)
        class_name = case module_name
                     when 'rss' then 'RSS'
                     when 'webpage' then 'Webpage'
                     when 'messenger' then 'Messenger'
                     when 'instagram' then 'Instagram'
                     when 'weechat' then 'Weechat'
                     # Custom source types loaded from ~/.heathrow/plugins/
                     else module_name.capitalize
                     end
        source_class = Heathrow::Sources.const_get(class_name)
        
        # Parse config if it's JSON
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        
        # Create instance
        source_class.new(source['name'], config, @db)
      rescue LoadError => e
        STDERR.puts "Source module not found: #{source_type}" if ENV['DEBUG']
        nil
      rescue => e
        STDERR.puts "Error loading source #{source['name']}: #{e.message}" if ENV['DEBUG']
        nil
      end
    end
    
    def poll_sources
      messages = []
      
      @source_instances.each do |source_id, instance|
        next unless instance.enabled?
        
        # Check if enough time has passed since last poll
        if instance.last_fetch
          next if Time.now.to_i - instance.last_fetch < instance.poll_interval
        end
        
        begin
          new_messages = instance.fetch
          messages.concat(new_messages) if new_messages
        rescue => e
          STDERR.puts "Error polling #{instance.name}: #{e.message}" if ENV['DEBUG']
        end
      end
      
      messages
    end
    
    def add_source(source_type, config)
      # Generate unique ID
      source_id = "#{source_type}_#{Time.now.to_i}"
      
      # Use default color based on source type if not provided
      default_color = get_default_color_for_type(source_type)
      
      # Save to database
      @db.add_source(
        source_id,
        source_type,
        config[:name],
        config,
        config[:polling_interval] || 300,
        config[:color] || default_color,
        true # enabled by default
      )
      
      # Add to local cache
      @sources[source_id] = {
        'id' => source_id,
        'type' => source_type,
        'name' => config[:name],
        'config' => config,
        'color' => config[:color] || get_default_color_for_type(source_type),
        'poll_interval' => config[:polling_interval] || 300,
        'enabled' => true,
        'last_poll' => nil
      }
      
      source_id
    end
    
    # Default colors for new sources (stored in DB at creation time).
    # Runtime display colors come from the theme system in application.rb.
    SOURCE_TYPE_COLORS = {
      'email' => 39, 'gmail' => 33, 'maildir' => 39, 'whatsapp' => 40,
      'discord' => 99, 'reddit' => 202, 'rss' => 226, 'telegram' => 51,
      'slack' => 35, 'web' => 208, 'weechat' => 75
    }.freeze

    def get_default_color_for_type(source_type)
      SOURCE_TYPE_COLORS[source_type.to_s.downcase] || 15
    end
    
    def remove_source(source_id)
      @db.execute("DELETE FROM sources WHERE id = ?", source_id)
      @sources.delete(source_id)
    end
    
    def toggle_source(source_id)
      source = @sources[source_id]
      return unless source
      
      new_status = source['enabled'] ? 0 : 1
      @db.execute("UPDATE sources SET enabled = ? WHERE id = ?", new_status, source_id)
      source['enabled'] = !source['enabled']
    end
    
    def get_source_types
      {
        'gmail' => {
          name: 'Gmail (OAuth2)',
          description: 'Connect to Gmail using OAuth2 (requires setup - see fields below)',
          icon: '✉',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true },
            { key: 'email', label: 'Gmail Address', type: 'text', required: true, placeholder: 'you@gmail.com' },
            { key: 'safedir', label: 'Safe Directory', type: 'text', required: true, default: File.join(Dir.home, '.heathrow', 'mail'),
              help: 'Dir with OAuth files: email.json (credentials) & email.txt (refresh token)' },
            { key: 'oauth2_script', label: 'OAuth2 Script', type: 'text', default: '~/bin/oauth2.py',
              help: 'Get from: github.com/google/gmail-oauth2-tools/blob/master/python/oauth2.py' },
            { key: 'folder', label: 'Folder', type: 'text', default: 'INBOX' },
            { key: 'fetch_limit', label: 'Max messages per fetch', type: 'number', default: 50 },
            { key: 'mark_as_read', label: 'Mark as read (CAUTION)', type: 'boolean', default: false },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 300 }
          ]
        },
        'imap' => {
          name: 'Email (IMAP)',
          description: 'Connect to any IMAP email server with username/password',
          icon: '📧',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true },
            { key: 'imap_server', label: 'IMAP Server', type: 'text', required: true, placeholder: 'imap.example.com' },
            { key: 'imap_port', label: 'IMAP Port', type: 'number', default: 993 },
            { key: 'username', label: 'Username/Email', type: 'text', required: true },
            { key: 'password', label: 'Password', type: 'password', required: true },
            { key: 'use_ssl', label: 'Use SSL/TLS', type: 'boolean', default: true },
            { key: 'folder', label: 'Folder', type: 'text', default: 'INBOX' },
            { key: 'fetch_limit', label: 'Max messages per fetch', type: 'number', default: 50 },
            { key: 'mark_as_read', label: 'Mark fetched as read', type: 'boolean', default: false },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 300 }
          ]
        },
        'whatsapp' => {
          name: 'WhatsApp',
          description: 'Connect via WhatsApp Web (requires API server)',
          icon: '◉',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true },
            { key: 'api_url', label: 'WhatsApp API URL', type: 'text', default: 'http://localhost:8080',
              help: 'URL of the WhatsApp API server (whatsmeow)' },
            { key: 'use_pairing_code', label: 'Use pairing code instead of QR?', type: 'boolean', default: false,
              help: 'Use 8-digit pairing code instead of QR code scanning' },
            { key: 'phone_number', label: 'Phone Number (for pairing code)', type: 'text', placeholder: '1234567890',
              help: 'Required only if using pairing code method' },
            { key: 'fetch_limit', label: 'Messages per fetch', type: 'number', default: 50 },
            { key: 'incremental_sync', label: 'Incremental sync', type: 'boolean', default: true,
              help: 'Only fetch new messages since last sync' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 60 }
          ]
        },
        'telegram' => {
          name: 'Telegram',
          description: 'Connect to Telegram via Bot or User account',
          icon: '✈',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true },
            { key: 'bot_token', label: 'Bot Token (if using bot)', type: 'password', required: false, 
              help: 'Get from @BotFather in Telegram. Leave empty for user account.' },
            { key: 'api_id', label: 'API ID (if using user account)', type: 'text', required: false, 
              help: 'Get from https://my.telegram.org - only for user account' },
            { key: 'api_hash', label: 'API Hash (if using user account)', type: 'password', required: false,
              help: 'Get from https://my.telegram.org - only for user account' },
            { key: 'phone_number', label: 'Phone Number (if using user account)', type: 'text', required: false, 
              placeholder: '+1234567890', help: 'Required for user account authentication' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 60 }
          ]
        },
        'discord' => {
          name: 'Discord',
          description: 'Connect to Discord servers and channels',
          icon: '💬',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true },
            { key: 'token', label: 'Bot Token', type: 'password', required: true,
              help: 'Bot token from Discord Developer Portal (starts with MTM...)' },
            { key: 'is_bot', label: 'Is Bot Token?', type: 'boolean', default: true,
              help: 'Set to true for bot tokens, false for user tokens (not recommended)' },
            { key: 'channels', label: 'Channel IDs', type: 'text', placeholder: '1234567890,0987654321',
              help: 'Comma-separated Discord channel IDs to monitor' },
            { key: 'guilds', label: 'Guild/Server IDs', type: 'text', placeholder: 'Optional',
              help: 'Monitor all channels in these guilds (comma-separated)' },
            { key: 'fetch_limit', label: 'Messages per fetch', type: 'number', default: 20 },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 60 }
          ]
        },
        'reddit' => {
          name: 'Reddit',
          description: 'Monitor subreddits and messages',
          icon: '®',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true },
            { key: 'client_id', label: 'Client ID', type: 'text', required: true },
            { key: 'client_secret', label: 'Client Secret', type: 'password', required: true },
            { key: 'user_agent', label: 'User Agent', type: 'text', required: true, default: 'Heathrow/1.0' },
            { key: 'username', label: 'Username (optional)', type: 'text' },
            { key: 'password', label: 'Password (optional)', type: 'password' },
            { key: 'subreddits', label: 'Subreddits to monitor', type: 'text', placeholder: 'AskReddit,news,technology' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 300 }
          ]
        },
        'rss' => {
          name: 'RSS/Atom Feeds',
          description: 'Subscribe to RSS and Atom feeds',
          icon: '◈',
          fields: [
            { key: 'name', label: 'Feed Collection Name', type: 'text', required: true },
            { key: 'feeds', label: 'Feed URLs (one per line)', type: 'multiline', required: true, placeholder: "https://news.ycombinator.com/rss\nhttps://example.com/feed.xml" },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 900 }
          ]
        },
        'web' => {
          name: 'Web Page Monitor',
          description: 'Monitor web pages for changes (use setup_webwatch.rb to configure)',
          icon: '◎',
          fields: [
            { key: 'name', label: 'Collection Name', type: 'text', required: true },
            { key: 'pages', label: 'Pages (JSON array)', type: 'multiline', required: true,
              placeholder: '[{"url": "https://example.com", "title": "Example", "selector": "#content"}]' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 3600 }
          ]
        },
        'messenger' => {
          name: 'Facebook Messenger',
          description: 'Read Messenger DMs via browser cookies (no app needed)',
          icon: '◉',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true, default: 'Messenger' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 300 }
          ]
        },
        'instagram' => {
          name: 'Instagram DMs',
          description: 'Read Instagram direct messages via browser cookies (no app needed)',
          icon: '◈',
          fields: [
            { key: 'name', label: 'Account Name', type: 'text', required: true, default: 'Instagram' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 300 }
          ]
        },
        'slack' => {
          name: 'Slack',
          description: 'Connect to Slack workspaces',
          icon: '#',
          fields: [
            { key: 'name', label: 'Workspace Name', type: 'text', required: true },
            { key: 'token', label: 'Bot/User Token', type: 'password', required: true, placeholder: 'xoxb-...' },
            { key: 'channels', label: 'Channel IDs (optional)', type: 'text', placeholder: 'C1234567890,C0987654321' },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 60 }
          ]
        },
        'weechat' => {
          name: 'WeeChat Relay',
          description: 'Connect to WeeChat relay for IRC, Slack, and other buffers',
          icon: 'W',
          fields: [
            { key: 'name', label: 'Source Name', type: 'text', required: true, default: 'WeeChat' },
            { key: 'host', label: 'Relay Host', type: 'text', required: true, default: 'localhost',
              help: 'Host running WeeChat relay (use SSH tunnel for remote)' },
            { key: 'port', label: 'Relay Port', type: 'number', required: true, default: 8001 },
            { key: 'password', label: 'Relay Password', type: 'password', required: true },
            { key: 'buffer_filter', label: 'Buffer Filter', type: 'text',
              help: 'Comma-separated patterns, e.g.: irc.*,python.slack.* (empty = all)' },
            { key: 'lines_per_buffer', label: 'Lines per buffer', type: 'number', default: 30 },
            { key: 'polling_interval', label: 'Check interval (seconds)', type: 'number', default: 120 }
          ]
        },
        # Additional source types can be added via plugins in ~/.heathrow/plugins/
      }
    end
  end
end