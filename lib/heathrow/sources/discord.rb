#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'fileutils'
require 'time'

module Heathrow
  module Sources
    class Discord
      API_BASE = 'https://discord.com/api/v10'
      
      def initialize(source)
        @source = source
      end
      
      def name
        'Discord'
      end
      
      def description
        'Fetch messages from Discord servers and DMs'
      end
      
      def fetch_messages
        token = @source.config['token']
        is_bot = @source.config['is_bot'] || false
        channels = @source.config['channels'] || []
        guilds = @source.config['guilds'] || []
        fetch_limit = @source.config['fetch_limit'] || 50
        
        messages = []
        
        # Get state file to track last message IDs per channel
        heathrow_home = File.expand_path('~/.heathrow')
        state_file = File.join(heathrow_home, 'state', "discord_#{@source.id}.json")
        FileUtils.mkdir_p(File.dirname(state_file))
        
        last_messages = if File.exist?(state_file)
          JSON.parse(File.read(state_file))
        else
          {}
        end
        
        begin
          # If specific channels are provided, fetch from those
          if channels && !channels.empty?
            channels_list = channels.is_a?(String) ? channels.split(',').map(&:strip) : channels
            channels_list.each do |channel_id|
              # Get channel info to determine if it's a guild channel or DM
              channel_info = fetch_channel_info(token, channel_id, is_bot)
              
              if channel_info
                guild_id = channel_info['guild_id']
                channel_name = channel_info['name'] || channel_id
                
                # If it's a guild channel, get guild info
                if guild_id
                  guild_info = fetch_guild_info(token, guild_id, is_bot)
                  guild_name = guild_info ? guild_info['name'] : "Server"
                  channel_messages = fetch_channel_messages(token, channel_id, last_messages[channel_id], fetch_limit, is_bot, guild_name, channel_name, guild_id)
                else
                  # It's a DM channel
                  channel_messages = fetch_channel_messages(token, channel_id, last_messages[channel_id], fetch_limit, is_bot)
                end
              else
                # Fallback if we can't get channel info
                channel_messages = fetch_channel_messages(token, channel_id, last_messages[channel_id], fetch_limit, is_bot)
              end
              
              messages.concat(channel_messages)
              
              # Update last message ID for this channel
              if channel_messages.any?
                last_messages[channel_id] = channel_messages.first[:external_id].split('_').last
              end
            end
          end
          
          # If guilds are provided, fetch all channels from those guilds
          if guilds && !guilds.empty?
            guilds_list = guilds.is_a?(String) ? guilds.split(',').map(&:strip) : guilds
            guilds_list.each do |guild_id|
              # Get guild info for proper naming
              guild_info = fetch_guild_info(token, guild_id, is_bot)
              guild_name = guild_info ? guild_info['name'] : "Guild #{guild_id}"
              
              guild_channels = fetch_guild_channels(token, guild_id, is_bot)
              guild_channels.each do |channel|
                next unless channel['type'] == 0  # Only text channels
                
                channel_id = channel['id']
                channel_messages = fetch_channel_messages(token, channel_id, last_messages[channel_id], fetch_limit, is_bot, guild_name, channel['name'], guild_id)
                messages.concat(channel_messages)
                
                # Update last message ID for this channel
                if channel_messages.any?
                  last_messages[channel_id] = channel_messages.first[:external_id].split('_').last
                end
              end
            end
          end
          
          # If neither channels nor guilds specified, try to get DMs
          if channels.empty? && guilds.empty?
            dm_channels = fetch_dm_channels(token, is_bot)
            dm_channels.each do |channel|
              channel_id = channel['id']
              channel_messages = fetch_channel_messages(token, channel_id, last_messages[channel_id], fetch_limit, is_bot)
              messages.concat(channel_messages)
              
              # Update last message ID for this channel
              if channel_messages.any?
                last_messages[channel_id] = channel_messages.first[:external_id].split('_').last
              end
            end
          end
          
          # Save state
          File.write(state_file, JSON.generate(last_messages))
          
        rescue => e
          return [{
            source_id: @source.id,
            source_type: 'discord',
            sender: 'Discord',
            subject: 'Error',
            content: "Failed to fetch messages: #{e.message}",
            timestamp: Time.now.to_s,
            is_read: 0
          }]
        end
        
        messages
      end
      
      def test_connection
        config = @source.config.is_a?(String) ? JSON.parse(@source.config) : @source.config
        token = config['token']
        is_bot = config['is_bot'] != false
        
        begin
          # Try to get user info
          uri = URI("#{API_BASE}/users/@me")
          request = Net::HTTP::Get.new(uri)
          request['Authorization'] = is_bot ? "Bot #{token}" : token
          
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
          
          if response.is_a?(Net::HTTPSuccess)
            user_data = JSON.parse(response.body)
            username = user_data['username']
            discriminator = user_data['discriminator']
            { success: true, message: "Connected as #{username}##{discriminator}" }
          else
            { success: false, message: "Failed to connect: #{response.code} #{response.message}" }
          end
        rescue => e
          { success: false, message: "Connection test failed: #{e.message}" }
        end
      end
      
      def can_reply?
        true
      end
      
      def send_message(to, subject, body, in_reply_to = nil)
        config = @source.config.is_a?(String) ? JSON.parse(@source.config) : @source.config
        token = config['token']
        is_bot = config['is_bot'] != false
        
        # Debug log
        File.open('/tmp/heathrow_debug.log', 'a') do |f|
          f.puts "\n=== DISCORD SEND MESSAGE #{Time.now} ==="
          f.puts "To: #{to.inspect}"
          f.puts "Subject: #{subject.inspect}"
          f.puts "Body length: #{body.length}"
          f.puts "In reply to: #{in_reply_to.inspect}"
        end
        
        # Parse the recipient - could be channel ID or username
        channel_id = if to =~ /^\d+$/
          to  # Already a channel ID
        else
          # Try to extract channel ID from a formatted string like "#general (123456789)"
          if to =~ /\((\d+)\)/
            $1
          else
            return { success: false, message: "Discord: Need channel ID, got '#{to}'. Check the To: field in editor." }
          end
        end
        
        # Build the message
        message_data = {
          content: body
        }
        
        # If replying, add reference
        if in_reply_to
          message_data[:message_reference] = {
            message_id: in_reply_to
          }
        end
        
        # Send the message
        uri = URI("#{API_BASE}/channels/#{channel_id}/messages")
        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = is_bot ? "Bot #{token}" : token
        request['Content-Type'] = 'application/json'
        request.body = message_data.to_json
        
        begin
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
          
          if response.is_a?(Net::HTTPSuccess)
            { success: true, message: "Message sent to Discord" }
          else
            error_data = JSON.parse(response.body) rescue {}
            { success: false, message: "Failed to send: #{error_data['message'] || response.message}" }
          end
        rescue => e
          { success: false, message: "Send failed: #{e.message}" }
        end
      end
      
      private
      
      def fetch_channel_messages(token, channel_id, last_message_id, limit, is_bot, guild_name = nil, channel_name = nil, guild_id = nil)
        messages = []
        
        uri = URI("#{API_BASE}/channels/#{channel_id}/messages")
        params = { limit: [limit, 100].min }
        params[:after] = last_message_id if last_message_id
        uri.query = URI.encode_www_form(params)
        
        response = make_request(uri, token, is_bot)
        return messages unless response.is_a?(Net::HTTPSuccess)
        
        channel_data = JSON.parse(response.body)
        channel_data.reverse.each do |msg|  # Reverse to get oldest first
          # Skip system messages
          next if msg['type'] != 0 && msg['type'] != 19  # 0 = normal, 19 = reply
          
          author = msg['author']
          sender = author['username']
          sender += " (BOT)" if author['bot']
          
          # Format channel display name
          display_channel = channel_name || msg['channel_name'] || channel_id
          
          # Determine if this is a DM based on whether we have guild info
          is_dm = guild_name.nil? || guild_name.empty?
          
          # Format content
          content = msg['content']
          
          # Add attachment info
          if msg['attachments'] && !msg['attachments'].empty?
            attachments = msg['attachments'].map { |a| a['filename'] }.join(', ')
            content += "\n[Attachments: #{attachments}]"
          end
          
          # Add embed info
          if msg['embeds'] && !msg['embeds'].empty?
            content += "\n[Contains #{msg['embeds'].length} embed(s)]"
          end
          
          # Format recipient based on whether it's a guild channel or DM
          recipient_display = if guild_name && !is_dm
            "#{guild_name} ##{display_channel}"  # Server #channel format with space
          elsif is_dm
            "DM"  # Mark as direct message
          else
            display_channel
          end
          
          # Add guild_id to the raw message data if we have it
          msg_with_guild = msg.dup
          msg_with_guild['guild_id'] = guild_id if guild_id
          
          message = {
            source_id: @source.id,
            source_type: 'discord',
            external_id: "discord_#{channel_id}_#{msg['id']}",
            sender: sender,
            recipient: recipient_display,
            subject: recipient_display,
            content: content,
            raw_data: msg_with_guild.to_json,
            attachments: msg['attachments'] ? msg['attachments'].to_json : nil,
            timestamp: Time.parse(msg['timestamp']),
            is_read: 0,
            metadata: {
              guild_name: guild_name,
              channel_name: display_channel,
              channel_id: channel_id,
              is_dm: is_dm
            }.to_json
          }
          
          messages << message
        end
        
        messages
      end
      
      def fetch_channel_info(token, channel_id, is_bot)
        uri = URI("#{API_BASE}/channels/#{channel_id}")
        response = make_request(uri, token, is_bot)
        return nil unless response.is_a?(Net::HTTPSuccess)
        
        JSON.parse(response.body)
      end
      
      def fetch_guild_info(token, guild_id, is_bot)
        uri = URI("#{API_BASE}/guilds/#{guild_id}")
        response = make_request(uri, token, is_bot)
        return nil unless response.is_a?(Net::HTTPSuccess)
        
        JSON.parse(response.body)
      end
      
      def fetch_guild_channels(token, guild_id, is_bot)
        uri = URI("#{API_BASE}/guilds/#{guild_id}/channels")
        response = make_request(uri, token, is_bot)
        return [] unless response.is_a?(Net::HTTPSuccess)
        
        JSON.parse(response.body)
      end
      
      def fetch_dm_channels(token, is_bot)
        uri = URI("#{API_BASE}/users/@me/channels")
        response = make_request(uri, token, is_bot)
        return [] unless response.is_a?(Net::HTTPSuccess)
        
        JSON.parse(response.body)
      end
      
      def make_request(uri, token, is_bot)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        request = Net::HTTP::Get.new(uri)
        auth_header = is_bot ? "Bot #{token}" : token
        request['Authorization'] = auth_header
        request['User-Agent'] = 'Heathrow/1.0'
        
        http.request(request)
      end
    end
  end
end