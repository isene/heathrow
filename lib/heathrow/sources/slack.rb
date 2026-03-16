#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'time'

module Heathrow
  module Sources
    # Slack source implementation
    class Slack
      def initialize(source)
        @source = source
        @base_url = 'https://slack.com/api'
        
        # Cache for user and channel names
        @users_cache = {}
        @channels_cache = {}
        @last_fetch = {}
      end
      
      def name
        'slack'
      end
      
      def test_connection
        uri = URI("#{@base_url}/auth.test")
        response = make_api_request(uri)
        
        if response && response['ok']
          puts "Successfully connected to Slack workspace: #{response['team']}"
          true
        else
          error = response ? response['error'] : 'Unknown error'
          puts "Failed to connect: #{error}"
          false
        end
      rescue => e
        puts "Connection error: #{e.message}"
        false
      end
      
      def fetch_messages
        messages = []
        
        channel_ids = @source.config['channel_ids'] || []
        dm_user_ids = @source.config['dm_user_ids'] || []
        
        # Fetch channel messages
        channel_ids.each do |channel_id|
          channel_messages = fetch_channel_messages(channel_id)
          messages.concat(channel_messages)
        end
        
        # Fetch direct messages
        dm_user_ids.each do |user_id|
          dm_messages = fetch_direct_messages(user_id)
          messages.concat(dm_messages)
        end
        
        # Fetch all channels if no specific ones configured
        if channel_ids.empty? && dm_user_ids.empty?
          all_channels = fetch_all_conversations
          all_channels.each do |channel|
            # Debug logging
            File.write('/tmp/slack_channels.log', "Channel: #{channel['name']} (#{channel['id']}), is_member: #{channel['is_member']}\n", mode: 'a') if ENV['DEBUG']
            
            # Only fetch from channels we're a member of
            next unless channel['is_member']
            
            if channel['is_im']
              # Direct message
              dm_messages = fetch_direct_messages(channel['user'] || channel['id'])
              messages.concat(dm_messages)
            else
              # Any other type of channel (public, private, group)
              channel_messages = fetch_channel_messages(channel['id'])
              messages.concat(channel_messages)
            end
          end
        end
        
        messages
      end
      
      def send_message(recipient, content, metadata = {})
        channel = resolve_channel(recipient)
        
        uri = URI("#{@base_url}/chat.postMessage")
        params = {
          channel: channel,
          text: content,
          as_user: true
        }
        
        # Handle thread replies
        if metadata[:thread_ts]
          params[:thread_ts] = metadata[:thread_ts]
        end
        
        response = make_api_request(uri, params)
        
        if response && response['ok']
          { success: true, message_id: response['ts'] }
        else
          error = response ? response['error'] : 'Unknown error'
          { success: false, error: error }
        end
      rescue => e
        { success: false, error: e.message }
      end
      
      def mark_as_read(message_id, channel_id = nil)
        return { success: false, error: 'Channel ID required for Slack' } unless channel_id
        
        # Determine the correct API endpoint based on channel type
        channel_type = detect_channel_type(channel_id)
        endpoint = case channel_type
                   when 'channel' then 'channels.mark'
                   when 'group' then 'groups.mark'
                   when 'im' then 'im.mark'
                   when 'mpim' then 'mpim.mark'
                   else 'conversations.mark'
                   end
        
        uri = URI("#{@base_url}/#{endpoint}")
        params = {
          channel: channel_id,
          ts: message_id
        }
        
        response = make_api_request(uri, params)
        
        if response && response['ok']
          { success: true }
        else
          error = response ? response['error'] : 'Unknown error'
          { success: false, error: error }
        end
      rescue => e
        { success: false, error: e.message }
      end
      
      private
      
      def make_api_request(uri, params = {}, method = :post)
        api_token = @source.config['api_token'] || @source.config['token']
        
        if method == :get
          uri.query = URI.encode_www_form(params) unless params.empty?
          request = Net::HTTP::Get.new(uri)
        else
          request = Net::HTTP::Post.new(uri)
          request['Content-Type'] = 'application/json'
          request.body = params.to_json unless params.empty?
        end
        
        request['Authorization'] = "Bearer #{api_token}"
        
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 10  # 10 second timeout
        http.open_timeout = 5   # 5 second connection timeout
        
        response = http.request(request)
        JSON.parse(response.body) rescue nil
      end
      
      def fetch_channel_messages(channel_id)
        channel_name = get_channel_name(channel_id)
        
        uri = URI("#{@base_url}/conversations.history")
        params = {
          channel: channel_id,
          limit: 50
        }
        
        # Get messages since last fetch if available
        if @last_fetch[channel_id]
          params[:oldest] = @last_fetch[channel_id].to_f.to_s
        end
        
        response = make_api_request(uri, params, :get)
        
        messages = []
        if response && response['ok']
          response['messages'].each do |msg|
            next if msg['type'] != 'message' || msg['subtype'] == 'bot_message'
            
            user_name = get_user_name(msg['user'])
            
            messages << {
              'source_id' => @source.id,
              'source_type' => 'slack',
              'external_id' => "slack_#{@source.id}_#{channel_id}_#{msg['ts']}",
              'sender' => user_name,
              'recipient' => "##{channel_name}",
              'subject' => nil,
              'content' => msg['text'],
              'timestamp' => Time.at(msg['ts'].to_f).iso8601,
              'is_read' => 0,
              'metadata' => {
                'channel_id' => channel_id,
                'channel_name' => channel_name,
                'thread_ts' => msg['thread_ts'],
                'ts' => msg['ts'],
                'workspace' => @source.config['workspace']
              }.to_json,
              'raw_data' => msg.to_json,
              'attachments' => nil
            }
          end
          
          @last_fetch[channel_id] = Time.now
        end
        
        messages
      rescue => e
        puts "Error fetching channel messages: #{e.message}"
        []
      end
      
      def fetch_direct_messages(user_id)
        # First, open the DM channel
        uri = URI("#{@base_url}/conversations.open")
        params = { users: user_id }
        response = make_api_request(uri, params)
        
        return [] unless response && response['ok']
        
        channel_id = response['channel']['id']
        user_name = get_user_name(user_id)
        
        # Now fetch the messages
        uri = URI("#{@base_url}/conversations.history")
        params = {
          channel: channel_id,
          limit: 100
        }
        
        if @last_fetch[channel_id]
          params[:oldest] = @last_fetch[channel_id].to_f.to_s
        end
        
        response = make_api_request(uri, params)
        
        messages = []
        if response && response['ok']
          response['messages'].each do |msg|
            next if msg['type'] != 'message'
            
            sender_name = get_user_name(msg['user'])
            
            messages << {
              'source_id' => @source.id,
              'source_type' => 'slack',
              'external_id' => "slack_dm_#{@source.id}_#{channel_id}_#{msg['ts']}",
              'sender' => sender_name,
              'recipient' => "DM with #{user_name}",
              'subject' => nil,
              'content' => msg['text'],
              'timestamp' => Time.at(msg['ts'].to_f).iso8601,
              'is_read' => 0,
              'metadata' => {
                'channel_id' => channel_id,
                'user_id' => user_id,
                'ts' => msg['ts'],
                'is_dm' => true,
                'workspace' => @source.config['workspace']
              }.to_json,
              'raw_data' => msg.to_json,
              'attachments' => nil
            }
          end
          
          @last_fetch[channel_id] = Time.now
        end
        
        messages
      rescue => e
        puts "Error fetching DMs: #{e.message}"
        []
      end
      
      def fetch_all_conversations
        uri = URI("#{@base_url}/conversations.list")
        params = {
          types: 'public_channel,private_channel,mpim,im',
          limit: 100
        }
        
        response = make_api_request(uri, params, :get)
        
        if response && response['ok']
          response['channels'] || []
        else
          []
        end
      rescue => e
        puts "Error fetching conversations: #{e.message}"
        []
      end
      
      def get_user_name(user_id)
        return @users_cache[user_id] if @users_cache[user_id]
        
        uri = URI("#{@base_url}/users.info")
        params = { user: user_id }
        response = make_api_request(uri, params, :get)
        
        if response && response['ok']
          name = response['user']['profile']['display_name'] || 
                 response['user']['profile']['real_name'] || 
                 response['user']['name']
          @users_cache[user_id] = name
          name
        else
          user_id
        end
      rescue => e
        user_id
      end
      
      def get_channel_name(channel_id)
        return @channels_cache[channel_id] if @channels_cache[channel_id]
        
        uri = URI("#{@base_url}/conversations.info")
        params = { channel: channel_id }
        response = make_api_request(uri, params, :get)
        
        if response && response['ok']
          name = response['channel']['name']
          @channels_cache[channel_id] = name
          name
        else
          channel_id
        end
      rescue => e
        channel_id
      end
      
      def detect_channel_type(channel_id)
        case channel_id[0]
        when 'C' then 'channel'
        when 'G' then 'group'
        when 'D' then 'im'
        when 'M' then 'mpim'
        else 'channel'
        end
      end
      
      def resolve_channel(recipient)
        # If it's already a channel ID, use it
        return recipient if recipient =~ /^[CGDM]/
        
        # If it starts with #, look up the channel
        if recipient.start_with?('#')
          channel_name = recipient[1..-1]
          # Would need to fetch channel list and find matching name
          # For now, assume it's provided as ID
          recipient
        else
          # Assume it's a user name for DM
          # Would need to look up user ID
          recipient
        end
      end
      
      def generate_message_id
        "slack_#{@source.id}_#{Time.now.to_i}_#{rand(1000)}"
      end
    end
  end
end