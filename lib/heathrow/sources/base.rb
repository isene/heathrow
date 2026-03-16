module Heathrow
  module Sources
    class Base
      attr_reader :name, :type, :config, :db
      
      def initialize(name, config, db)
        @name = name
        @config = config
        @db = db
        @type = self.class.name.split('::').last.downcase
      end
      
      def fetch
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end
      
      def poll_interval
        @config['poll_interval'] || 300
      end
      
      def enabled?
        @config['enabled'] != false
      end
      
      def last_fetch
        @config['last_fetch']
      end
      
      def update_last_fetch(time = Time.now)
        @config['last_fetch'] = time.to_i
        save_config
      end
      
      def save_config
        source = @db.get_source_by_name(@name)
        if source
          sid = source['id'] || source[:id]
          @db.update_source(sid, config: @config.to_json) if sid
        end
      end
      
      protected
      
      def store_message(external_id, title, content, timestamp = Time.now, metadata = {})
        source = @db.get_source_by_name(@name)
        return unless source
        
        # Check if message already exists
        existing = @db.get_messages(
          source_id: source['id']
        ).find { |m| m['external_id'] == external_id }
        
        return if existing
        
        # Store new message - insert_message expects an array in specific order
        message_data = [
          source['id'],       # source_id
          source['type'],     # source_type
          external_id,        # external_id
          metadata[:author],  # sender
          nil,               # recipient
          title,             # subject
          content,           # content
          metadata.to_json,  # raw_data
          nil,               # attachments
          timestamp,         # timestamp
          0                  # is_read
        ]
        
        @db.insert_message(message_data)
      end
    end
  end
end