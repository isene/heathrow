#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/imap'
require 'gmail_xoauth'
require 'json'
require 'fileutils'
require 'open3'

module Heathrow
  module Sources
    class Gmail
      def initialize(source)
        @source = source
      end
      
      def name
        'Gmail'
      end
      
      def description
        'Fetch emails from Gmail using OAuth2'
      end
      
      def config_fields
        [
          { name: 'email', label: 'Gmail Address', type: 'text', required: true },
          { name: 'safedir', label: 'Safe Directory', type: 'text', required: true,
            hint: 'Directory containing your .json and .txt OAuth files' },
          { name: 'oauth2_script', label: 'OAuth2 Script Path', type: 'text', required: true,
            hint: 'Path to oauth2.py script' },
          { name: 'folder', label: 'Folder to Monitor', type: 'text', default: 'INBOX' },
          { name: 'fetch_limit', label: 'Max messages per fetch', type: 'number', default: 50 },
          { name: 'check_interval', label: 'Check Interval (seconds)', type: 'number', default: 300 },
          { name: 'mark_as_read', label: 'Mark fetched as read', type: 'boolean', default: false,
            hint: 'CAUTION: Only enable if you want Heathrow to mark emails as read' }
        ]
      end
      
      def validate_config(config)
        return { valid: false, error: 'Email is required' } unless config['email']
        return { valid: false, error: 'Safe directory is required' } unless config['safedir']
        
        # Check if OAuth files exist
        email = config['email']
        safedir = File.expand_path(config['safedir'])
        json_file = File.join(safedir, "#{email}.json")
        txt_file = File.join(safedir, "#{email}.txt")
        
        unless File.exist?(json_file)
          return { valid: false, error: "OAuth JSON file not found: #{json_file}" }
        end
        
        unless File.exist?(txt_file)
          return { valid: false, error: "Refresh token file not found: #{txt_file}" }
        end
        
        { valid: true }
      end
      
      def fetch_messages
        email = @source.config['email']
        safedir = File.expand_path(@source.config['safedir'])
        oauth2_script = File.expand_path(@source.config['oauth2_script'] || '~/bin/oauth2.py')
        folder = @source.config['folder'] || 'INBOX'
        fetch_limit = @source.config['fetch_limit'] || 50
        mark_as_read = @source.config['mark_as_read'] || false
        
        # Read OAuth credentials
        json_file = File.join(safedir, "#{email}.json")
        txt_file = File.join(safedir, "#{email}.txt")
        
        begin
          jparse = JSON.parse(File.read(json_file))
          clientid = jparse["web"]["client_id"]
          clsecret = jparse["web"]["client_secret"]
          refresh_token = File.read(txt_file).chomp
        rescue StandardError => e
          return [{
            source_id: @source.id,
            source_type: 'gmail',
            sender: 'Gmail',
            subject: 'Configuration Error',
            content: "Failed to read OAuth credentials: #{e.message}",
            timestamp: Time.now.to_s,
            is_read: 0
          }]
        end
        
        # Get access token using oauth2.py
        begin
          cmd = "python3 #{oauth2_script} --generate_oauth2_token " \
                "--client_id=#{clientid} --client_secret=#{clsecret} " \
                "--refresh_token=#{refresh_token}"
          
          require 'timeout'
          stdout = stderr = nil
          status = nil
          
          Timeout::timeout(10) do
            stdout, stderr, status = Open3.capture3(cmd)
          end
          
          unless status && status.success?
            raise "OAuth token generation failed: #{stderr || 'No output'}"
          end
          
          # Extract access token from output (format: "Access Token: <token>")
          token_match = stdout.match(/Access Token: (.+?)(\n|$)/)
          unless token_match
            raise "Could not extract access token from output: #{stdout}"
          end
          token = token_match[1].strip
        rescue StandardError => e
          return [{
            source_id: @source.id,
            source_type: 'gmail',
            sender: 'Gmail',
            subject: 'Authentication Error',
            content: "Failed to get access token: #{e.message}",
            timestamp: Time.now.to_s,
            is_read: 0
          }]
        end
        
        messages = []
        
        begin
          # Connect to Gmail IMAP
          imap = Net::IMAP.new('imap.gmail.com', 993, usessl = true, certs = nil, verify = false)
          
          # Authenticate with OAuth2
          imap.authenticate('XOAUTH2', email, token)
          imap.select(folder)
          
          # Get state file to track which messages we've already seen
          heathrow_home = File.expand_path('~/.heathrow')
          state_file = File.join(heathrow_home, 'state', "gmail_#{@source.id}.json")
          FileUtils.mkdir_p(File.dirname(state_file))
          
          seen_uids = if File.exist?(state_file)
            JSON.parse(File.read(state_file))['seen_uids'] || []
          else
            []
          end
          
          # Search for messages (both seen and unseen for testing)
          # In production, you might want to use ["UNSEEN"] only
          search_criteria = mark_as_read ? ["UNSEEN"] : ["ALL"]
          
          # Get UIDs of messages
          uids = imap.uid_search(search_criteria)
          
          # Limit the number of messages to fetch
          new_uids = uids.reject { |uid| seen_uids.include?(uid) }.last(fetch_limit)
          
          new_uids.each do |uid|
            begin
              # Fetch the message envelope and body
              fetch_data = imap.uid_fetch(uid, ['ENVELOPE', 'BODY.PEEK[TEXT]', 'FLAGS'])[0]
              
              envelope = fetch_data.attr['ENVELOPE']
              body = fetch_data.attr['BODY[TEXT]'] || ''
              flags = fetch_data.attr['FLAGS'] || []
              
              # Extract sender
              from = if envelope.from && envelope.from.first
                addr = envelope.from.first
                if addr.name
                  "#{addr.name} <#{addr.mailbox}@#{addr.host}>"
                else
                  "#{addr.mailbox}@#{addr.host}"
                end
              else
                'Unknown Sender'
              end
              
              # Clean up subject
              subject = envelope.subject || '(No Subject)'
              
              # Parse date
              date = envelope.date ? Time.parse(envelope.date) : Time.now
              
              # Truncate body for preview
              body_preview = body.to_s
                .force_encoding('UTF-8')
                .encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
                .gsub(/\r\n/, "\n")
                .strip[0..500]
              
              # Check if message is unread
              is_unread = !flags.include?(:Seen)
              
              messages << {
                source_id: @source.id,
                source_type: 'gmail',
                sender: from,
                subject: subject,
                content: body_preview,
                timestamp: date.to_s,
                is_read: is_unread ? 0 : 1,
                metadata: {
                  uid: uid,
                  folder: folder,
                  message_id: envelope.message_id,
                  flags: flags.map(&:to_s)
                }.to_json
              }
              
              # Add to seen UIDs list
              seen_uids << uid
              
              # IMPORTANT: Only mark as read if explicitly configured
              if mark_as_read && is_unread
                imap.uid_store(uid, "+FLAGS", [:Seen])
              end
            rescue StandardError => e
              # Log error but continue with other messages
              puts "Error fetching message UID #{uid}: #{e.message}" if ENV['DEBUG']
            end
          end
          
          # Save state
          File.write(state_file, JSON.pretty_generate({
            seen_uids: seen_uids,
            last_check: Time.now.to_s
          }))
          
          # Disconnect
          imap.logout
          imap.disconnect
          
        rescue StandardError => e
          return [{
            source_id: @source.id,
            source_type: 'gmail',
            sender: 'Gmail',
            subject: 'Connection Error',
            content: "Failed to connect to Gmail: #{e.message}",
            timestamp: Time.now.to_s,
            is_read: 0
          }]
        end
        
        messages
      end
      
      def test
        # Test connection and authentication
        email = @source.config['email']
        
        begin
          # Try to get token
          messages = fetch_messages
          
          if messages.any? { |m| m[:subject] =~ /Error/ }
            { success: false, message: messages.first[:content] }
          else
            { 
              success: true, 
              message: "Successfully connected to Gmail for #{email}. Found #{messages.size} messages."
            }
          end
        rescue StandardError => e
          { success: false, message: "Test failed: #{e.message}" }
        end
      end
      
      def can_reply?
        true
      end
      
      def send_message(to, subject, body, in_reply_to = nil)
        config = @source.config.is_a?(String) ? JSON.parse(@source.config) : @source.config
        email = config['email']
        
        # Use the SmtpSender module
        require_relative '../smtp_sender'
        
        # SmtpSender handles all the complexity of OAuth2 and gmail_smtp
        result = Heathrow::SmtpSender.send_message(
          email,
          to,
          subject,
          body,
          in_reply_to,
          config
        )
        
        result
      end
    end
  end
end