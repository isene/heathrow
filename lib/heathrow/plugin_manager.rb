# Plugin manager for communication source plugins with error boundaries
module Heathrow
  class PluginManager
    attr_reader :plugins, :plugin_errors, :logger, :event_bus

    def initialize(logger: nil, event_bus: nil)
      @plugins = {}
      @plugin_errors = {}
      @plugin_dir = HEATHROW_PLUGINS
      @logger = logger
      @event_bus = event_bus
      ensure_plugin_directory
      load_plugins
    end

    def ensure_plugin_directory
      require 'fileutils'
      FileUtils.mkdir_p(@plugin_dir) unless Dir.exist?(@plugin_dir)
    end

    def load_plugins
      # Load built-in plugins
      load_builtin_plugins

      # Load user plugins from ~/.heathrow/plugins/
      Dir.glob(File.join(@plugin_dir, '*.rb')).each do |plugin_file|
        load_plugin(plugin_file)
      end

      @logger&.info("PluginManager: Loaded #{@plugins.size} plugin(s)")
      @event_bus&.publish('plugins.loaded', plugin_types: @plugins.keys)
    end

    def load_builtin_plugins
      # Built-in source plugins will auto-register when required
      # This is handled by the create_source method
    end

    def load_plugin(plugin_file)
      begin
        require plugin_file
        # Plugin should register itself via PluginManager.register
        @logger&.info("PluginManager: Loaded plugin from #{plugin_file}")
      rescue StandardError => e
        error_msg = "Failed to load plugin #{plugin_file}: #{e.message}"
        @logger&.error(error_msg, error: e)
        @plugin_errors[plugin_file] = e
      end
    end

    def register(type, plugin_class)
      @plugins[type] = plugin_class
      @logger&.debug("PluginManager: Registered plugin type '#{type}'")
      @event_bus&.publish('plugin.registered', type: type, class: plugin_class.name)
    end

    def get_plugin(type)
      @plugins[type]
    end

    def available_types
      @plugins.keys
    end

    def plugin_registered?(type)
      @plugins.key?(type)
    end
    
    def create_source(type, source)
      # Try to load the source module dynamically with error boundary
      begin
        # Handle 'web' as 'webpage' for the module
        module_name = type == 'web' ? 'webpage' : type
        require_relative "sources/#{module_name}"

        # Get the class
        class_name = module_name.capitalize
        source_class = Heathrow::Sources.const_get(class_name)

        # Create instance with error boundary
        instance = source_class.new(source)

        @logger&.info("PluginManager: Created source instance for type '#{type}'", source_id: source['id'])
        @event_bus&.publish('source.created', type: type, source_id: source['id'])

        instance
      rescue LoadError => e
        error_msg = "Source module not found: #{module_name}"
        @logger&.error(error_msg, error: e, type: type)
        @event_bus&.publish('source.create_failed', type: type, error: e.message)
        nil
      rescue StandardError => e
        error_msg = "Error creating source"
        @logger&.error(error_msg, error: e, type: type)
        @event_bus&.publish('source.create_failed', type: type, error: e.message)
        nil
      end
    end

    # Execute plugin method with error boundary
    # Returns [success, result_or_error]
    def safe_execute(plugin_instance, method_name, *args)
      begin
        result = plugin_instance.send(method_name, *args)
        @logger&.debug("PluginManager: Executed #{method_name} successfully")
        [true, result]
      rescue => e
        @logger&.error("PluginManager: Error in #{method_name}", error: e)
        @event_bus&.publish('plugin.error', method: method_name, error: e.message)
        [false, e]
      end
    end

    # Get plugin health status
    def plugin_health
      {
        total_plugins: @plugins.size,
        plugin_types: @plugins.keys,
        errors: @plugin_errors.transform_values { |e| e.message }
      }
    end

    # Reload a specific plugin
    def reload_plugin(type)
      @plugins.delete(type)
      load_plugins
      @logger&.info("PluginManager: Reloaded plugin type '#{type}'")
    end

    # Unregister a plugin
    def unregister(type)
      if @plugins.delete(type)
        @logger&.info("PluginManager: Unregistered plugin type '#{type}'")
        @event_bus&.publish('plugin.unregistered', type: type)
        true
      else
        false
      end
    end
  end
end