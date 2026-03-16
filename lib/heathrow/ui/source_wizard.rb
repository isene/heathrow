#!/usr/bin/env ruby
# frozen_string_literal: true

module Heathrow
  class SourceWizard
    include Rcurses
    include Rcurses::Input
    include Rcurses::Cursor

    attr_reader :source_manager, :panes

    def initialize(source_manager, bottom_pane, right_pane)
      @source_manager = source_manager
      @panes = {
        bottom: bottom_pane,
        right: right_pane
      }
    end

    def run_wizard
      # Show source type selection with arrow navigation
      source_type = select_source_type
      return nil unless source_type

      # Get source configuration
      source_info = @source_manager.get_source_types[source_type]
      return nil unless source_info

      # Run type-specific wizard
      config = case source_type
               when 'web'
                 configure_webwatch
               when 'rss'
                 configure_rss
               when 'messenger'
                 configure_messenger
               when 'instagram'
                 configure_instagram
               when 'weechat'
                 configure_weechat
               else
                 configure_source(source_type, source_info)
               end
      return nil unless config

      # Add the source
      source_id = create_source(source_type, config)

      @panes[:bottom].clear
      @panes[:bottom].text = " Source '#{config[:name] || config['name']}' added!".fg(156)
      @panes[:bottom].refresh
      sleep(1)

      source_id
    end

    def select_source_type
      source_types = @source_manager.get_source_types
      keys = source_types.keys
      selected = 0

      loop do
        # Render list with arrow marker
        lines = []
        lines << "ADD SOURCE".b.fg(226)
        lines << ""

        keys.each_with_index do |key, i|
          info = source_types[key]
          marker = i == selected ? "→ " : "  "
          name_line = "#{marker}#{info[:icon]} #{info[:name]}"
          desc_line = "    #{info[:description]}"

          if i == selected
            lines << name_line.b.fg(39)
            lines << desc_line.fg(245)
          else
            lines << name_line.fg(250)
            lines << desc_line.fg(240)
          end
          lines << ""
        end

        lines << "j/k or arrows to navigate, Enter to select, ESC to cancel".fg(245)

        @panes[:right].clear
        @panes[:right].text = lines.join("\n")
        @panes[:right].refresh

        @panes[:bottom].clear
        @panes[:bottom].text = " Select source type...".fg(245)
        @panes[:bottom].refresh

        chr = getchr
        case chr
        when 'j', 'DOWN'
          selected = (selected + 1) % keys.size
        when 'k', 'UP'
          selected = (selected - 1) % keys.size
        when 'ENTER', "\r", "\n"
          return keys[selected]
        when 'ESC', "\e", 'q'
          return nil
        end
      end
    end

    # Web Watch: simple prompts for URL, title, selector
    def configure_webwatch
      pages = []

      @panes[:right].clear
      @panes[:right].text = [
        "WEB PAGE MONITOR SETUP".b.fg(226),
        "",
        "Add pages to monitor for changes.",
        "Each page is checked on refresh (C-R).",
        "",
        "Optional CSS selector limits monitoring",
        "to a specific part of the page:",
        "  #content  - element with id=\"content\"",
        "  .main     - elements with class=\"main\"",
        "  article   - all <article> elements",
        "",
        "Enter pages one at a time.",
        "Leave URL empty when done.",
      ].join("\n")
      @panes[:right].refresh

      loop do
        url = @panes[:bottom].ask("URL (Enter when done, ESC cancel): ", "")
        return nil if url.nil?
        break if url.empty?

        title = @panes[:bottom].ask("Title (optional): ", "")
        return nil if title.nil?

        selector = @panes[:bottom].ask("CSS selector (optional): ", "")
        return nil if selector.nil?

        tags_input = @panes[:bottom].ask("Tags (comma-separated, optional): ", "")
        return nil if tags_input.nil?
        tags = tags_input.empty? ? [] : tags_input.split(',').map(&:strip)

        page = { 'url' => url }
        page['title'] = title unless title.empty?
        page['selector'] = selector unless selector.empty?
        page['tags'] = tags unless tags.empty?
        pages << page

        @panes[:bottom].clear
        @panes[:bottom].text = " Added: #{title.empty? ? url : title} (#{pages.size} total)".fg(156)
        @panes[:bottom].refresh
        sleep(0.5)
      end

      return nil if pages.empty?

      { name: 'Web Watch', pages: pages, enabled: true }
    end

    # RSS: prompts for feed URLs with optional title/tags
    def configure_rss
      feeds = []

      @panes[:right].clear
      @panes[:right].text = [
        "RSS/ATOM FEED SETUP".b.fg(226),
        "",
        "Add feeds one at a time.",
        "Leave URL empty when done.",
        "",
        "Feeds from newsboat can be imported",
        "with: ruby setup_rss.rb",
      ].join("\n")
      @panes[:right].refresh

      loop do
        url = @panes[:bottom].ask("Feed URL (Enter when done, ESC cancel): ", "")
        return nil if url.nil?
        break if url.empty?

        title = @panes[:bottom].ask("Title (optional): ", "")
        return nil if title.nil?

        tags_input = @panes[:bottom].ask("Tags (comma-separated, optional): ", "")
        return nil if tags_input.nil?
        tags = tags_input.empty? ? [] : tags_input.split(',').map(&:strip)

        feed = { 'url' => url }
        feed['title'] = title unless title.empty?
        feed['tags'] = tags unless tags.empty?
        feeds << feed

        @panes[:bottom].clear
        @panes[:bottom].text = " Added: #{title.empty? ? url : title} (#{feeds.size} total)".fg(156)
        @panes[:bottom].refresh
        sleep(0.5)
      end

      return nil if feeds.empty?

      { name: 'RSS Feeds', feeds: feeds, enabled: true }
    end

    # Messenger: extract cookies from Firefox or manual entry
    def configure_messenger
      configure_meta_source(
        'FACEBOOK MESSENGER',
        'messenger',
        'messenger.com',
        %w[c_user xs],
        %w[datr fr],
        [
          "This connects to Messenger using your browser session.",
          "",
          "HOW IT WORKS:".b.fg(39),
          "  Heathrow reads your Firefox cookies to authenticate",
          "  with messenger.com — no password needed, no extra app.",
          "",
          "IMPORTANT:".b.fg(196),
          "  - Cookies expire when you log out of Facebook",
          "  - Sessions typically last 30-90 days",
          "  - If messages stop appearing, refresh cookies",
          "  - To refresh: press S → select Messenger → e → r",
          "",
          "PRIVACY:".b.fg(226),
          "  Cookies are stored locally in ~/.heathrow/cookies/",
          "  with restricted permissions (owner-only read/write).",
          "  They never leave your machine.",
        ]
      )
    end

    # Instagram: extract cookies from Firefox or manual entry
    def configure_instagram
      configure_meta_source(
        'INSTAGRAM DMs',
        'instagram',
        'instagram.com',
        %w[sessionid csrftoken],
        %w[ds_user_id ig_did mid],
        [
          "This connects to Instagram DMs using your browser session.",
          "",
          "HOW IT WORKS:".b.fg(39),
          "  Heathrow reads your Firefox cookies to authenticate",
          "  with instagram.com — no password needed, no extra app.",
          "",
          "IMPORTANT:".b.fg(196),
          "  - Cookies expire when you log out of Instagram",
          "  - Sessions typically last 30-90 days",
          "  - If messages stop appearing, refresh cookies",
          "  - Two-factor auth stays active — this is read-only",
          "",
          "PRIVACY:".b.fg(226),
          "  Cookies are stored locally in ~/.heathrow/cookies/",
          "  with restricted permissions (owner-only read/write).",
        ]
      )
    end

    # WeeChat Relay setup with connection test
    def configure_weechat
      @panes[:right].clear
      @panes[:right].text = [
        "WEECHAT RELAY SETUP".b.fg(226),
        "",
        "Connect to a running WeeChat instance via",
        "its relay protocol to read IRC, Slack, and",
        "other chat buffers.",
        "",
        "PREREQUISITES:".b.fg(39),
        "  WeeChat must have a relay enabled:",
        "  /relay add weechat 8001",
        "  /set relay.network.password \"yourpassword\"",
        "",
        "For remote servers, use an SSH tunnel:",
        "  ssh -L 8001:localhost:8001 user@host",
        "",
        "BUFFER FILTER:".b.fg(39),
        "  Comma-separated glob patterns to select",
        "  which buffers to import:",
        "  irc.*           - all IRC",
        "  python.slack.*  - all Slack",
        "  irc.oftc.*      - just OFTC network",
        "  (empty = import all message buffers)",
      ].join("\n")
      @panes[:right].refresh

      host = @panes[:bottom].ask("Relay host [localhost]: ", "localhost")
      return nil if host.nil?
      host = 'localhost' if host.empty?

      port = @panes[:bottom].ask("Relay port [8001]: ", "8001")
      return nil if port.nil?
      port = port.empty? ? 8001 : port.to_i

      password = @panes[:bottom].ask("Relay password: ", "")
      return nil if password.nil?

      buffer_filter = @panes[:bottom].ask("Buffer filter (empty = all): ", "")
      return nil if buffer_filter.nil?

      # Test connection
      @panes[:bottom].clear
      @panes[:bottom].text = " Testing connection to #{host}:#{port}...".fg(226)
      @panes[:bottom].refresh

      require_relative '../sources/weechat'
      test_config = { 'host' => host, 'port' => port, 'password' => password }
      test_instance = Heathrow::Sources::Weechat.new('WeeChat', test_config, @source_manager.db)
      result = test_instance.test_connection

      if result[:success]
        @panes[:bottom].clear
        @panes[:bottom].text = " #{result[:message]}".fg(156)
        @panes[:bottom].refresh
        sleep(1)

        config = {
          name: 'WeeChat',
          host: host,
          port: port,
          password: password,
          enabled: true
        }
        config[:buffer_filter] = buffer_filter unless buffer_filter.empty?
        config
      else
        @panes[:bottom].clear
        @panes[:bottom].text = " Connection failed: #{result[:message]}".fg(196)
        @panes[:bottom].refresh
        sleep(2)

        choice = @panes[:bottom].ask("Retry? (Enter = retry, ESC = cancel): ", "")
        return nil if choice.nil?
        configure_weechat  # Retry
      end
    end

    # Shared Meta cookie setup for Messenger/Instagram
    def configure_meta_source(title, source_type, domain, required_cookies, optional_cookies, help_lines)
      @panes[:right].clear
      @panes[:right].text = ([
        "#{title} SETUP".b.fg(226),
        "",
      ] + help_lines).join("\n")
      @panes[:right].refresh

      # Try auto-extraction from Firefox
      @panes[:bottom].clear
      @panes[:bottom].text = " Checking Firefox for #{domain} cookies...".fg(226)
      @panes[:bottom].refresh

      require_relative '../sources/messenger'
      cookies = if source_type == 'messenger'
                  Heathrow::Sources::Messenger.extract_firefox_cookies
                else
                  Heathrow::Sources::Messenger.extract_instagram_cookies_from_firefox
                end

      loop do
        if cookies && required_cookies.all? { |k| cookies[k] && !cookies[k].empty? }
          @panes[:bottom].clear
          @panes[:bottom].text = " Found #{domain} cookies in Firefox!".fg(156)
          @panes[:bottom].refresh
          sleep(1)
          save_meta_cookies(source_type, cookies)
          return { name: title.split(' ').first.capitalize, cookies: cookies, enabled: true }
        end

        # Not found — ask user to log in and retry
        @panes[:right].clear
        @panes[:right].text = ([
          "#{title} SETUP".b.fg(226),
          "",
        ] + help_lines + [
          "",
          "NEXT STEP:".b.fg(39),
          "  1. Open #{domain} in Firefox and log in",
          "  2. Come back here and press Enter to retry",
          "",
          "Heathrow will automatically read your",
          "Firefox cookies — no copying needed.",
        ]).join("\n")
        @panes[:right].refresh

        choice = @panes[:bottom].ask("Press Enter after logging in (ESC to cancel): ", "")
        return nil if choice.nil?

        @panes[:bottom].clear
        @panes[:bottom].text = " Checking Firefox for #{domain} cookies...".fg(226)
        @panes[:bottom].refresh

        cookies = if source_type == 'messenger'
                    Heathrow::Sources::Messenger.extract_firefox_cookies
                  else
                    Heathrow::Sources::Messenger.extract_instagram_cookies_from_firefox
                  end
      end
    end

    def save_meta_cookies(source_type, cookies)
      cookie_dir = File.join(Dir.home, '.heathrow', 'cookies')
      Dir.mkdir(cookie_dir) unless Dir.exist?(cookie_dir)
      file = File.join(cookie_dir, "#{source_type}.json")
      File.write(file, cookies.to_json)
      File.chmod(0600, file)
    end

    # Generic source configuration via field definitions
    def configure_source(source_type, source_info)
      config = {}

      form_text = []
      form_text << "CONFIGURE #{source_info[:name].upcase}".b.fg(226)
      form_text << ""
      form_text << source_info[:description]
      form_text << ""

      source_info[:fields].each do |field|
        form_text << "#{field[:label]}:".b.fg(39)
        form_text << "  #{field[:help]}".fg(240) if field[:help]

        @panes[:right].clear
        @panes[:right].text = form_text.join("\n")
        @panes[:right].refresh

        value = get_field_value(field)
        return nil if value.nil?

        # Store value
        unless value.empty?
          case field[:type]
          when 'number'
            config[field[:key].to_sym] = value.to_i
          when 'boolean'
            config[field[:key].to_sym] = %w[y yes true 1].include?(value.downcase)
          else
            config[field[:key].to_sym] = value
          end
        end

        # Use default if empty
        if config[field[:key].to_sym].nil? && field[:default]
          config[field[:key].to_sym] = field[:default]
        end

        display_val = field[:type] == 'password' ? '****' : (value.empty? ? "(default: #{field[:default]})" : value)
        form_text << "  → #{display_val}".fg(156)
        form_text << ""
      end

      # Validate required fields
      missing = source_info[:fields].select { |f| f[:required] && config[f[:key].to_sym].nil? }
      unless missing.empty?
        @panes[:bottom].clear
        @panes[:bottom].text = " Missing required: #{missing.map { |f| f[:label] }.join(', ')}".fg(196)
        @panes[:bottom].refresh
        sleep(2)
        return nil
      end

      config
    end

    private

    def create_source(source_type, config)
      db = @source_manager.db

      # Check if source of this type already exists (for web/rss, merge pages/feeds)
      existing = db.get_sources.find { |s| s['plugin_type'] == source_type }

      if existing && (source_type == 'web' || source_type == 'rss')
        # Merge into existing source
        old_config = existing['config']
        old_config = JSON.parse(old_config) if old_config.is_a?(String)

        case source_type
        when 'web'
          old_pages = old_config['pages'] || []
          new_pages = config[:pages] || config['pages'] || []
          new_pages.each do |p|
            old_pages << p unless old_pages.any? { |op| op['url'] == p['url'] }
          end
          old_config['pages'] = old_pages
        when 'rss'
          old_feeds = old_config['feeds'] || []
          new_feeds = config[:feeds] || config['feeds'] || []
          new_feeds.each do |f|
            url = f.is_a?(Hash) ? f['url'] : f
            old_feeds << f unless old_feeds.any? { |of| (of.is_a?(Hash) ? of['url'] : of) == url }
          end
          old_config['feeds'] = old_feeds
        end

        db.execute("UPDATE sources SET config = ? WHERE id = ?", [old_config.to_json, existing['id']])
        # Take initial snapshot / sync
        initial_sync(source_type, old_config, db, existing['id'])
        return existing['id']
      end

      # Create new source
      now = Time.now.to_i
      config_hash = config.is_a?(Hash) ? config : {}
      config_json = config_hash.transform_keys(&:to_s).to_json

      name = config_hash[:name] || config_hash['name'] || source_type.capitalize
      db.execute(
        "INSERT INTO sources (plugin_type, name, config, enabled, capabilities, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [source_type, name, config_json, 1, '["read"]', now, now]
      )

      source_id = db.get_sources.find { |s| s['plugin_type'] == source_type }['id']
      initial_sync(source_type, config_hash.transform_keys(&:to_s), db, source_id)
      source_id
    end

    def initial_sync(source_type, config, db, source_id)
      @panes[:bottom].clear
      @panes[:bottom].text = " Syncing #{source_type}...".fg(226)
      @panes[:bottom].refresh

      case source_type
      when 'web'
        require_relative '../sources/webpage'
        instance = Heathrow::Sources::Webpage.new('Web Watch', config, db)
        count = instance.sync(source_id)
        @panes[:bottom].text = " #{count} changes detected (first run stores baselines)".fg(156)
      when 'rss'
        require_relative '../sources/rss'
        instance = Heathrow::Sources::RSS.new('RSS Feeds', config, db)
        count = instance.sync(source_id)
        @panes[:bottom].text = " Imported #{count} articles".fg(156)
      when 'weechat'
        require_relative '../sources/weechat'
        instance = Heathrow::Sources::Weechat.new('WeeChat', config, db)
        count = instance.sync(source_id)
        @panes[:bottom].text = " Imported #{count} messages from WeeChat".fg(156)
      end
      @panes[:bottom].refresh
      sleep(1)
    rescue => e
      @panes[:bottom].text = " Sync error: #{e.message}".fg(196)
      @panes[:bottom].refresh
      sleep(2)
    end

    def get_field_value(field)
      prompt = field[:label]
      prompt += " (#{field[:placeholder]})" if field[:placeholder]
      prompt += field[:required] ? " *: " : " (optional): "

      case field[:type]
      when 'boolean'
        default = field[:default] ? "y" : "n"
        @panes[:bottom].ask("#{field[:label]} (y/n): ", default)
      when 'password'
        @panes[:bottom].ask(prompt, "")
      else
        @panes[:bottom].ask(prompt, field[:default]&.to_s || "")
      end
    end
  end
end
