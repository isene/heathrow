# Source model for communication sources
module Heathrow
  class Source
    attr_accessor :id, :type, :name, :config, :enabled, :poll_interval, :last_poll
    
    def initialize(attrs = {})
      @id = attrs[:id] || generate_id
      @type = attrs[:type]
      @name = attrs[:name]
      @config = attrs[:config] || {}
      @enabled = attrs[:enabled] != false
      @poll_interval = attrs[:poll_interval] || 60
      @last_poll = attrs[:last_poll]
    end
    
    def generate_id
      "#{@type}_#{Time.now.to_i}_#{rand(1000)}"
    end
    
    def to_h
      {
        id: @id,
        type: @type,
        name: @name,
        config: @config.to_json,
        enabled: @enabled ? 1 : 0,
        poll_interval: @poll_interval,
        last_poll: @last_poll
      }
    end
    
    def should_poll?
      return false unless @enabled
      return true if @last_poll.nil?
      
      Time.now - Time.parse(@last_poll) >= @poll_interval
    end
  end
end