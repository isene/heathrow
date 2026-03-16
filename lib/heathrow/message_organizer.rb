#!/usr/bin/env ruby
# frozen_string_literal: true

module Heathrow
  # Organizes messages into threads, groups, and channels
  class MessageOrganizer
    attr_reader :messages, :threads, :groups, :channels

    def initialize(messages = [], db = nil, group_by_folder: false)
      @messages = messages
      @db = db
      @group_by_folder = group_by_folder
      @threads = {}
      @groups = {}
      @channels = {}
      @dms = []
      # Pre-populate source type cache in one query instead of per-message lookups
      @source_types_cache = db ? db.get_source_type_map : {}
      organize_messages
    end

    # Get plugin type for a message (from source_type or by looking up source)
    def get_plugin_type(msg)
      return msg['source_type'] if msg['source_type']
      @source_types_cache[msg['source_id']] || 'unknown'
    end

    # Detect if message is an email based on metadata
    def is_email_message?(msg)
      metadata = parse_metadata(msg['metadata'])
      metadata && metadata['message_id']  # Emails have Message-ID header
    end

    # Organize messages into logical structures
    def organize_messages
      original_count = @messages.size
      filtered_count = 0

      # Sort messages by timestamp ascending so root messages are processed before replies
      sorted_messages = @messages.sort_by { |m| m['timestamp'] || 0 }

      if ENV['DEBUG']
        File.write('/tmp/heathrow_debug.log', "ORGANIZER: Sorted #{sorted_messages.size} messages by timestamp\n", mode: 'a')
        File.write('/tmp/heathrow_debug.log', "ORGANIZER: First 10 IDs in order: #{sorted_messages.first(10).map { |m| m['id'] }.join(', ')}\n", mode: 'a')
      end

      sorted_messages.each do |msg|
        # Skip synthetic header messages from previous organization
        if msg['is_header'] || msg['is_channel_header'] || msg['is_thread_header'] || msg['is_dm_header']
          File.write('/tmp/heathrow_debug.log', "ORGANIZER: Skipping header message: #{msg['id']}\n", mode: 'a') if ENV['DEBUG']
          next
        end
        filtered_count += 1

        # If grouping by folder, use folder organization for all messages
        if @group_by_folder
          organize_by_folder(msg)
          next
        end

        # Get plugin type for this message
        plugin_type = get_plugin_type(msg)

        # Also check if it looks like an email based on metadata
        if plugin_type == 'unknown' && is_email_message?(msg)
          plugin_type = 'email'
        end

        # Stamp source_type on message so formatting code can use it
        msg['source_type'] = plugin_type

        case plugin_type
        when 'discord'
          organize_discord_message(msg)
        when 'slack'
          organize_slack_message(msg)
        when 'reddit'
          organize_reddit_message(msg)
        when 'telegram'
          organize_telegram_message(msg)
        when 'gmail', 'imap', 'email', 'maildir'
          organize_email_thread(msg)
        when 'rss'
          organize_rss_message(msg)
        when 'web'
          organize_webwatch_message(msg)
        when 'messenger'
          organize_messenger_message(msg)
        when 'instagram'
          organize_instagram_message(msg)
        when 'weechat'
          organize_weechat_message(msg)
        when 'workspace'
          organize_workspace_message(msg)
        else
          # Other/unknown sources - treat as simple messages in a channel
          organize_other_message(msg)
        end
      end
      
      # Build thread relationships
      build_thread_hierarchy
      
      File.write('/tmp/heathrow_debug.log', "ORGANIZER: Processed #{filtered_count}/#{original_count} messages (#{original_count - filtered_count} headers skipped)\n", mode: 'a') if ENV['DEBUG']
    end
    
    # Get organized view of messages
    def get_organized_view(sort_order = nil, sort_inverted = false)
      organized = []
      
      # Add channels/groups with their messages
      @channels.each do |channel_id, channel_data|
        organized << {
          type: 'channel',
          name: channel_data[:name],
          source: channel_data[:source],
          messages: channel_data[:messages],
          collapsed: channel_data[:collapsed] || false,
          unread_count: count_unread(channel_data[:messages]),
          display_name: channel_data[:display_name]  # Pass display_name for Discord channels
        }
      end
      
      # Add DMs separately first (they go at the top or bottom)
      dm_section = nil
      unless @dms.empty?
        dm_section = {
          type: 'dm_section',
          name: 'Direct Messages',
          messages: @dms,
          collapsed: false,
          unread_count: count_unread(@dms)
        }
      end
      
      # Add threaded messages (emails, forums) to the main list
      @threads.each do |thread_id, thread_data|
        next if thread_data[:in_channel] # Skip if already in a channel
        
        organized << {
          type: 'thread',
          subject: thread_data[:subject],
          messages: thread_data[:messages],
          collapsed: thread_data[:collapsed] || false,
          unread_count: count_unread(thread_data[:messages])
        }
      end
      
      # Sort based on sort_order
      case sort_order
      when 'alphabetical'
        organized.sort! do |a, b|
          clean_a = section_display_name(a).gsub(/^[#\[\]@\s]+/, '')
          clean_b = section_display_name(b).gsub(/^[#\[\]@\s]+/, '')
          clean_a == clean_b ? section_display_name(a) <=> section_display_name(b) : clean_a <=> clean_b
        end
      when 'unread'
        organized.sort! do |a, b|
          cmp = b[:unread_count].to_i <=> a[:unread_count].to_i
          cmp != 0 ? cmp : section_display_name(a) <=> section_display_name(b)
        end
      when 'latest'
        organized.sort! do |a, b|
          newest_a = (a[:messages] || []).map { |m| m['timestamp'].to_i }.max || 0
          newest_b = (b[:messages] || []).map { |m| m['timestamp'].to_i }.max || 0
          newest_b <=> newest_a
        end
      when 'source'
        organized.sort! do |a, b|
          sa = a[:source] || (a[:type] == 'thread' ? 'email' : 'unknown')
          sb = b[:source] || (b[:type] == 'thread' ? 'email' : 'unknown')
          cmp = sa.to_s <=> sb.to_s
          cmp != 0 ? cmp : section_display_name(a) <=> section_display_name(b)
        end
      end
      
      # Add DM section(s) at the end (or beginning if inverted)
      if dm_section
        if sort_order == 'conversation'
          # Split DMs into per-conversation sections
          convos = {}
          dm_section[:messages].each do |msg|
            metadata = parse_metadata(msg['metadata'])
            key = metadata['thread_id'] || msg['sender'] || 'Unknown'
            convos[key] ||= { name: msg['sender'] || msg['subject'] || 'Unknown', messages: [] }
            convos[key][:messages] << msg
          end
          conv_sections = convos.map do |_key, data|
            {
              type: 'dm_section',
              name: data[:name],
              messages: data[:messages],
              collapsed: false,
              unread_count: count_unread(data[:messages])
            }
          end
          # Sort conversation sections alphabetically by name
          conv_sections.sort_by! { |s| s[:name].to_s.downcase }
          if sort_inverted
            organized.unshift(*conv_sections.reverse)
          else
            organized.push(*conv_sections)
          end
        else
          if sort_inverted
            organized.unshift(dm_section)  # Add at beginning
          else
            organized.push(dm_section)     # Add at end
          end
        end
      end
      
      # Sort messages within each section to match sort order
      if sort_order == 'latest' || sort_order == 'conversation'
        organized.each do |section|
          next unless section[:messages]
          section[:messages].sort_by! { |m| -(m['timestamp'].to_i) }
        end
      end

      # Apply invert if requested - reverse everything
      if sort_inverted
        organized.reverse!
        organized.each do |section|
          next unless section[:messages]
          section[:messages].reverse!
        end
      end

      organized
    end
    
    private

    # Get display name for a section (used in sorting)
    def section_display_name(section)
      (section[:name] || section[:subject] || '').to_s.downcase
    end

    # Organize Discord messages by channel and DMs
    def organize_discord_message(msg)
      # Parse metadata to check if it's actually a DM
      metadata = parse_metadata(msg['metadata'])
      is_dm = metadata['is_dm'] == true
      
      # Check if it's a DM based on recipient format or metadata
      if is_dm || msg['recipient'] == 'DM'
        # Direct message
        msg['is_dm'] = true
        @dms << msg
      elsif msg['recipient'] =~ /^(.+)#(.+)$/
        # Server channel message (format: ServerName#channelName)
        guild_name = $1
        channel_name = $2
        channel_id = metadata['channel_id'] || msg['recipient']
        
        # Create a unique key for this server/channel combination
        channel_key = "discord_#{channel_id}"
        
        @channels[channel_key] ||= {
          name: "#{guild_name} > #{channel_name}",
          source: 'discord',
          messages: [],
          guild: guild_name,
          channel: channel_name,
          display_name: "#{guild_name}##{channel_name}"
        }
        
        @channels[channel_key][:messages] << msg
      else
        # For Discord messages with just channel ID as recipient (old format)
        channel_id = msg['recipient']
        
        # Group by channel ID
        channel_key = "discord_#{channel_id}"
        
        # Map channel IDs to display names (from heathrowrc config)
        names = Config.instance&.channel_name_map || {}

        # Try to get a readable name
        channel_display = names[channel_id]
        if channel_display.nil? && channel_id =~ /^\d+$/
          # Unknown channel, show last 4 digits
          channel_display = "Discord-#{channel_id[-4..-1]}"
        elsif channel_display.nil?
          channel_display = channel_id
        end
        
        @channels[channel_key] ||= {
          name: channel_display,
          source: 'discord',
          messages: [],
          display_name: channel_display
        }
        
        @channels[channel_key][:messages] << msg
      end
    end
    
    # Organize Slack messages by channel and threads
    def organize_slack_message(msg)
      # Extract channel info from message
      channel_id = msg['channel_id'] || extract_channel_from_recipient(msg['recipient'])
      
      if channel_id =~ /^D/ # Direct message channel
        msg['is_dm'] = true
        @dms << msg
      elsif channel_id =~ /^C/ || channel_id =~ /^G/ # Channel or private group
        channel_name = msg['channel_name'] || msg['recipient']
        
        @channels[channel_id] ||= {
          name: channel_name,
          source: 'slack',
          messages: [],
          type: channel_id.start_with?('C') ? 'public' : 'private'
        }
        
        @channels[channel_id][:messages] << msg
      end
      
      # Handle threading - only for actual threaded messages
      if msg['thread_ts']
        add_to_thread(msg, thread_id: msg['thread_ts'])
      end
      # Don't create threads for regular channel messages
    end
    
    # Organize Reddit messages by subreddit and thread
    def organize_reddit_message(msg)
      # Check if it's a private message
      if msg['external_id'] =~ /reddit_msg_/
        msg['is_dm'] = true
        @dms << msg
      else
        # Subreddit post or comment
        subreddit = extract_subreddit(msg['recipient'])
        
        if subreddit
          @groups[subreddit] ||= {
            name: subreddit,
            source: 'reddit',
            messages: [],
            type: 'subreddit'
          }
          
          @groups[subreddit][:messages] << msg
        end
        
        # Handle comment threads
        if msg['external_id'] =~ /reddit_comment_/
          # This is a comment, find parent post
          parent_id = extract_reddit_parent(msg)
          add_to_thread(msg, thread_id: parent_id)
        else
          # This is a post, start a thread
          add_to_thread(msg)
        end
      end
    end
    
    # Organize Telegram messages
    def organize_telegram_message(msg)
      # Check if it's a DM or group
      if msg['recipient'] =~ /^@/ || msg['chat_type'] == 'private'
        msg['is_dm'] = true
        @dms << msg
      else
        # Group/channel message
        group_name = msg['recipient']
        group_id = msg['chat_id'] || group_name
        
        @groups[group_id] ||= {
          name: group_name,
          source: 'telegram',
          messages: [],
          type: msg['chat_type'] || 'group'
        }
        
        @groups[group_id][:messages] << msg
      end
      
      # Handle replies
      if msg['reply_to_message_id']
        add_to_thread(msg, thread_id: msg['reply_to_message_id'])
      else
        add_to_thread(msg)
      end
    end

    # Organize messages by folder (from labels)
    def organize_by_folder(msg)
      # Get folder from labels (first label is folder name)
      labels = parse_labels(msg['labels'])
      folder_name = labels.first || 'Uncategorized'

      folder_key = "folder_#{folder_name.downcase.gsub(/[^a-z0-9]/, '_')}"

      @channels[folder_key] ||= {
        name: folder_name,
        source: 'folder',
        messages: [],
        display_name: folder_name
      }

      @channels[folder_key][:messages] << msg
    end

    # Parse labels (handle both JSON string and array)
    def parse_labels(labels)
      return [] unless labels
      return labels if labels.is_a?(Array)
      JSON.parse(labels) rescue []
    end

    # Organize other/unknown source types
    def organize_other_message(msg)
      # Group by source type
      source_type = msg['source_type'] || 'other'
      channel_key = "other_#{source_type}"
      
      @channels[channel_key] ||= {
        name: source_type.capitalize,
        source: source_type,
        messages: [],
        display_name: source_type.capitalize
      }
      
      @channels[channel_key][:messages] << msg
    end
    
    # Organize RSS messages as flat feed
    def organize_rss_message(msg)
      # Group by feed title from metadata (not sender, which may be per-article author)
      metadata = parse_metadata(msg['metadata'])
      feed_name = metadata['feed_title'] || msg['sender'] || 'RSS Feed'

      feed_key = "rss_#{feed_name.downcase.gsub(/[^a-z0-9]/, '_')}"
      
      @channels[feed_key] ||= {
        name: feed_name,
        source: 'rss',
        messages: [],
        display_name: feed_name
      }
      
      # Also ensure each message has a proper sender
      msg['sender'] = feed_name if msg['sender'].nil? || msg['sender'].empty?
      
      @channels[feed_key][:messages] << msg
    end

    # Organize web watch messages by page
    def organize_webwatch_message(msg)
      metadata = parse_metadata(msg['metadata'])
      page_name = metadata['page_title'] || msg['sender'] || 'Web Watch'
      page_key = "web_#{page_name.downcase.gsub(/[^a-z0-9]/, '_')}"

      @channels[page_key] ||= {
        name: page_name,
        source: 'web',
        messages: [],
        display_name: page_name
      }

      @channels[page_key][:messages] << msg
    end

    # Organize Messenger messages as DMs/conversations
    def organize_messenger_message(msg)
      metadata = parse_metadata(msg['metadata'])
      thread_id = metadata['thread_id'] || msg['sender']
      name = msg['subject'] || msg['sender'] || 'Messenger'

      # Treat as DMs
      msg['is_dm'] = true
      @dms << msg
    end

    # Organize WeeChat relay messages by buffer (IRC channels, Slack channels, DMs)
    def organize_weechat_message(msg)
      metadata = parse_metadata(msg['metadata'])
      buffer_type = metadata['buffer_type'] || ''
      buffer = metadata['buffer'] || 'WeeChat'
      is_dm = metadata['is_dm'] == true
      platform = (metadata['platform'] || 'irc').upcase
      channel_name = metadata['channel_name'] || metadata['buffer_short'] || buffer.split('.').last

      if is_dm
        msg['is_dm'] = true
        @dms << msg
      else
        channel_key = "weechat_#{buffer.downcase.gsub(/[^a-z0-9.]/, '_')}"

        @channels[channel_key] ||= {
          name: channel_name,
          source: 'weechat',
          messages: [],
          display_name: "#{platform}: #{channel_name}"
        }

        @channels[channel_key][:messages] << msg
      end
    end

    # Organize Workspace messages by channel or as DMs
    def organize_workspace_message(msg)
      metadata = parse_metadata(msg['metadata'])
      conv_type = metadata['conv_type'] || 'channel'
      conv_name = metadata['channel_name'] || msg['subject'] || 'Workspace'

      if conv_type == 'private' || metadata['is_dm']
        msg['is_dm'] = true
        @dms << msg
      else
        channel_key = "workspace_#{conv_name.downcase.gsub(/[^a-z0-9]/, '_')}"
        @channels[channel_key] ||= {
          name: conv_name,
          source: 'workspace',
          messages: [],
          display_name: "WS: #{conv_name}"
        }
        @channels[channel_key][:messages] << msg
      end
    end

    # Organize Instagram messages as DMs/conversations
    def organize_instagram_message(msg)
      metadata = parse_metadata(msg['metadata'])
      thread_id = metadata['thread_id'] || msg['sender']
      name = msg['subject'] || msg['sender'] || 'Instagram'

      msg['is_dm'] = true
      @dms << msg
    end

    # Organize email messages into threads
    def organize_email_thread(msg)
      # Use Message-ID and In-Reply-To headers for threading
      metadata = parse_metadata(msg['metadata']) || {}
      message_id = metadata['message_id']
      in_reply_to = metadata['in_reply_to']
      references = metadata['references']

      File.write('/tmp/heathrow_debug.log', "ORGANIZER: Email msg #{msg['id']} - subject: '#{msg['subject']}', in_reply_to: #{in_reply_to.inspect}\n", mode: 'a') if ENV['DEBUG']

      # Find or create thread
      thread_id = find_email_thread(message_id, in_reply_to, references)

      File.write('/tmp/heathrow_debug.log', "ORGANIZER:   -> thread_id: #{thread_id.inspect} (#{thread_id ? 'found' : 'will create new'})\n", mode: 'a') if ENV['DEBUG']

      add_to_thread(msg, thread_id: thread_id, subject: msg['subject'])
    end
    
    # Add message to a thread
    def add_to_thread(msg, thread_id: nil, subject: nil, channel_id: nil)
      thread_id ||= generate_thread_id(msg)
      
      @threads[thread_id] ||= {
        messages: [],
        subject: subject || msg['subject'],
        first_message_id: msg['id'],
        in_channel: !channel_id.nil?
      }
      
      @threads[thread_id][:messages] << msg
      msg['thread_id'] = thread_id
    end
    
    # Build parent-child relationships in threads
    def build_thread_hierarchy
      @threads.each do |thread_id, thread_data|
        messages = thread_data[:messages]
        
        # Skip threading for channel messages (they're already in channels)
        next if thread_data[:in_channel]
        
        # Sort messages by timestamp
        messages.sort_by! { |m| m['timestamp'] || '' }
        
        # Build hierarchy based on reply relationships
        messages.each do |msg|
          # Find parent based on various criteria
          parent = find_parent_message(msg, messages)
          if parent
            msg['parent_id'] = parent['id']
            msg['thread_level'] = (parent['thread_level'] || 0) + 1
          else
            msg['thread_level'] = 0
          end
        end
      end
    end
    
    # Find parent message for threading
    def find_parent_message(msg, messages)
      return nil if messages.size <= 1

      # Get plugin type for this message
      plugin_type = get_plugin_type(msg)

      # Skip threading for Discord/Slack channel messages
      return nil if plugin_type =~ /discord|slack|telegram/ && !msg['is_dm']

      # For email sources, use In-Reply-To from metadata
      if plugin_type =~ /mail|imap|gmail|email/
        metadata = parse_metadata(msg['metadata'])
        if metadata && metadata['in_reply_to']
          # Find message with matching Message-ID
          parent = messages.find { |m|
            m_meta = parse_metadata(m['metadata'])
            m_meta && m_meta['message_id'] == metadata['in_reply_to']
          }
          return parent if parent

          # Also try References header (list of parent messages)
          if metadata['references'] && metadata['references'].is_a?(Array)
            # Try each reference from most recent to oldest
            metadata['references'].reverse.each do |ref_id|
              parent = messages.find { |m|
                m_meta = parse_metadata(m['metadata'])
                m_meta && m_meta['message_id'] == ref_id
              }
              return parent if parent
            end
          end
        end
      end

      # For chat platforms, use reply_to fields only for DMs
      if msg['reply_to_message_id'] && msg['is_dm']
        return messages.find { |m| m['external_id'] == msg['reply_to_message_id'] }
      end

      nil
    end
    
    # Extract channel ID from Discord message
    def extract_channel_id(msg)
      # Try to extract from external_id or raw_data
      if msg['external_id'] =~ /discord_(\d+)_/
        return $1
      end
      
      # Parse raw_data if available
      if msg['raw_data']
        data = JSON.parse(msg['raw_data']) rescue {}
        return data['channel_id'] if data['channel_id']
      end
      
      # Generate from recipient
      "discord_#{msg['recipient'].gsub(/[^a-z0-9]/i, '_')}"
    end
    
    # Extract subreddit from recipient
    def extract_subreddit(recipient)
      if recipient =~ /^r\/(\w+)/
        return "r/#{$1}"
      end
      nil
    end
    
    # Extract parent ID for Reddit comments
    def extract_reddit_parent(msg)
      # Parse from subject line (Re: post_title)
      if msg['subject'] =~ /^Re: (.+)/
        parent_subject = $1[0..50]
        # Find post with matching subject
        parent = @messages.find { |m| 
          m['external_id'] =~ /reddit_post_/ && 
          m['subject'] && m['subject'].start_with?(parent_subject)
        }
        return parent['external_id'] if parent
      end
      
      # Default to post ID from external_id pattern
      "reddit_post_unknown"
    end
    
    # Parse metadata JSON
    def parse_metadata(metadata_str)
      return {} unless metadata_str
      return metadata_str if metadata_str.is_a?(Hash)  # Already parsed
      JSON.parse(metadata_str) rescue {}
    end
    
    # Find email thread based on headers
    def find_email_thread(message_id, in_reply_to, references)
      File.write('/tmp/heathrow_debug.log', "  find_email_thread: in_reply_to=#{in_reply_to.inspect}, references=#{references.inspect}, @threads.size=#{@threads.size}\n", mode: 'a') if ENV['DEBUG']

      # Check if this message is already part of a thread
      if in_reply_to
        # Find thread containing the message we're replying to
        @threads.each do |thread_id, thread_data|
          if thread_data[:messages].any? { |m|
            meta = parse_metadata(m['metadata'])
            msg_id = meta['message_id']
            matches = (msg_id == in_reply_to)
            if ENV['DEBUG']
              File.write('/tmp/heathrow_debug.log', "    Checking in_reply_to: msg #{m['id']} message_id=#{msg_id.inspect} == #{in_reply_to.inspect}? #{matches}\n", mode: 'a')
            end
            matches
          }
            File.write('/tmp/heathrow_debug.log', "  Found thread via in_reply_to: #{thread_id}\n", mode: 'a') if ENV['DEBUG']
            return thread_id
          end
        end
      end

      # Check references header
      if references && !references.empty?
        # References can be an array or a string
        ref_list = references.is_a?(Array) ? references : references.split(/\s+/)
        File.write('/tmp/heathrow_debug.log', "  Checking references: #{ref_list.inspect}\n", mode: 'a') if ENV['DEBUG']
        # Find thread containing any referenced message
        @threads.each do |thread_id, thread_data|
          thread_data[:messages].each do |m|
            meta = parse_metadata(m['metadata'])
            if ref_list.include?(meta['message_id'])
              File.write('/tmp/heathrow_debug.log', "  Found thread via references: #{thread_id} (matched #{meta['message_id']})\n", mode: 'a') if ENV['DEBUG']
              return thread_id
            end
          end
        end
      end

      File.write('/tmp/heathrow_debug.log', "  No thread found, will create new\n", mode: 'a') if ENV['DEBUG']
      # Return nil to let generate_thread_id create a proper unique ID
      nil
    end
    
    # Generate a thread ID for a message
    def generate_thread_id(msg)
      # Use external_id for unique threading
      if msg['external_id'] =~ /(post|msg|message)_(\w+)/
        return "thread_#{$2}"
      end
      
      # For emails, be more strict about threading
      # Each email should be its own thread unless it has In-Reply-To header
      if msg['source_type'] =~ /gmail|imap|email/
        # Use message ID to create unique thread
        metadata = parse_metadata(msg['metadata'])
        if metadata['message_id']
          return "thread_email_#{metadata['message_id'].gsub(/[^a-z0-9]+/, '_')}"
        end
      end
      
      # Use subject for other messages
      if msg['subject'] && !msg['subject'].empty?
        subject_base = msg['subject'].gsub(/^(Re:|Fwd:|Fw:)\s*/i, '').strip
        # Include sender to make threads more unique
        sender_part = (msg['sender'] || '').downcase.gsub(/[^a-z0-9]+/, '_')[0..10]
        return "thread_#{sender_part}_#{subject_base.downcase.gsub(/[^a-z0-9]+/, '_')}"
      end
      
      # Default to message ID
      "thread_#{msg['id'] || Time.now.to_i}"
    end
    
    # Extract channel from Slack recipient
    def extract_channel_from_recipient(recipient)
      # Slack recipients often include channel name
      if recipient =~ /#(\w+)/
        return "C#{recipient.gsub(/[^a-z0-9]/i, '')}"
      end
      recipient
    end
    
    # Count unread messages
    def count_unread(messages)
      messages.count { |m| m['is_read'].to_i == 0 }
    end
  end
end