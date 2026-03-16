#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../sources/slack'

module Heathrow
  module Wizards
    # Setup wizard for Slack integration
    class SlackWizard
      def self.run
        puts "\n=== Slack Setup Wizard ==="
        puts "This will help you configure Slack integration for Heathrow.\n\n"
        
        puts "You'll need a Slack API token. You can get one by:"
        puts "1. Creating a Slack App at https://api.slack.com/apps"
        puts "2. Installing it to your workspace"
        puts "3. Getting a User OAuth Token (xoxp-...) or Bot Token (xoxb-...)"
        puts "\nFor full access to all channels and DMs, use a User Token."
        puts "For limited bot access, use a Bot Token.\n\n"
        
        config = {}
        
        # Get API token
        print "Enter your Slack API token (xoxp-... or xoxb-...): "
        config['api_token'] = gets.chomp
        
        # Test the token
        print "\nTesting connection..."
        test_source = Heathrow::Sources::Slack.new(config)
        
        unless test_source.test_connection
          puts "\nFailed to connect. Please check your token and try again."
          return nil
        end
        
        puts " Success!\n\n"
        
        # Get workspace name (optional)
        print "Enter a name for this workspace (optional, for display): "
        workspace = gets.chomp
        config['workspace'] = workspace unless workspace.empty?
        
        # Ask about channel configuration
        puts "\nChannel Configuration:"
        puts "1. Monitor all channels I have access to (default)"
        puts "2. Monitor specific channels only"
        print "Choose option [1]: "
        
        choice = gets.chomp
        choice = '1' if choice.empty?
        
        if choice == '2'
          puts "\nEnter channel IDs to monitor (one per line, empty line to finish):"
          puts "Example: C1234567890"
          puts "You can find channel IDs in Slack by right-clicking a channel."
          
          channels = []
          loop do
            print "> "
            channel = gets.chomp
            break if channel.empty?
            channels << channel
          end
          config['channel_ids'] = channels unless channels.empty?
        end
        
        # Ask about DM configuration
        puts "\nDirect Message Configuration:"
        puts "1. Monitor all DMs (default)"
        puts "2. Monitor specific users only"
        print "Choose option [1]: "
        
        choice = gets.chomp
        choice = '1' if choice.empty?
        
        if choice == '2'
          puts "\nEnter user IDs to monitor DMs with (one per line, empty line to finish):"
          puts "Example: U1234567890"
          
          users = []
          loop do
            print "> "
            user = gets.chomp
            break if user.empty?
            users << user
          end
          config['dm_user_ids'] = users unless users.empty?
        end
        
        # Ask about fetch interval
        print "\nHow often to fetch messages (in seconds) [300]: "
        interval = gets.chomp
        config['fetch_interval'] = interval.empty? ? 300 : interval.to_i
        
        # Save configuration
        source_name = workspace.empty? ? 'slack' : "slack_#{workspace.downcase.gsub(/\s+/, '_')}"
        config_file = File.join(Dir.home, '.config', 'heathrow', 'sources', "#{source_name}.json")
        
        # Create directory if it doesn't exist
        FileUtils.mkdir_p(File.dirname(config_file))
        
        # Write config
        File.write(config_file, JSON.pretty_generate(config))
        
        puts "\n✓ Slack configuration saved to: #{config_file}"
        puts "\nYou can now use this source in Heathrow!"
        puts "The source will appear as: #{source_name}"
        
        config
      end
      
      def self.run_oauth_flow
        puts "\n=== Slack OAuth Setup (Alternative) ==="
        puts "This method uses OAuth authentication flow.\n\n"
        
        puts "1. Go to: https://api.slack.com/apps"
        puts "2. Create a new app or select existing"
        puts "3. Add these OAuth scopes:"
        puts "   - channels:history"
        puts "   - channels:read"
        puts "   - groups:history"
        puts "   - groups:read"
        puts "   - im:history"
        puts "   - im:read"
        puts "   - mpim:history"
        puts "   - mpim:read"
        puts "   - users:read"
        puts "   - chat:write"
        puts "4. Install the app to your workspace"
        puts "5. Copy the User OAuth Token\n\n"
        
        print "Press Enter when ready to continue..."
        gets
        
        run
      end
    end
  end
end