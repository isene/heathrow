require 'thread'

module Heathrow
  # EventBus - Simple pub/sub system for inter-component communication
  #
  # Usage:
  #   bus = EventBus.instance
  #
  #   # Subscribe to events
  #   bus.subscribe('message.new') { |data| puts "New message: #{data}" }
  #
  #   # Publish events
  #   bus.publish('message.new', message_data)
  #
  #   # Unsubscribe
  #   handler_id = bus.subscribe('message.new') { |data| ... }
  #   bus.unsubscribe('message.new', handler_id)
  #
  class EventBus
    attr_reader :subscribers, :event_log

    def initialize(logger = nil)
      @subscribers = Hash.new { |h, k| h[k] = {} }
      @event_log = []
      @mutex = Mutex.new
      @logger = logger
      @next_id = 0
    end

    # Subscribe to an event
    # Returns handler ID for later unsubscribing
    def subscribe(event_name, &block)
      @mutex.synchronize do
        handler_id = generate_handler_id
        @subscribers[event_name][handler_id] = block
        @logger&.debug("EventBus: Subscribed to '#{event_name}' (handler #{handler_id})")
        handler_id
      end
    end

    # Unsubscribe from an event
    def unsubscribe(event_name, handler_id)
      @mutex.synchronize do
        if @subscribers[event_name].delete(handler_id)
          @logger&.debug("EventBus: Unsubscribed from '#{event_name}' (handler #{handler_id})")
          true
        else
          false
        end
      end
    end

    # Unsubscribe all handlers for an event
    def unsubscribe_all(event_name)
      @mutex.synchronize do
        count = @subscribers[event_name].size
        @subscribers.delete(event_name)
        @logger&.debug("EventBus: Unsubscribed all #{count} handlers from '#{event_name}'")
        count
      end
    end

    # Publish an event
    def publish(event_name, data = nil)
      handlers = nil

      @mutex.synchronize do
        handlers = @subscribers[event_name].values.dup
        log_event(event_name, data)
      end

      @logger&.debug("EventBus: Publishing '#{event_name}' to #{handlers.size} handler(s)")

      # Execute handlers outside the mutex to avoid deadlocks
      handlers.each do |handler|
        begin
          handler.call(data)
        rescue => e
          @logger&.error("EventBus: Error in handler for '#{event_name}': #{e.message}")
          @logger&.error(e.backtrace.join("\n")) if @logger
        end
      end

      handlers.size
    end

    # Publish event asynchronously (returns immediately)
    def publish_async(event_name, data = nil)
      Thread.new do
        begin
          publish(event_name, data)
        rescue => e
          @logger&.error("EventBus: Error in async publish of '#{event_name}': #{e.message}")
        end
      end
    end

    # Get all subscribers for an event
    def subscribers_for(event_name)
      @mutex.synchronize do
        @subscribers[event_name].keys
      end
    end

    # Get all event names that have subscribers
    def event_names
      @mutex.synchronize do
        @subscribers.keys.reject { |k| @subscribers[k].empty? }
      end
    end

    # Get count of subscribers for an event
    def subscriber_count(event_name)
      @mutex.synchronize do
        @subscribers[event_name].size
      end
    end

    # Clear all subscribers (useful for testing)
    def clear
      @mutex.synchronize do
        @subscribers.clear
        @logger&.debug("EventBus: Cleared all subscribers")
      end
    end

    # Get event log (last N events)
    def recent_events(count = 10)
      @mutex.synchronize do
        @event_log.last(count)
      end
    end

    # Enable/disable event logging
    def log_events=(enabled)
      @log_events = enabled
    end

    def log_events?
      @log_events != false  # Default to true
    end

    private

    def generate_handler_id
      @next_id += 1
      "handler_#{@next_id}"
    end

    def log_event(event_name, data)
      return unless log_events?

      @event_log << {
        name: event_name,
        data: data,
        timestamp: Time.now.to_i,
        subscriber_count: @subscribers[event_name].size
      }

      # Keep only last 100 events
      @event_log.shift if @event_log.size > 100
    end

    # Singleton pattern (optional, can also instantiate directly)
    class << self
      def instance
        @instance ||= new
      end

      def reset_instance!
        @instance = nil
      end
    end
  end
end
