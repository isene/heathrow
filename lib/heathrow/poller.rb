# Background polling service for fetching messages
require 'thread'

module Heathrow
  class Poller
    attr_reader :running
    
    def initialize(db, plugin_manager)
      @db = db
      @plugin_manager = plugin_manager
      @running = false
      @thread = nil
      @mutex = Mutex.new
    end
    
    def start
      return if @running
      
      @running = true
      @thread = Thread.new do
        run_polling_loop
      end
    end
    
    def stop
      @running = false
      @thread&.join(5) # Wait up to 5 seconds for thread to finish
    end
    
    private
    
    def run_polling_loop
      while @running
        begin
          poll_sources
          sleep 10 # Check every 10 seconds
        rescue StandardError => e
          log_error("Polling error: #{e.message}")
        end
      end
    end
    
    def poll_sources
      sources = @db.get_sources(true) # Only enabled sources
      
      sources.each do |source_data|
        source = Source.new(
          id: source_data['id'],
          type: source_data['type'],
          name: source_data['name'],
          config: source_data['config'],
          enabled: source_data['enabled'] == 1,
          poll_interval: source_data['poll_interval'],
          last_poll: source_data['last_poll']
        )
        
        next unless source.should_poll?
        
        poll_source(source)
      end
    end
    
    def poll_source(source)
      plugin = @plugin_manager.create_source(source.type, source)
      return unless plugin
      
      begin
        messages = plugin.fetch_messages
        
        @mutex.synchronize do
          messages.each do |msg_data|
            message = Message.new(msg_data)
            message.source_id = source.id
            message.source_type = source.type
            
            @db.insert_message(message.to_h.values)
          end
          
          @db.update_source_poll_time(source.id)
        end
      rescue StandardError => e
        log_error("Error polling #{source.name}: #{e.message}")
      end
    end
    
    def log_error(message)
      log_file = File.join(HEATHROW_LOGS, 'poller.log')
      File.open(log_file, 'a') do |f|
        f.puts "[#{Time.now}] #{message}"
      end
    end
  end
end