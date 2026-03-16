require 'yaml'
require 'fileutils'

module Heathrow
  class Config
    attr_accessor :settings

    HEATHROWRC = File.expand_path('~/.heathrow/heathrowrc')

    def self.instance
      @@instance rescue nil
    end

    def initialize(config_path = HEATHROW_CONFIG, db = nil)
      @@instance = self
      @config_path = config_path
      @db = db
      @settings = load_config
      ensure_heathrow_directory

      # DSL state — populated by loading heathrowrc
      @identities = {}
      @folder_hooks = []
      @global_headers = {}
      @rc_settings = {}

      load_rc

      # Register as singleton so class methods work
      self.class.instance = self
    end

    def ensure_heathrow_directory
      dir = File.dirname(@config_path)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    end

    # ── RC file DSL methods (called from heathrowrc) ──

    def set(key, value)
      key_s = key.to_s
      if key_s.include?('.')
        # Dot-notation path: save to YAML settings (e.g. 'ui.color_theme')
        keys = key_s.split('.')
        last_key = keys.pop
        parent = @settings
        keys.each { |k| parent[k] ||= {}; parent = parent[k] }
        parent[last_key] = value
      else
        # Simple key: RC setting (e.g. :color_theme)
        @rc_settings[key_s] = value
      end
    end

    def identity(name, from:, signature: nil, smtp: nil, headers: nil)
      @identities[name.to_s] = {
        from: from,
        signature: signature ? File.expand_path(signature) : nil,
        smtp: smtp ? File.expand_path(smtp) : nil,
        headers: headers || {}
      }
    end

    def folder_hook(pattern, identity_name)
      @folder_hooks << { pattern: pattern, identity: identity_name.to_s }
    end

    def header(name, value)
      @global_headers[name.to_s] = value.to_s
    end

    # Define a custom color theme (or override a built-in)
    # Usage in heathrowrc:
    #   theme 'MyTheme', unread: 226, read: 249, accent: 10, thread: 255,
    #                     dm: 201, tag: 14, quote1: 114, quote2: 180,
    #                     quote3: 139, quote4: 109, sig: 242
    def theme(name, **colors)
      @custom_themes ||= {}
      @custom_themes[name.to_s] = colors
    end

    def custom_themes
      @custom_themes || {}
    end

    # Define a custom view (replaces hardcoded views in database.rb)
    # Usage: view '1', 'Personal', folder: 'Personal'
    #        view '4', 'Work', folder: 'Work.Archive'
    #        view '5', 'RSS', source_type: 'rss'
    def view(key, name, **opts)
      @custom_views ||= []
      filters = if opts[:folder]
        { 'rules' => [{ 'field' => 'folder', 'op' => 'like', 'value' => opts[:folder] }] }
      elsif opts[:source_type]
        { 'rules' => [{ 'field' => 'source_type', 'op' => '=', 'value' => opts[:source_type] }] }
      elsif opts[:filters]
        opts[:filters]
      else
        { 'rules' => [] }
      end
      @custom_views << { key: key.to_s, name: name, filters: filters,
                         sort_order: opts[:sort_order] }
    end

    def custom_views
      @custom_views || []
    end

    # Map Discord channel IDs to display names
    # Usage: channel_names '123456789' => 'MyServer#general',
    #                      '987654321' => 'MyServer#dev'
    def channel_names(mapping)
      @channel_name_map ||= {}
      @channel_name_map.merge!(mapping.transform_keys(&:to_s))
    end

    def channel_name_map
      @channel_name_map || {}
    end

    # Bind a key to a custom action
    # Usage:
    #   bind 'C-S', shell: 'mailq'              # Run shell command, show output
    #   bind 'C-N', shell: 'notmuch search %q'  # %q = prompted query
    #   bind 'C-O', action: :open_in_browser     # Call a Heathrow method
    #   bind '\\',  shell: 'my-script %f'        # %f = current message file path
    def bind(key, shell: nil, action: nil, prompt: nil, description: nil)
      @custom_bindings ||= {}
      @custom_bindings[key.to_s] = {
        shell: shell,
        action: action,
        prompt: prompt,
        description: description
      }
    end

    def custom_bindings
      @custom_bindings || {}
    end

    # ── Load the RC file ──

    def load_rc(path = HEATHROWRC)
      return unless File.exist?(path)

      # Evaluate in the context of this Config instance so DSL methods work
      instance_eval(File.read(path), path)
    rescue => e
      STDERR.puts "Error loading #{path}: #{e.message}"
      STDERR.puts e.backtrace.first(3).join("\n") if ENV['DEBUG']
    end

    # Reload the RC file (for interactive 'R' key)
    def reload_rc
      @identities = {}
      @folder_hooks = []
      @global_headers = {}
      @rc_settings = {}
      @custom_themes = nil
      @custom_views = nil
      @custom_bindings = nil
      @channel_name_map = nil
      load_rc
    end

    # ── Identity resolution ──

    def identities
      @identities
    end

    def folder_hooks
      @folder_hooks
    end

    def global_headers
      @global_headers
    end

    # Get identity for a given folder name (first matching folder_hook wins)
    def identity_for_folder(folder_name)
      folder_name ||= 'INBOX'
      hook = @folder_hooks.find { |h| folder_name.match?(h[:pattern]) }
      identity_name = hook ? hook[:identity] : 'default'
      id = @identities[identity_name] || @identities['default']
      return nil unless id

      # Merge global headers into identity headers
      merged_headers = @global_headers.merge(id[:headers] || {})
      id.merge(headers: merged_headers)
    end

    def identity_name_for_folder(folder_name)
      folder_name ||= 'INBOX'
      hook = @folder_hooks.find { |h| folder_name.match?(h[:pattern]) }
      hook ? hook[:identity] : 'default'
    end

    # Class-level shortcuts that delegate to the singleton
    class << self
      attr_accessor :instance

      def identity_for_folder(folder_name)
        instance&.identity_for_folder(folder_name)
      end

      def identity_name_for_folder(folder_name)
        instance&.identity_name_for_folder(folder_name)
      end
    end

    # ── RC settings access ──
    # RC settings override YAML config values

    def rc(key, default = nil)
      val = @rc_settings[key.to_s]
      val.nil? ? default : val
    end

    # ── YAML config (legacy, still used for some things) ──

    def load_config
      if File.exist?(@config_path)
        YAML.load_file(@config_path)
      else
        create_default_config
      end
    end

    def create_default_config
      default = {
        'version' => Heathrow::VERSION,
        'ui' => {},
        'polling' => {
          'enabled' => true,
          'default_interval' => 60
        },
        'notifications' => {
          'enabled' => false,
          'sound' => false
        }
      }

      save_config(default)
      default
    end

    def save_config(config = @settings)
      File.write(@config_path, config.to_yaml)
    end

    def save
      save_config
    end

    # Get config value — YAML overrides (from interactive settings) beat RC defaults
    def get(path, default = nil)
      # First check YAML (interactive changes persist here)
      keys = path.split('.')
      yaml_val = @settings
      keys.each do |key|
        break unless yaml_val.is_a?(Hash)
        yaml_val = yaml_val[key]
      end
      return yaml_val unless yaml_val.nil?

      # Then check RC settings
      rc_key = path.sub(/^ui\./, '')
      val = @rc_settings[rc_key]
      return val unless val.nil?

      default
    end

    def has?(path)
      keys = path.split('.')
      value = @settings

      keys.each do |key|
        return false unless value.is_a?(Hash) && value.key?(key)
        value = value[key]
      end

      true
    end

    def [](key)
      @settings[key]
    end

    def []=(key, value)
      @settings[key] = value
    end

    # ── Database-backed settings ──

    def set_db_setting(key, value)
      return unless @db

      now = Time.now.to_i
      value_str = value.is_a?(String) ? value : value.to_json

      @db.execute <<-SQL, [key, value_str, now]
        INSERT OR REPLACE INTO settings (key, value, updated_at)
        VALUES (?, ?, ?)
      SQL
    end

    def get_db_setting(key, default = nil)
      return default unless @db

      result = @db.get_first_value("SELECT value FROM settings WHERE key = ?", key)
      return default unless result

      begin
        JSON.parse(result)
      rescue JSON::ParserError
        result
      end
    end

    def has_db_setting?(key)
      return false unless @db
      @db.get_first_value("SELECT COUNT(*) FROM settings WHERE key = ?", key).to_i > 0
    end

    def delete_db_setting(key)
      return unless @db
      @db.execute("DELETE FROM settings WHERE key = ?", key)
    end
  end
end
