#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tempfile'
require 'shellwords'

module Heathrow
  # SMTP sender module - supports OAuth2 and standard SMTP
  # Configure oauth2_domains, smtp_command, safe_dir in ~/.heathrowrc
  class SmtpSender
    attr_reader :from_address, :config

    def initialize(from_address, config = {})
      @from_address = from_address
      @config = config
      cfg = Heathrow::Config.instance
      @oauth2_domains = cfg&.rc('oauth2_domains', %w[gmail.com]) || %w[gmail.com]
      @smtp_command = cfg&.rc('smtp_command', File.expand_path('~/bin/gmail_smtp'))
      @safe_dir = cfg&.rc('safe_dir', File.join(Dir.home, '.heathrow', 'mail'))
      @smtp_log_path = File.join(@safe_dir, '.smtp.log')
    end
    
    # Send an email message
    # @param mail [Mail::Message] The mail object to send
    # @param recipients [String, Array] Recipient email addresses
    # @return [Hash] Result with :success and :message keys
    def send(mail, recipients = nil)
      # Extract recipients from mail object if not provided
      recipients ||= extract_recipients(mail)
      
      # Determine sending method based on from address
      if uses_oauth2?
        send_via_gmail_smtp(mail, recipients)
      elsif config['smtp_server']
        send_via_smtp_server(mail, recipients)
      else
        { success: false, message: "No SMTP configuration available for #{from_address}" }
      end
    end
    
    # Check if this address uses OAuth2 via gmail_smtp
    def uses_oauth2?
      return false unless from_address
      
      domain = from_address.split('@').last
      @oauth2_domains.include?(domain)
    end
    
    # Class method for quick sending
    def self.send_message(from, to, subject, body, in_reply_to = nil, config = {})
      require 'mail'
      
      mail = Mail.new do
        from     from
        to       to
        subject  subject
        body     body
      end
      
      # Add threading headers if replying
      if in_reply_to
        mail['In-Reply-To'] = in_reply_to
        mail['References'] = in_reply_to
      end
      
      sender = new(from, config)
      sender.send(mail)
    end
    
    private
    
    # Send using integrated OAuth2 module
    def send_via_gmail_smtp(mail, recipients)
      require_relative 'oauth2_smtp'
      
      # Use the integrated OAuth2 SMTP module
      oauth2 = Heathrow::OAuth2Smtp.new(from_address)
      result = oauth2.send(mail, recipients)
      
      # Add fallback to external script if integrated module fails
      if !result[:success] && File.exist?(@smtp_command)
        send_via_external_script(mail, recipients)
      else
        result
      end
    end
    
    # Fallback to external gmail_smtp script
    def send_via_external_script(mail, recipients)
      begin
        tempfile = Tempfile.new(['heathrow-mail', '.eml'])
        tempfile.write(mail.to_s)
        tempfile.flush
        
        recipient_list = Array(recipients).map(&:strip).join(' ')
        cmd = "#{@smtp_command} -f #{Shellwords.escape(from_address)} -i #{recipient_list}"
        
        success = system("#{cmd} < #{Shellwords.escape(tempfile.path)}")
        
        if success
          { success: true, message: "Message sent via OAuth2 (external script)" }
        else
          error_msg = read_smtp_log_error
          { success: false, message: "Send failed: #{error_msg}" }
        end
        
      rescue => e
        { success: false, message: "Error sending: #{e.message}" }
      ensure
        tempfile&.close
        tempfile&.unlink
      end
    end
    
    # Send using configured SMTP server
    def send_via_smtp_server(mail, recipients)
      require 'net/smtp'
      
      begin
        smtp_config = config['smtp_server'] ? config : default_smtp_config
        
        smtp = Net::SMTP.new(
          smtp_config['smtp_server'],
          smtp_config['smtp_port'] || 587
        )
        
        # Enable TLS for secure ports
        if smtp_config['smtp_port'] != 25
          smtp.enable_starttls
        end
        
        # Authenticate and send
        bare_from = from_address[/<([^>]+)>/, 1] || from_address.strip
        bare_recipients = Array(recipients).map { |r| r[/<([^>]+)>/, 1] || r.strip }

        smtp.start(
          smtp_config['smtp_server'],
          smtp_config['smtp_username'] || bare_from,
          smtp_config['smtp_password'],
          :plain
        ) do |smtp_conn|
          smtp_conn.send_message(
            mail.to_s,
            bare_from,
            bare_recipients
          )
        end
        
        { success: true, message: "Message sent via SMTP server" }
        
      rescue => e
        { success: false, message: "SMTP send failed: #{e.message}" }
      end
    end
    
    # Extract recipients from mail object
    def extract_recipients(mail)
      recipients = []
      recipients += Array(mail.to) if mail.to
      recipients += Array(mail.cc) if mail.cc
      recipients += Array(mail.bcc) if mail.bcc
      recipients.map(&:to_s).uniq
    end
    
    # Read last error from SMTP log
    def read_smtp_log_error
      return "Unknown error" unless File.exist?(@smtp_log_path)
      
      # Get last 5 lines from log
      lines = File.readlines(@smtp_log_path).last(5)
      
      # Look for error indicators
      error_lines = lines.select { |l| l =~ /error|fail|denied|invalid/i }
      
      if error_lines.any?
        error_lines.join(' ').strip
      else
        lines.join(' ').strip
      end
    rescue
      "Could not read SMTP log"
    end
    
    # Default SMTP configuration for common providers
    def default_smtp_config
      case from_address
      when /@gmail\.com$/
        {
          'smtp_server' => 'smtp.gmail.com',
          'smtp_port' => 587,
          'smtp_username' => from_address
        }
      when /@(outlook|hotmail|live)\.com$/
        {
          'smtp_server' => 'smtp-mail.outlook.com',
          'smtp_port' => 587,
          'smtp_username' => from_address
        }
      else
        {}
      end
    end
  end
end