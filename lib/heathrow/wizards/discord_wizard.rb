#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'io/console'

module Heathrow
  module Wizards
    class DiscordWizard
      def self.run(source = nil)
        new(source).run
      end
      
      def initialize(source = nil)
        @source = source
        @config = source ? source.config : {}
      end
      
      def run
        puts "\n=== Discord Configuration Wizard ==="
        puts
        
        # Get token
        token = get_token
        return nil unless token
        
        # Test token
        is_bot = test_token(token)
        return nil unless is_bot
        
        @config['token'] = token
        @config['is_bot'] = is_bot
        
        # Discover servers and channels
        puts "\nDiscovering servers and channels..."
        discover_and_select_channels(token, is_bot)
        
        # Set other options
        @config['fetch_limit'] ||= 50
        @config['polling_interval'] ||= 300
        
        puts "\n=== Configuration Complete ==="
        puts "Token: #{token[0..20]}..."
        puts "Bot account: #{is_bot ? 'Yes' : 'No'}"
        puts "Channels: #{@config['channels'].split(',').length} selected" if @config['channels']
        puts "Guilds: #{@config['guilds'].split(',').length} selected" if @config['guilds'] && !@config['guilds'].empty?
        
        @config
      end
      
      private
      
      def get_token
        puts "Discord Token Setup"
        puts "-" * 40
        puts "You can use either:"
        puts "  1. Bot token (recommended) - Create at https://discord.com/developers/applications"
        puts "  2. User token (against ToS) - Found in browser DevTools"
        puts
        
        existing = @config['token']
        if existing
          print "Current token: #{existing[0..20]}...\nKeep this token? (Y/n): "
          keep = gets.chomp.downcase
          return existing unless keep == 'n'
        end
        
        print "Enter Discord token: "
        token = gets.chomp.strip
        
        if token.empty?
          puts "Error: Token cannot be empty"
          return nil
        end
        
        token
      end
      
      def test_token(token)
        # Try as bot token first
        uri = URI("https://discord.com/api/v10/users/@me")
        
        [true, false].each do |is_bot|
          request = Net::HTTP::Get.new(uri)
          request['Authorization'] = is_bot ? "Bot #{token}" : token
          
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
          
          if response.is_a?(Net::HTTPSuccess)
            user_data = JSON.parse(response.body)
            puts "✓ Connected as: #{user_data['username']}##{user_data['discriminator']}"
            puts "  Account type: #{is_bot ? 'Bot' : 'User'}"
            return is_bot
          end
        end
        
        puts "✗ Failed to authenticate with Discord"
        false
      end
      
      def discover_and_select_channels(token, is_bot)
        # Get user's guilds
        uri = URI("https://discord.com/api/v10/users/@me/guilds")
        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = is_bot ? "Bot #{token}" : token
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        
        unless response.is_a?(Net::HTTPSuccess)
          puts "Could not fetch guilds. You can manually add channel IDs later."
          return
        end
        
        guilds = JSON.parse(response.body)
        puts "\nFound #{guilds.length} servers:"
        
        # Show guilds and their channels
        selected_channels = []
        selected_guilds = []
        
        guilds.each_with_index do |guild, index|
          puts "\n#{index + 1}. #{guild['name']}"
          
          # Get channels for this guild
          channels_uri = URI("https://discord.com/api/v10/guilds/#{guild['id']}/channels")
          channels_request = Net::HTTP::Get.new(channels_uri)
          channels_request['Authorization'] = is_bot ? "Bot #{token}" : token
          
          channels_response = Net::HTTP.start(channels_uri.hostname, channels_uri.port, use_ssl: true) do |http|
            http.request(channels_request)
          end
          
          if channels_response.is_a?(Net::HTTPSuccess)
            channels = JSON.parse(channels_response.body)
            text_channels = channels.select { |c| c['type'] == 0 }  # Type 0 = text channel
            
            puts "   Channels:"
            text_channels.first(10).each do |channel|
              puts "    - ##{channel['name']} (ID: #{channel['id']})"
            end
            puts "    ... and #{text_channels.length - 10} more" if text_channels.length > 10
          else
            puts "   Could not fetch channels for this server"
          end
        end
        
        puts "\n" + "=" * 40
        puts "Channel Selection Options:"
        puts "  1. Select all channels from specific servers"
        puts "  2. Select individual channels (enter IDs)"
        puts "  3. Use existing configuration"
        puts "  4. Skip for now"
        print "\nChoice (1-4): "
        
        choice = gets.chomp
        
        case choice
        when '1'
          print "Enter server numbers (comma-separated, e.g., 1,3,5): "
          numbers = gets.chomp.split(',').map(&:strip)
          
          numbers.each do |num|
            idx = num.to_i - 1
            if idx >= 0 && idx < guilds.length
              selected_guilds << guilds[idx]['id']
              puts "  Added: #{guilds[idx]['name']}"
            end
          end
          
          @config['guilds'] = selected_guilds.join(',') unless selected_guilds.empty?
          
        when '2'
          puts "Enter channel IDs (comma-separated):"
          puts "Tip: Right-click channel in Discord > Copy ID"
          print "> "
          channels = gets.chomp
          @config['channels'] = channels unless channels.empty?
          
        when '3'
          puts "Keeping existing configuration"
          
        else
          puts "Skipping channel configuration"
        end
      end
    end
  end
end