#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'base64'
require 'time'

module Heathrow
  module Sources
    class Reddit
      attr_reader :source, :last_fetch_time
      
      def initialize(source)
        @source = source
        @config = source.config.is_a?(String) ? JSON.parse(source.config) : source.config
        @last_fetch_time = Time.now
        @access_token = nil
        @token_expires_at = nil
      end
      
      def fetch_messages
        messages = []
        
        begin
          # Get access token if needed
          ensure_access_token
          
          # Determine what to fetch based on mode
          mode = @config['mode'] || 'subreddit'
          
          case mode
          when 'subreddit'
            messages = fetch_subreddit_posts
          when 'messages'
            messages = fetch_private_messages
          else
            puts "Unknown Reddit mode: #{mode}" if ENV['DEBUG']
          end
          
        rescue => e
          puts "Reddit fetch error: #{e.message}" if ENV['DEBUG']
          puts e.backtrace.join("\n") if ENV['DEBUG']
        end
        
        messages
      end
      
      def test_connection
        begin
          ensure_access_token

          # Test basic API access
          data = make_api_request('/api/v1/me')

          if data
            if data['name']
              { success: true, message: "Connected as u/#{data['name']}" }
            else
              { success: true, message: "Connected with read-only access" }
            end
          else
            { success: false, message: "Failed to connect to Reddit API" }
          end
        rescue => e
          { success: false, message: "Connection test failed: #{e.message}" }
        end
      end

      def can_reply?
        # Can reply to PMs if we have username/password auth
        @config['username'] && @config['password']
      end

      def send_message(to, subject, body, in_reply_to = nil)
        unless can_reply?
          return { success: false, message: "Reddit requires username/password authentication to send messages" }
        end

        begin
          ensure_access_token

          if in_reply_to
            # Reply to an existing message or comment
            send_reply(in_reply_to, body)
          else
            # Send a new private message
            send_private_message(to, subject, body)
          end
        rescue => e
          { success: false, message: "Failed to send: #{e.message}" }
        end
      end

      private

      def send_private_message(to, subject, body)
        # Remove u/ prefix if present
        recipient = to.sub(/^u\//, '')

        uri = URI('https://oauth.reddit.com/api/compose')

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{@access_token}"
        request['User-Agent'] = @config['user_agent'] || 'Heathrow/1.0'
        request['Content-Type'] = 'application/x-www-form-urlencoded'

        request.set_form_data(
          'api_type' => 'json',
          'to' => recipient,
          'subject' => subject,
          'text' => body
        )

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)

          if data['json'] && data['json']['errors'] && !data['json']['errors'].empty?
            errors = data['json']['errors'].map { |e| e[1] }.join(', ')
            { success: false, message: "Reddit API error: #{errors}" }
          else
            { success: true, message: "Message sent to u/#{recipient}" }
          end
        else
          { success: false, message: "HTTP error: #{response.code} #{response.message}" }
        end
      end

      def send_reply(thing_id, body)
        # thing_id is the fullname of the thing to reply to (e.g., t1_xxx for comment, t4_xxx for PM)
        uri = URI('https://oauth.reddit.com/api/comment')

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{@access_token}"
        request['User-Agent'] = @config['user_agent'] || 'Heathrow/1.0'
        request['Content-Type'] = 'application/x-www-form-urlencoded'

        request.set_form_data(
          'api_type' => 'json',
          'thing_id' => thing_id,
          'text' => body
        )

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)

          if data['json'] && data['json']['errors'] && !data['json']['errors'].empty?
            errors = data['json']['errors'].map { |e| e[1] }.join(', ')
            { success: false, message: "Reddit API error: #{errors}" }
          else
            { success: true, message: "Reply sent" }
          end
        else
          { success: false, message: "HTTP error: #{response.code} #{response.message}" }
        end
      end
      
      def ensure_access_token
        # Check if we need a new token
        if @access_token.nil? || @token_expires_at.nil? || Time.now >= @token_expires_at
          get_access_token
        end
      end
      
      def get_access_token
        # Reddit OAuth2 token endpoint
        uri = URI('https://www.reddit.com/api/v1/access_token')
        
        # Prepare the request
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        request = Net::HTTP::Post.new(uri)
        
        # Basic auth with client_id:client_secret
        client_id = @config['client_id']
        client_secret = @config['client_secret']
        auth = Base64.strict_encode64("#{client_id}:#{client_secret}")
        request['Authorization'] = "Basic #{auth}"
        request['User-Agent'] = @config['user_agent'] || 'Heathrow/1.0'
        
        # Different grant types based on whether we have user credentials
        if @config['username'] && @config['password']
          # Script app with username/password
          request.set_form_data(
            'grant_type' => 'password',
            'username' => @config['username'],
            'password' => @config['password']
          )
        else
          # Read-only access
          request.set_form_data(
            'grant_type' => 'client_credentials'
          )
        end
        
        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          token_data = JSON.parse(response.body)
          @access_token = token_data['access_token']
          # Token expires in 'expires_in' seconds, refresh 5 minutes before
          @token_expires_at = Time.now + token_data['expires_in'] - 300
          puts "Got Reddit access token, expires at #{@token_expires_at}" if ENV['DEBUG']
        else
          raise "Failed to get Reddit access token: #{response.code} #{response.body}"
        end
      end
      
      def make_api_request(endpoint, params = {})
        uri = URI("https://oauth.reddit.com#{endpoint}")
        uri.query = URI.encode_www_form(params) unless params.empty?
        
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = "Bearer #{@access_token}"
        request['User-Agent'] = @config['user_agent'] || 'Heathrow/1.0'
        
        response = http.request(request)
        
        if response.is_a?(Net::HTTPSuccess)
          JSON.parse(response.body)
        else
          puts "Reddit API error: #{response.code} #{response.body}" if ENV['DEBUG']
          nil
        end
      end
      
      def fetch_subreddit_posts
        messages = []
        subreddits = @config['subreddits'] || 'programming'
        subreddits = subreddits.split(',').map(&:strip) if subreddits.is_a?(String)
        
        limit = @config['fetch_limit'] || 25
        include_comments = @config['include_comments'] || false
        
        subreddits.each do |subreddit|
          # Fetch hot posts from subreddit
          data = make_api_request("/r/#{subreddit}/hot", { limit: limit })
          
          next unless data && data['data'] && data['data']['children']
          
          data['data']['children'].each do |post_wrapper|
            post = post_wrapper['data']
            
            # Skip if we've seen this before (basic deduplication)
            external_id = "reddit_post_#{post['id']}"
            
            # Convert post to message format
            message = {
              source_id: @source.id,
              source_type: 'reddit',
              external_id: external_id,
              sender: post['author'] || '[deleted]',
              recipient: "r/#{subreddit}",
              subject: post['title'],
              content: format_post_content(post),
              raw_data: post.to_json,
              attachments: extract_attachments(post),
              timestamp: Time.at(post['created_utc']).iso8601,
              is_read: 0
            }
            
            messages << message
            
            # Optionally fetch top comments
            if include_comments && post['num_comments'] > 0
              fetch_post_comments(post['id'], subreddit, post['title'], limit: 5).each do |comment|
                messages << comment
              end
            end
          end
        end
        
        messages
      end
      
      def fetch_private_messages
        messages = []
        
        # Fetch inbox messages (requires authentication with username/password)
        unless @config['username'] && @config['password']
          puts "Reddit private messages require username/password authentication" if ENV['DEBUG']
          return messages
        end
        
        # Fetch unread messages
        data = make_api_request('/message/unread', { limit: 100 })
        
        if data && data['data'] && data['data']['children']
          data['data']['children'].each do |msg_wrapper|
            msg = msg_wrapper['data']
            
            external_id = "reddit_msg_#{msg['id']}"
            
            message = {
              source_id: @source.id,
              source_type: 'reddit',
              external_id: external_id,
              sender: msg['author'] || '[deleted]',
              recipient: @config['username'],
              subject: msg['subject'] || 'Reddit Message',
              content: msg['body'] || '',
              raw_data: msg.to_json,
              attachments: nil,
              timestamp: Time.at(msg['created_utc']).iso8601,
              is_read: msg['new'] ? 0 : 1
            }
            
            messages << message
          end
        end
        
        # Also fetch recent messages (not just unread)
        data = make_api_request('/message/inbox', { limit: 50 })
        
        if data && data['data'] && data['data']['children']
          data['data']['children'].each do |msg_wrapper|
            msg = msg_wrapper['data']
            
            external_id = "reddit_msg_#{msg['id']}"
            
            # Skip if we already have this message
            next if messages.any? { |m| m[:external_id] == external_id }
            
            message = {
              source_id: @source.id,
              source_type: 'reddit',
              external_id: external_id,
              sender: msg['author'] || '[deleted]',
              recipient: @config['username'],
              subject: msg['subject'] || 'Reddit Message',
              content: msg['body'] || '',
              raw_data: msg.to_json,
              attachments: nil,
              timestamp: Time.at(msg['created_utc']).iso8601,
              is_read: msg['new'] ? 0 : 1
            }
            
            messages << message
          end
        end
        
        messages
      end
      
      def fetch_post_comments(post_id, subreddit, post_title, limit: 5)
        comments = []
        
        # Fetch comments for a specific post
        data = make_api_request("/r/#{subreddit}/comments/#{post_id}", { limit: limit })
        
        return comments unless data && data.is_a?(Array) && data[1]
        
        # Comments are in the second element
        comment_data = data[1]
        
        if comment_data['data'] && comment_data['data']['children']
          comment_data['data']['children'].each do |comment_wrapper|
            next unless comment_wrapper['kind'] == 't1'  # t1 = comment
            
            comment = comment_wrapper['data']
            next unless comment['author']  # Skip deleted comments
            
            external_id = "reddit_comment_#{comment['id']}"
            
            message = {
              source_id: @source.id,
              source_type: 'reddit',
              external_id: external_id,
              sender: comment['author'],
              recipient: "r/#{subreddit}",
              subject: "Re: #{post_title[0..50]}",
              content: comment['body'] || '',
              raw_data: comment.to_json,
              attachments: nil,
              timestamp: Time.at(comment['created_utc']).iso8601,
              is_read: 0
            }
            
            comments << message
          end
        end
        
        comments
      end
      
      def format_post_content(post)
        content = []
        
        # Add self text if present
        if post['selftext'] && !post['selftext'].empty?
          content << post['selftext']
        end
        
        # Add URL if it's a link post
        if post['url'] && post['url'] != post['permalink']
          content << "\nLink: #{post['url']}"
        end
        
        # Add metadata
        content << "\nScore: #{post['score']} | Comments: #{post['num_comments']}"
        content << "Permalink: https://reddit.com#{post['permalink']}"
        
        # Add flair if present
        if post['link_flair_text']
          content << "Flair: #{post['link_flair_text']}"
        end
        
        content.join("\n")
      end
      
      def extract_attachments(post)
        attachments = []
        
        # Check for image/video content
        if post['url']
          url = post['url']
          
          # Direct image links
          if url =~ /\.(jpg|jpeg|png|gif|webp)$/i
            attachments << { type: 'image', url: url }
          end
          
          # Reddit gallery
          if post['is_gallery'] && post['media_metadata']
            post['media_metadata'].each do |_id, media|
              if media['s'] && media['s']['u']
                # Convert preview URL to full URL
                full_url = media['s']['u'].gsub('preview.redd.it', 'i.redd.it')
                                           .gsub(/\?.*$/, '')
                attachments << { type: 'image', url: full_url }
              end
            end
          end
          
          # Reddit video
          if post['is_video'] && post['media'] && post['media']['reddit_video']
            video_url = post['media']['reddit_video']['fallback_url']
            attachments << { type: 'video', url: video_url }
          end
        end
        
        attachments.empty? ? nil : attachments.to_json
      end
    end
  end
end