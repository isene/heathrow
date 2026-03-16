require 'json'

module Heathrow
  module Plugin
    # Base class for all Heathrow plugins
    #
    # All communication source plugins (Gmail, Slack, Discord, etc.) should inherit from this class.
    #
    # Required Methods:
    #   - fetch_messages: Fetch new messages from the source
    #
    # Optional Methods:
    #   - send_message: Send a message (if two-way communication supported)
    #   - delete_message: Delete a message
    #   - mark_read: Mark message as read on the source
    #   - can_reply?: Does this source support replying?
    #   - can_delete?: Does this source support deleting messages?
    #   - setup_wizard: Configuration wizard steps
    #   - validate_config: Validate source configuration
    #   - capabilities: List of capabilities this plugin supports
    #
    class Base
      attr_reader :source, :config, :logger, :event_bus

      def initialize(source, logger: nil, event_bus: nil)
        @source = source
        @config = parse_config(source['config'])
        @logger = logger
        @event_bus = event_bus
        @capabilities = default_capabilities
      end

      # Fetch new messages from the source
      # Must return an array of message hashes:
      #   [{
      #     external_id: "msg_123",
      #     sender: "user@example.com",
      #     sender_name: "John Doe",
      #     recipients: ["me@example.com"],
      #     subject: "Hello",
      #     content: "Message content",
      #     timestamp: 1234567890,
      #     ...
      #   }]
      def fetch_messages
        raise NotImplementedError, "#{self.class} must implement fetch_messages"
      end

      # Send a message through this source
      # Returns [success, result_or_error]
      def send_message(recipients, subject: nil, content:, **options)
        raise NotImplementedError, "#{self.class} does not support sending messages"
      end

      # Delete a message (if supported)
      def delete_message(external_id)
        raise NotImplementedError, "#{self.class} does not support deleting messages"
      end

      # Mark message as read on the source (if supported)
      def mark_read(external_id)
        raise NotImplementedError, "#{self.class} does not support marking messages as read"
      end

      # Capabilities
      def can_reply?
        @capabilities.include?('write')
      end

      def can_delete?
        @capabilities.include?('delete')
      end

      def can_mark_read?
        @capabilities.include?('mark_read')
      end

      def supports_real_time?
        @capabilities.include?('real_time')
      end

      def supports_attachments?
        @capabilities.include?('attachments')
      end

      def supports_threads?
        @capabilities.include?('threads')
      end

      # Get all capabilities
      def capabilities
        @capabilities
      end

      # Setup wizard for configuration
      # Returns array of wizard steps:
      #   [{
      #     key: 'api_key',
      #     prompt: 'Enter your API key:',
      #     type: 'text',
      #     required: true
      #   }]
      def setup_wizard
        []
      end

      # Validate configuration
      # Returns [valid, error_message]
      def validate_config
        [true, nil]
      end

      # Health check
      # Returns [healthy, status_message]
      def health_check
        begin
          # Default: try to fetch messages as health check
          fetch_messages
          [true, "OK"]
        rescue => e
          [false, e.message]
        end
      end

      # Get source metadata
      def metadata
        {
          type: self.class.name.split('::').last.downcase,
          capabilities: @capabilities,
          config_keys: @config.keys
        }
      end

      protected

      # Parse configuration (handles both JSON string and Hash)
      def parse_config(config)
        return {} if config.nil?
        return config if config.is_a?(Hash)

        begin
          JSON.parse(config)
        rescue JSON::ParserError
          {}
        end
      end

      # Default capabilities for a read-only source
      def default_capabilities
        ['read']
      end

      # Log helper methods
      def log_info(message, context = {})
        @logger&.info(message, context.merge(plugin: self.class.name))
      end

      def log_error(message, error = nil, context = {})
        ctx = context.merge(plugin: self.class.name)
        ctx[:error] = error if error
        @logger&.error(message, ctx)
      end

      def log_debug(message, context = {})
        @logger&.debug(message, context.merge(plugin: self.class.name))
      end

      # Publish event helper
      def publish_event(event_name, data = {})
        @event_bus&.publish(event_name, data.merge(plugin: self.class.name))
      end

      # Helper: Convert timestamp to Unix timestamp
      def to_unix_timestamp(time)
        case time
        when Integer
          time
        when Time
          time.to_i
        when String
          Time.parse(time).to_i
        else
          Time.now.to_i
        end
      end

      # Helper: Normalize message data to Heathrow format
      def normalize_message(data)
        {
          external_id: data[:external_id] || data[:id],
          sender: data[:sender] || data[:from],
          sender_name: data[:sender_name] || data[:from_name],
          recipients: Array(data[:recipients] || data[:to]),
          cc: Array(data[:cc]),
          bcc: Array(data[:bcc]),
          subject: data[:subject],
          content: data[:content] || data[:body] || data[:text],
          html_content: data[:html_content] || data[:html],
          timestamp: to_unix_timestamp(data[:timestamp] || data[:created_at] || Time.now),
          read: data[:read],
          starred: data[:starred],
          replied: data[:replied],
          thread_id: data[:thread_id],
          parent_id: data[:parent_id],
          labels: Array(data[:labels] || data[:tags]),
          attachments: Array(data[:attachments]),
          metadata: data[:metadata] || {}
        }
      end
    end
  end
end
