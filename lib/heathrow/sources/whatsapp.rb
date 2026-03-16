#!/usr/bin/env ruby
# frozen_string_literal: true

# WhatsApp source using WAHA (WhatsApp HTTP API)
# Requires: docker run -p 3000:3000 devlikeapro/waha

require 'net/http'
require 'json'
require 'uri'
require 'base64'
require 'time'

module Heathrow
  module Sources
    class Whatsapp
      attr_reader :source, :last_fetch_time

      DEFAULT_API_URL = 'http://localhost:3000'
      DEFAULT_SESSION = 'default'

      def initialize(source)
        @source = source
        @config = source.config.is_a?(String) ? JSON.parse(source.config) : source.config
        @last_fetch_time = Time.now
        @session = @config['session'] || DEFAULT_SESSION
        @api_url = @config['api_url'] || DEFAULT_API_URL
      end

      def fetch_messages
        messages = []

        begin
          unless authenticated?
            puts "WhatsApp not authenticated. Run setup first." if ENV['DEBUG']
            return messages
          end

          # Get list of chats
          chats = fetch_chats
          return messages if chats.empty?

          # Fetch recent messages from each chat
          limit = @config['fetch_limit'] || 20
          chats.each do |chat|
            chat_id = chat['id']
            chat_messages = fetch_chat_messages(chat_id, limit)

            chat_messages.each do |msg|
              message = convert_to_heathrow_message(msg, chat)
              messages << message if message
            end
          end

          @last_fetch_time = Time.now

        rescue => e
          puts "WhatsApp fetch error: #{e.message}" if ENV['DEBUG']
          puts e.backtrace.join("\n") if ENV['DEBUG']
        end

        messages
      end

      def test_connection
        begin
          # Check session status
          uri = URI("#{@api_url}/api/sessions/#{@session}")
          response = Net::HTTP.get_response(uri)

          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)
            status = data['status']

            case status
            when 'WORKING'
              me = data.dig('me', 'id') || 'Unknown'
              phone = me.split('@').first
              { success: true, message: "Connected as +#{phone}" }
            when 'SCAN_QR_CODE'
              { success: false, message: "Session needs QR code scan. Run setup." }
            when 'STARTING'
              { success: false, message: "Session is starting..." }
            when 'STOPPED'
              { success: false, message: "Session stopped. Run setup to start." }
            else
              { success: false, message: "Session status: #{status}" }
            end
          elsif response.code == '404'
            { success: false, message: "Session '#{@session}' not found. Run setup." }
          else
            { success: false, message: "API error: #{response.code}" }
          end

        rescue Errno::ECONNREFUSED
          { success: false, message: "WAHA not running. Start with: docker run -p 3000:3000 devlikeapro/waha" }
        rescue => e
          { success: false, message: "Connection failed: #{e.message}" }
        end
      end

      def can_reply?
        authenticated?
      end

      def send_message(to, subject, body, in_reply_to = nil)
        unless can_reply?
          return { success: false, message: "WhatsApp not authenticated" }
        end

        begin
          chat_id = format_chat_id(to)

          payload = {
            session: @session,
            chatId: chat_id,
            text: body
          }

          # Add reply context if replying
          payload[:reply_to] = in_reply_to if in_reply_to

          uri = URI("#{@api_url}/api/sendText")
          response = post_json(uri, payload)

          if response.is_a?(Net::HTTPSuccess)
            { success: true, message: "Message sent to #{to}" }
          else
            error = parse_error(response)
            { success: false, message: "Failed to send: #{error}" }
          end

        rescue Errno::ECONNREFUSED
          { success: false, message: "WAHA not running" }
        rescue => e
          { success: false, message: "Send failed: #{e.message}" }
        end
      end

      def send_media(to, file_path, caption = nil)
        unless can_reply?
          return { success: false, message: "WhatsApp not authenticated" }
        end

        begin
          chat_id = format_chat_id(to)
          mime_type = detect_mime_type(file_path)

          # Determine endpoint based on media type
          endpoint = case mime_type
                     when /^image/ then '/api/sendImage'
                     when /^video/ then '/api/sendVideo'
                     when /^audio/ then '/api/sendVoice'
                     else '/api/sendFile'
                     end

          # Read and encode file
          file_data = Base64.strict_encode64(File.binread(file_path))

          payload = {
            session: @session,
            chatId: chat_id,
            file: {
              mimetype: mime_type,
              filename: File.basename(file_path),
              data: file_data
            }
          }
          payload[:caption] = caption if caption

          uri = URI("#{@api_url}#{endpoint}")
          response = post_json(uri, payload)

          if response.is_a?(Net::HTTPSuccess)
            { success: true, message: "Media sent to #{to}" }
          else
            error = parse_error(response)
            { success: false, message: "Failed to send media: #{error}" }
          end

        rescue => e
          { success: false, message: "Send media failed: #{e.message}" }
        end
      end

      def authenticate
        begin
          # Create session if it doesn't exist
          unless session_exists?
            puts "Creating WhatsApp session '#{@session}'..."
            create_session
          end

          # Start session if stopped
          status = get_session_status
          if status == 'STOPPED'
            start_session
            sleep(2)
          end

          # Get QR code and wait for scan
          authenticate_with_qr_code

        rescue => e
          puts "Authentication error: #{e.message}"
          false
        end
      end

      def post_configure
        if authenticated?
          puts "WhatsApp already authenticated!"
          return true
        end

        puts "\nWhatsApp requires authentication via QR code."
        print "Would you like to authenticate now? (y/n): "
        response = gets.chomp.downcase

        if response == 'y'
          authenticate
        else
          puts "You can authenticate later by running: ruby setup_whatsapp.rb"
          true
        end
      end

      private

      def authenticated?
        status = get_session_status
        status == 'WORKING'
      end

      def session_exists?
        uri = URI("#{@api_url}/api/sessions/#{@session}")
        response = Net::HTTP.get_response(uri)
        response.is_a?(Net::HTTPSuccess)
      rescue
        false
      end

      def get_session_status
        uri = URI("#{@api_url}/api/sessions/#{@session}")
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          data['status']
        else
          nil
        end
      rescue
        nil
      end

      def create_session
        uri = URI("#{@api_url}/api/sessions")
        payload = { name: @session }
        post_json(uri, payload)
      end

      def start_session
        uri = URI("#{@api_url}/api/sessions/#{@session}/start")
        post_json(uri, {})
      end

      def authenticate_with_qr_code
        puts "\n=== WhatsApp QR Code Authentication ==="
        puts "1. Open WhatsApp on your phone"
        puts "2. Go to Settings > Linked Devices"
        puts "3. Tap 'Link a Device'"
        puts "4. Scan the QR code\n\n"

        max_attempts = 60
        attempt = 0
        last_qr = nil

        while attempt < max_attempts
          status = get_session_status

          case status
          when 'WORKING'
            puts "\n[OK] Successfully authenticated!"
            return true
          when 'SCAN_QR_CODE'
            qr = fetch_qr_code
            if qr && qr != last_qr
              display_qr_terminal(qr)
              last_qr = qr
            end
          when 'STARTING'
            print "."
          end

          sleep(2)
          attempt += 1
        end

        puts "\nAuthentication timeout. Please try again."
        false
      end

      def fetch_qr_code
        uri = URI("#{@api_url}/api/#{@session}/auth/qr?format=raw")
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          data['value']
        else
          nil
        end
      rescue
        nil
      end

      def display_qr_terminal(qr_string)
        # Use qrencode if available, otherwise print raw
        begin
          require 'rqrcode'
          qr = RQRCode::QRCode.new(qr_string)
          puts qr.as_ansi(
            light: "\e[47m", dark: "\e[40m",
            fill_character: '  ',
            quiet_zone_size: 1
          )
        rescue LoadError
          # Fallback: try system qrencode
          result = `echo '#{qr_string}' | qrencode -t ANSIUTF8 2>/dev/null`
          if $?.success?
            puts result
          else
            puts "QR Data: #{qr_string}"
            puts "\nInstall 'rqrcode' gem or 'qrencode' for visual QR code"
          end
        end
      end

      def fetch_chats
        uri = URI("#{@api_url}/api/#{@session}/chats?limit=50")
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body)
        else
          []
        end
      rescue
        []
      end

      def fetch_chat_messages(chat_id, limit = 20)
        encoded_chat_id = URI.encode_www_form_component(chat_id)
        uri = URI("#{@api_url}/api/#{@session}/chats/#{encoded_chat_id}/messages?limit=#{limit}")
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body)
        else
          []
        end
      rescue
        []
      end

      def convert_to_heathrow_message(msg, chat)
        sender_id = msg['from'] || msg['_data']&.dig('from')
        sender = format_phone_number(sender_id)

        # Get chat name
        chat_name = chat['name'] || chat['id']&.split('@')&.first || 'Unknown'

        content = msg['body'] || ''
        subject = content[0..50]
        subject += "..." if content.length > 50

        # Handle timestamps
        timestamp = if msg['timestamp']
                      Time.at(msg['timestamp']).iso8601
                    else
                      Time.now.iso8601
                    end

        {
          source_id: @source.id,
          source_type: 'whatsapp',
          external_id: "whatsapp_#{msg['id']}",
          sender: sender,
          recipient: chat_name,
          subject: subject,
          content: content,
          raw_data: msg.to_json,
          attachments: extract_attachments(msg),
          timestamp: timestamp,
          is_read: msg['ack'].to_i >= 1 ? 1 : 0
        }
      end

      def format_phone_number(jid)
        return '[Unknown]' unless jid

        phone = jid.split('@').first
        if jid.include?('@c.us') || jid.include?('@s.whatsapp.net')
          "+#{phone}"
        elsif jid.include?('@g.us')
          phone  # Group ID
        else
          jid
        end
      end

      def format_chat_id(to)
        # Clean phone number
        phone = to.gsub(/[^\d+]/, '').sub(/^\+/, '')

        if phone.include?('-')
          "#{phone}@g.us"
        else
          "#{phone}@c.us"
        end
      end

      def extract_attachments(msg)
        attachments = []

        if msg['hasMedia']
          attachments << {
            type: msg['type'],
            url: msg.dig('media', 'url'),
            mime_type: msg['mimetype'],
            filename: msg['filename']
          }
        end

        attachments.empty? ? nil : attachments.to_json
      end

      def post_json(uri, payload)
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = payload.to_json

        Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(request)
        end
      end

      def parse_error(response)
        data = JSON.parse(response.body)
        data['message'] || data['error'] || response.message
      rescue
        response.message
      end

      def detect_mime_type(file_path)
        ext = File.extname(file_path).downcase

        case ext
        when '.jpg', '.jpeg' then 'image/jpeg'
        when '.png' then 'image/png'
        when '.gif' then 'image/gif'
        when '.webp' then 'image/webp'
        when '.mp4' then 'video/mp4'
        when '.mp3' then 'audio/mpeg'
        when '.ogg' then 'audio/ogg'
        when '.pdf' then 'application/pdf'
        when '.doc' then 'application/msword'
        when '.docx' then 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        else 'application/octet-stream'
        end
      end
    end
  end
end
