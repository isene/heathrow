#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/smtp'
require 'mail'
require 'json'
require 'base64'
require 'open3'

# Monkey patch Net::SMTP to add xoauth2 support
module Net
  class SMTP
    unless method_defined?(:auth_xoauth2)
      private
      
      def auth_xoauth2(user, secret)
        auth_string = "user=#{user}\1auth=Bearer #{secret}\1\1"
        res = critical {
          send("AUTH XOAUTH2 #{Base64.strict_encode64(auth_string)}", true)
          recv_response()
        }
        check_auth_response res
      end
    end
  end
end

module Heathrow
  # OAuth2 SMTP module - integrated version of gmail_smtp
  # Handles OAuth2 authentication for Gmail and compatible services
  class OAuth2Smtp
    attr_reader :from_address, :log_file

    def initialize(from_address = nil, config = {})
      cfg = Heathrow::Config.instance
      @safe_dir = config['safe_dir'] || cfg&.rc('safe_dir', File.join(Dir.home, '.heathrow', 'mail'))
      @default_email = config['default_email'] || cfg&.rc('default_email', '')
      @oauth2_script = config['oauth2_script'] || cfg&.rc('oauth2_script', File.expand_path('~/bin/oauth2.py'))
      @log_file_path = File.join(@safe_dir, '.smtp.log')
      @from_address = from_address || @default_email
      @log_file = File.open(@log_file_path, 'a') if File.exist?(@safe_dir) && File.writable?(@safe_dir)
    end
    
    # Send email using OAuth2 authentication
    def send(mail_object, recipients = nil)
      begin
        log "Mail to send: SUBJECT: #{mail_object.subject}"
        log "FROM: #{from_address}"
        
        # Extract recipients from mail object if not provided
        if recipients.nil?
          recipients = []
          recipients += Array(mail_object.to) if mail_object.to
          recipients += Array(mail_object.cc) if mail_object.cc
          recipients.uniq!
        end
        
        log "TO: #{recipients.inspect}"
        
        # Get OAuth2 access token
        token = get_oauth2_token
        
        unless token
          error_msg = "Failed to get OAuth2 token for #{from_address}"
          log error_msg
          return { success: false, message: error_msg }
        end
        
        log "Token obtained for #{from_address}"
        
        # Send via Gmail SMTP with OAuth2
        send_via_smtp(mail_object, token, recipients)
        
      rescue => e
        error_msg = "OAuth2 SMTP error: #{e.message}"
        log error_msg
        { success: false, message: error_msg }
      ensure
        @log_file&.close
      end
    end
    
    # Get OAuth2 access token using stored credentials
    def get_oauth2_token
      # Find the correct credential files
      json_file = find_credential_file('.json')
      txt_file = find_credential_file('.txt')
      
      unless json_file && txt_file
        log "Credential files not found for #{from_address}"
        return nil
      end
      
      log "Using #{json_file}"
      
      begin
        # Parse the JSON credentials
        credentials = JSON.parse(File.read(json_file))
        client_id = credentials.dig('web', 'client_id') || credentials.dig('installed', 'client_id')
        client_secret = credentials.dig('web', 'client_secret') || credentials.dig('installed', 'client_secret')
        
        # Read the refresh token
        refresh_token = File.read(txt_file).strip
        
        # Call oauth2.py to get access token
        if File.exist?(@oauth2_script)
          get_token_via_script(client_id, client_secret, refresh_token)
        else
          # Fallback to direct API call if script not available
          get_token_via_api(client_id, client_secret, refresh_token)
        end
        
      rescue => e
        log "Error getting token: #{e.message}"
        nil
      end
    end
    
    private
    
    # Find credential file for the email address
    def find_credential_file(extension)
      # Try exact email match first
      file = File.join(@safe_dir, "#{from_address}#{extension}")
      return file if File.exist?(file)
      
      # Try without domain for aliases
      username = from_address.split('@').first
      file = File.join(@safe_dir, "#{username}#{extension}")
      return file if File.exist?(file)
      
      # Try default email
      file = File.join(@safe_dir, "#{@default_email}#{extension}")
      return file if File.exist?(file)
      
      nil
    end
    
    # Get token using oauth2.py script
    def get_token_via_script(client_id, client_secret, refresh_token)
      cmd = [
        @oauth2_script,
        '--generate_oauth2_token',
        "--client_id=#{client_id}",
        "--client_secret=#{client_secret}",
        "--refresh_token=#{refresh_token}"
      ]
      
      log "Getting token for #{from_address}"
      
      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        # Extract token from output
        if stdout =~ /Access Token:\s*(\S+)/
          token = $1
          log "Token obtained for #{from_address}"
          return token
        end
      else
        log "oauth2.py error: #{stderr}"
      end
      
      nil
    end
    
    # Get token via direct Google API call (fallback)
    def get_token_via_api(client_id, client_secret, refresh_token)
      require 'net/http'
      require 'uri'
      
      uri = URI('https://oauth2.googleapis.com/token')
      
      params = {
        'client_id' => client_id,
        'client_secret' => client_secret,
        'refresh_token' => refresh_token,
        'grant_type' => 'refresh_token'
      }
      
      response = Net::HTTP.post_form(uri, params)
      
      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        token = data['access_token']
        log "Token obtained via API for #{from_address}"
        return token
      else
        log "Token API error: #{response.body}"
        nil
      end
    end
    
    # Send email via SMTP with OAuth2
    def send_via_smtp(mail_object, token, recipients)
      smtp = Net::SMTP.new('smtp.gmail.com', 587)
      smtp.enable_starttls_auto
      
      log "Sending email"
      
      # Extract email address for authentication
      auth_email = from_address.split(/[<>]/).find { |s| s.include?('@') } || from_address
      
      # Extract bare email addresses for SMTP envelope
      bare_from = auth_email
      bare_recipients = Array(recipients).map { |r| r[/<([^>]+)>/, 1] || r.strip }

      smtp.start('gmail.com', auth_email, token, :xoauth2) do |smtp_conn|
        smtp_conn.send_message(
          mail_object.to_s,
          bare_from,
          bare_recipients
        )
      end
      
      log "Email sent"
      
      { success: true, message: "Message sent via OAuth2" }
      
    rescue => e
      error_msg = "SMTP error: #{e.message}"
      log error_msg
      { success: false, message: error_msg }
    ensure
      smtp&.finish rescue nil
    end
    
    # Log message with timestamp
    def log(message)
      return unless @log_file
      
      @log_file.puts "#{Time.now.utc} #{message}"
      @log_file.flush
    end
    
    # Class method for easy sending
    def self.send_message(from, to, subject, body, in_reply_to = nil)
      mail = Mail.new do
        from     from
        to       to
        subject  subject
        body     body
      end
      
      if in_reply_to
        mail['In-Reply-To'] = in_reply_to
        mail['References'] = in_reply_to
      end
      
      oauth2 = new(from)
      oauth2.send(mail)
    end
  end
end