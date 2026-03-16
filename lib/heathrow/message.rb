# Message model - matches DATABASE_SCHEMA.md spec
require 'json'

module Heathrow
  class Message
    attr_accessor :id, :source_id, :external_id, :thread_id, :parent_id,
                  :sender, :sender_name,
                  :recipients, :cc, :bcc,
                  :subject, :content, :html_content,
                  :timestamp, :received_at,
                  :read, :starred, :archived,
                  :labels, :attachments, :metadata

    # Backward compatibility aliases
    alias :is_read :read
    alias :is_read= :read=
    alias :is_starred :starred
    alias :is_starred= :starred=

    def initialize(attrs = {})
      # Set defaults
      @timestamp = Time.now.to_i
      @received_at = Time.now.to_i
      @read = false
      @starred = false
      @archived = false
      @recipients = []
      @cc = []
      @bcc = []
      @labels = []
      @attachments = []
      @metadata = {}

      # Set attributes from hash
      attrs.each do |key, value|
        # Handle both string and symbol keys
        key = key.to_s if key.is_a?(Symbol)

        # Parse JSON strings for array/hash fields
        if ['recipients', 'cc', 'bcc', 'labels', 'attachments', 'metadata'].include?(key)
          value = parse_json_field(value)
        end

        # Handle backward compatibility
        key = 'read' if key == 'is_read'
        key = 'starred' if key == 'is_starred'

        send("#{key}=", value) if respond_to?("#{key}=")
      end
    end
    
    def to_h
      {
        id: @id,
        source_id: @source_id,
        external_id: @external_id,
        thread_id: @thread_id,
        parent_id: @parent_id,
        sender: @sender,
        sender_name: @sender_name,
        recipients: @recipients,
        cc: @cc,
        bcc: @bcc,
        subject: @subject,
        content: @content,
        html_content: @html_content,
        timestamp: @timestamp,
        received_at: @received_at,
        read: @read,
        starred: @starred,
        archived: @archived,
        labels: @labels,
        attachments: @attachments,
        metadata: @metadata
      }
    end

    # Message state methods
    def mark_as_read!
      @read = true
    end

    def mark_as_unread!
      @read = false
    end

    def toggle_star!
      @starred = !@starred
    end

    def archive!
      @archived = true
    end

    def unarchive!
      @archived = false
    end

    def add_label(label)
      @labels << label unless @labels.include?(label)
    end

    def remove_label(label)
      @labels.delete(label)
    end

    def has_label?(label)
      @labels.include?(label)
    end

    # Query methods
    def read?
      @read
    end

    def unread?
      !@read
    end

    def starred?
      @starred
    end

    def archived?
      @archived
    end

    def has_attachments?
      @attachments && !@attachments.empty?
    end

    def has_thread?
      !@thread_id.nil?
    end

    def is_reply?
      !@parent_id.nil?
    end

    # Display helpers
    def short_subject(length = 50)
      return '' unless @subject
      @subject.length > length ? "#{@subject[0...length]}..." : @subject
    end

    def short_content(length = 100)
      return '' unless @content
      @content.length > length ? "#{@content[0...length]}..." : @content
    end

    def display_sender
      @sender_name || @sender || 'Unknown'
    end

    def timestamp_formatted(format = '%Y-%m-%d %H:%M:%S')
      Time.at(@timestamp).strftime(format)
    end

    def age_in_days
      ((Time.now.to_i - @timestamp) / 86400.0).round(1)
    end

    private

    def parse_json_field(value)
      return value if value.nil?
      return value unless value.is_a?(String)

      begin
        JSON.parse(value)
      rescue JSON::ParserError
        value
      end
    end
  end
end
