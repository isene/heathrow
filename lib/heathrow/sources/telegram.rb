#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'time'

module Heathrow
  module Sources
    class Telegram
      attr_reader :source, :last_fetch_time
      
      def initialize(source)
        @source = source
        @config = source.config.is_a?(String) ? JSON.parse(source.config) : source.config
        @last_fetch_time = Time.now
        @last_message_id = nil
      end
      
      def fetch_messages
        messages = []
        
        begin
          # Use Bot API or MTProto based on configuration
          if @config['bot_token']
            messages = fetch_bot_messages
          elsif @config['api_id'] && @config['api_hash']
            messages = fetch_mtproto_messages
          else
            puts "Telegram: No valid credentials configured" if ENV['DEBUG']
          end
          
        rescue => e
          puts "Telegram fetch error: #{e.message}" if ENV['DEBUG']
          puts e.backtrace.join("\n") if ENV['DEBUG']
        end
        
        messages
      end
      
      def test_connection
        begin
          if @config['bot_token']
            test_bot_connection
          elsif @config['api_id'] && @config['api_hash']
            test_mtproto_connection
          else
            { success: false, message: "No Telegram credentials configured" }
          end
        rescue => e
          { success: false, message: "Connection test failed: #{e.message}" }
        end
      end
      
      def authenticate
        if @config['api_id'] && @config['api_hash'] && @config['phone_number']
          authenticate_mtproto
        else
          puts "For user account access, configure api_id, api_hash, and phone_number"
          puts "For bot access, configure bot_token"
          false
        end
      end
      
      def can_reply?
        true
      end
      
      def send_message(to, subject, body, in_reply_to = nil)
        if @config['bot_token']
          send_bot_message(to, body, in_reply_to)
        elsif @config['session_string']
          send_mtproto_message(to, body, in_reply_to)
        else
          { success: false, message: "Telegram not configured for sending" }
        end
      end
      
      private
      
      def send_bot_message(to, body, in_reply_to = nil)
        token = @config['bot_token']
        
        # Parse recipient - could be chat ID or username
        chat_id = if to =~ /^-?\d+$/
          to  # Already a chat ID
        else
          # For usernames, we'd need to look up the chat ID
          # For now, require chat IDs
          return { success: false, message: "Please use chat ID for Telegram messages" }
        end
        
        uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
        
        params = {
          chat_id: chat_id,
          text: body
        }
        
        # Add reply if specified
        params[:reply_to_message_id] = in_reply_to if in_reply_to
        
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = params.to_json
        
        begin
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
          
          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)
            if data['ok']
              { success: true, message: "Message sent via Telegram bot" }
            else
              { success: false, message: "Failed: #{data['description']}" }
            end
          else
            { success: false, message: "HTTP error: #{response.code}" }
          end
        rescue => e
          { success: false, message: "Send failed: #{e.message}" }
        end
      end
      
      def send_mtproto_message(to, body, in_reply_to = nil)
        # This would require the MTProto server
        api_url = @config['mtproto_api_url'] || 'http://localhost:8081'
        
        uri = URI("#{api_url}/send")
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = {
          session_string: @config['session_string'],
          chat_id: to,
          text: body,
          reply_to: in_reply_to
        }.to_json
        
        begin
          response = Net::HTTP.start(uri.hostname, uri.port) do |http|
            http.request(request)
          end
          
          if response.is_a?(Net::HTTPSuccess)
            { success: true, message: "Message sent via Telegram" }
          else
            { success: false, message: "Failed to send via MTProto" }
          end
        rescue => e
          { success: false, message: "MTProto server not available: #{e.message}" }
        end
      end
      
      # Bot API Methods (simpler but limited to bot interactions)
      
      def fetch_bot_messages
        messages = []
        token = @config['bot_token']
        
        uri = URI("https://api.telegram.org/bot#{token}/getUpdates")
        params = { timeout: 0, limit: @config['fetch_limit'] || 100 }
        
        # Use offset for incremental updates
        if @last_message_id
          params[:offset] = @last_message_id + 1
        end
        
        uri.query = URI.encode_www_form(params)
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          
          if data['ok'] && data['result']
            data['result'].each do |update|
              if update['message']
                msg = convert_bot_message(update['message'])
                messages << msg if msg
                @last_message_id = update['update_id']
              end
            end
          end
        else
          puts "Telegram Bot API error: #{response.code}" if ENV['DEBUG']
        end
        
        messages
      end
      
      def test_bot_connection
        token = @config['bot_token']
        uri = URI("https://api.telegram.org/bot#{token}/getMe")
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          if data['ok']
            bot = data['result']
            { success: true, message: "Connected as bot @#{bot['username']}" }
          else
            { success: false, message: "Bot token invalid" }
          end
        else
          { success: false, message: "Failed to connect to Telegram Bot API" }
        end
      end
      
      def convert_bot_message(msg)
        # Extract sender info
        from = msg['from']
        sender = from['username'] || "#{from['first_name']} #{from.fetch('last_name', '')}".strip
        
        # Extract chat info
        chat = msg['chat']
        recipient = case chat['type']
                   when 'private'
                     'Me (Bot)'
                   when 'group', 'supergroup'
                     chat['title']
                   when 'channel'
                     chat['title']
                   else
                     'Unknown'
                   end
        
        # Extract content
        content = msg['text'] || msg['caption'] || ''
        subject = content[0..50]
        subject += "..." if content.length > 50
        
        # Handle attachments
        attachments = extract_bot_attachments(msg)
        
        {
          source_id: @source.id,
          source_type: 'telegram',
          external_id: "telegram_#{msg['message_id']}_#{chat['id']}",
          sender: sender,
          recipient: recipient,
          subject: subject,
          content: content,
          raw_data: msg.to_json,
          attachments: attachments,
          timestamp: Time.at(msg['date']).iso8601,
          is_read: 0
        }
      end
      
      def extract_bot_attachments(msg)
        attachments = []
        
        # Photo
        if msg['photo']
          largest = msg['photo'].max_by { |p| p['file_size'] }
          attachments << { type: 'photo', file_id: largest['file_id'] }
        end
        
        # Video
        if msg['video']
          attachments << {
            type: 'video',
            file_id: msg['video']['file_id'],
            duration: msg['video']['duration']
          }
        end
        
        # Document
        if msg['document']
          attachments << {
            type: 'document',
            file_id: msg['document']['file_id'],
            file_name: msg['document']['file_name'],
            mime_type: msg['document']['mime_type']
          }
        end
        
        # Voice
        if msg['voice']
          attachments << {
            type: 'voice',
            file_id: msg['voice']['file_id'],
            duration: msg['voice']['duration']
          }
        end
        
        # Location
        if msg['location']
          attachments << {
            type: 'location',
            latitude: msg['location']['latitude'],
            longitude: msg['location']['longitude']
          }
        end
        
        # Sticker
        if msg['sticker']
          attachments << {
            type: 'sticker',
            file_id: msg['sticker']['file_id'],
            emoji: msg['sticker']['emoji']
          }
        end
        
        attachments.empty? ? nil : attachments.to_json
      end
      
      # MTProto Methods (full user account access via proxy server)
      
      def fetch_mtproto_messages
        messages = []
        
        # This requires a separate MTProto proxy server
        # Similar to WhatsApp's whatsmeow server
        api_url = @config['mtproto_api_url'] || 'http://localhost:8081'
        
        uri = URI("#{api_url}/messages")
        params = {
          session_string: @config['session_string'],
          limit: @config['fetch_limit'] || 100
        }
        
        if @last_fetch_time && @config['incremental_sync']
          params[:since] = (@last_fetch_time - 300).iso8601
        end
        
        uri.query = URI.encode_www_form(params)
        
        response = Net::HTTP.get_response(uri)
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          
          if data['messages']
            data['messages'].each do |msg|
              message = convert_mtproto_message(msg)
              messages << message if message
            end
          end
          
          @last_fetch_time = Time.now
        else
          puts "Telegram MTProto API error: #{response.code}" if ENV['DEBUG']
        end
        
        messages
      end
      
      def test_mtproto_connection
        api_url = @config['mtproto_api_url'] || 'http://localhost:8081'
        
        # Check if API server is running
        uri = URI("#{api_url}/health")
        response = Net::HTTP.get_response(uri)
        
        unless response.is_a?(Net::HTTPSuccess)
          return { success: false, message: "Telegram MTProto server not running at #{api_url}" }
        end
        
        # Check session status
        if @config['session_string']
          uri = URI("#{api_url}/session/status")
          uri.query = URI.encode_www_form(session_string: @config['session_string'])
          response = Net::HTTP.get_response(uri)
          
          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)
            if data['authenticated']
              { success: true, message: "Connected as #{data['username'] || data['phone']}" }
            else
              { success: false, message: "Session expired. Re-authentication required." }
            end
          else
            { success: false, message: "Failed to check session status" }
          end
        else
          { success: false, message: "No session configured. Run authentication first." }
        end
      end
      
      def authenticate_mtproto
        api_url = @config['mtproto_api_url'] || 'http://localhost:8081'
        
        puts "\n=== Telegram Authentication ==="
        puts "Phone: #{@config['phone_number']}"
        
        # Start authentication
        uri = URI("#{api_url}/auth/start")
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = {
          api_id: @config['api_id'],
          api_hash: @config['api_hash'],
          phone_number: @config['phone_number']
        }.to_json
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(request)
        end
        
        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          
          if data['code_sent']
            print "\nEnter the code sent to your Telegram app: "
            code = gets.chomp
            
            # Submit code
            uri = URI("#{api_url}/auth/code")
            request = Net::HTTP::Post.new(uri)
            request['Content-Type'] = 'application/json'
            request.body = {
              session_id: data['session_id'],
              code: code
            }.to_json
            
            response = Net::HTTP.start(uri.hostname, uri.port) do |http|
              http.request(request)
            end
            
            if response.is_a?(Net::HTTPSuccess)
              auth_data = JSON.parse(response.body)
              
              if auth_data['requires_2fa']
                print "Enter your 2FA password: "
                password = gets.chomp
                
                # Submit 2FA password
                uri = URI("#{api_url}/auth/2fa")
                request = Net::HTTP::Post.new(uri)
                request['Content-Type'] = 'application/json'
                request.body = {
                  session_id: data['session_id'],
                  password: password
                }.to_json
                
                response = Net::HTTP.start(uri.hostname, uri.port) do |http|
                  http.request(request)
                end
                
                if response.is_a?(Net::HTTPSuccess)
                  auth_data = JSON.parse(response.body)
                end
              end
              
              if auth_data['session_string']
                # Save session string to config
                @config['session_string'] = auth_data['session_string']
                puts "\n✓ Authentication successful!"
                puts "Session saved. You won't need to authenticate again."
                return true
              end
            end
          end
        end
        
        puts "\n✗ Authentication failed"
        false
      end
      
      def convert_mtproto_message(msg)
        # Convert MTProto message format to Heathrow format
        sender = msg['sender_name'] || msg['sender_username'] || msg['sender_id'].to_s
        recipient = msg['chat_name'] || msg['chat_id'].to_s
        
        content = msg['text'] || ''
        subject = content[0..50]
        subject += "..." if content.length > 50
        
        # Handle media
        attachments = []
        if msg['media']
          attachments << {
            type: msg['media']['type'],
            file_id: msg['media']['file_id'],
            caption: msg['media']['caption']
          }
        end
        
        {
          source_id: @source.id,
          source_type: 'telegram',
          external_id: "telegram_#{msg['id']}",
          sender: sender,
          recipient: recipient,
          subject: subject,
          content: content,
          raw_data: msg.to_json,
          attachments: attachments.empty? ? nil : attachments.to_json,
          timestamp: msg['date'] || Time.now.iso8601,
          is_read: msg['is_read'] ? 1 : 0
        }
      end
    end
  end
end