#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/imap'
require 'json'
require 'fileutils'

module Heathrow
  module Sources
    class Imap
      def initialize(source)
        @source = source
      end
      
      def name
        'IMAP Email'
      end
      
      def description
        'Fetch emails from any IMAP server using username/password'
      end
      
      def fetch_messages
        server = @source.config['imap_server']
        port = @source.config['imap_port'] || 993
        username = @source.config['username']
        password = @source.config['password']
        folder = @source.config['folder'] || 'INBOX'
        fetch_limit = @source.config['fetch_limit'] || 50
        mark_as_read = @source.config['mark_as_read'] || false
        use_ssl = @source.config['use_ssl'] != false  # Default to true
        
        messages = []
        
        begin
          # Connect to IMAP server
          if use_ssl
            imap = Net::IMAP.new(server, port, usessl = true, certs = nil, verify = false)
          else
            imap = Net::IMAP.new(server, port)
          end
          
          # Login with username/password
          imap.login(username, password)
          imap.select(folder)
          
          # Get state file to track which messages we've already seen
          heathrow_home = File.expand_path('~/.heathrow')
          state_file = File.join(heathrow_home, 'state', "imap_#{@source.id}.json")
          FileUtils.mkdir_p(File.dirname(state_file))
          
          seen_uids = if File.exist?(state_file)
            JSON.parse(File.read(state_file))['seen_uids'] || []
          else
            []
          end
          
          # Search for unseen messages
          unseen_uids = imap.search(["UNSEEN"])
          
          # Get UIDs not already processed
          new_uids = unseen_uids - seen_uids
          new_uids = new_uids.first(fetch_limit) if new_uids.length > fetch_limit
          
          new_uids.each do |uid|
            msg = imap.uid_fetch(uid, ["ENVELOPE", "BODY[TEXT]", "FLAGS"]).first
            next unless msg
            
            envelope = msg.attr["ENVELOPE"]
            body = msg.attr["BODY[TEXT]"]
            flags = msg.attr["FLAGS"]
            
            from = envelope.from&.first
            sender = from ? "#{from.name || ''} <#{from.mailbox}@#{from.host}>" : "Unknown"
            
            is_unread = !flags.include?(:Seen)
            
            # Mark as read if configured to do so
            if mark_as_read && is_unread
              imap.uid_store(uid, "+FLAGS", [:Seen])
            end
            
            message = {
              source_id: @source.id,
              source_type: 'imap',
              external_id: "imap_#{username}_#{uid}",
              sender: sender,
              recipient: username,
              subject: envelope.subject || "(no subject)",
              content: body || "",
              raw_data: {
                envelope: envelope,
                flags: flags,
                uid: uid
              }.to_json,
              attachments: nil,
              timestamp: envelope.date || Time.now,
              is_read: flags.include?(:Seen) ? 1 : 0
            }
            
            messages << message
            seen_uids << uid
          end
          
          # Update state file
          File.write(state_file, JSON.generate({ 
            seen_uids: seen_uids,
            last_fetch: Time.now.to_s
          }))
          
          imap.logout
          imap.disconnect
        rescue Net::IMAP::NoResponseError => e
          # Authentication failed
          return [{
            source_id: @source.id,
            source_type: 'imap',
            sender: 'IMAP',
            subject: 'Authentication Failed',
            content: "Failed to login to #{server}: #{e.message}",
            timestamp: Time.now.to_s,
            is_read: 0
          }]
        rescue => e
          # Other errors
          return [{
            source_id: @source.id,
            source_type: 'imap',
            sender: 'IMAP',
            subject: 'Connection Error',
            content: "Error connecting to #{server}: #{e.message}",
            timestamp: Time.now.to_s,
            is_read: 0
          }]
        end
        
        messages
      end
      
      def test_connection
        config = @source.config.is_a?(String) ? JSON.parse(@source.config) : @source.config
        server = config['imap_server']
        port = config['imap_port'] || 993
        username = config['username']
        password = config['password']
        use_ssl = config['use_ssl'] != false
        
        begin
          if use_ssl
            imap = Net::IMAP.new(server, port, usessl = true, certs = nil, verify = false)
          else
            imap = Net::IMAP.new(server, port)
          end
          
          imap.login(username, password)
          
          # Get folder list to verify connection
          folders = imap.list('', '*')
          folder_count = folders&.size || 0
          
          imap.logout
          imap.disconnect
          
          { success: true, message: "Connected to #{server} (#{folder_count} folders)" }
        rescue => e
          { success: false, message: "Connection failed: #{e.message}" }
        end
      end
      
      def can_reply?
        config = @source.config.is_a?(String) ? JSON.parse(@source.config) : @source.config
        # Check if we have SMTP configuration or can use gmail_smtp
        config['smtp_server'] || config['username']&.include?('@')
      end
      
      def send_message(to, subject, body, in_reply_to = nil)
        config = @source.config.is_a?(String) ? JSON.parse(@source.config) : @source.config
        from = config['username']
        
        # Use the SmtpSender module
        require_relative '../smtp_sender'
        
        # SmtpSender will automatically detect OAuth2 domains and use gmail_smtp
        # or fall back to SMTP server configuration
        result = Heathrow::SmtpSender.send_message(
          from,
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