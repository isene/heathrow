require 'digest'
require 'json'
require 'shellwords'
require 'time'
require_relative 'base'

module Heathrow
  module Sources
    class Instagram < Base
      COOKIE_DIR = File.join(Dir.home, '.heathrow', 'cookies')
      COOKIE_FILE = File.join(COOKIE_DIR, 'instagram.json')
      INBOX_URL = 'https://www.instagram.com/api/v1/direct_v2/inbox/'
      APP_ID = '936619743392459'

      REQUIRED_COOKIES = %w[sessionid csrftoken]
      OPTIONAL_COOKIES = %w[ds_user_id ig_did mid]

      def initialize(name, config, db)
        super
        @cookies = config['cookies'] || load_cookies
      end

      def sync(source_id)
        return 0 unless valid_cookies?

        begin
          inbox = fetch_inbox
          return 0 unless inbox

          count = 0
          threads = inbox['inbox']&.dig('threads') || []
          threads.each do |thread|
            count += process_thread(source_id, thread)
          end
          count
        rescue SessionExpiredError => e
          STDERR.puts "Instagram session expired: #{e.message}" if ENV['DEBUG']
          save_session_error("Session expired. Please refresh cookies.")
          0
        rescue => e
          STDERR.puts "Instagram error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" if ENV['DEBUG']
          0
        end
      end

      def fetch
        return [] unless enabled?
        source = @db.get_source_by_name(@name)
        return [] unless source
        sync(source['id'])
        update_last_fetch
        []
      end

      def valid_cookies?
        return false unless @cookies.is_a?(Hash)
        REQUIRED_COOKIES.all? { |k| @cookies[k] && !@cookies[k].empty? }
      end

      def save_cookies(cookies = nil)
        cookies ||= @cookies
        Dir.mkdir(COOKIE_DIR) unless Dir.exist?(COOKIE_DIR)
        File.write(COOKIE_FILE, cookies.to_json)
        File.chmod(0600, COOKIE_FILE)
        @cookies = cookies
      end

      SEND_SCRIPT = File.join(__dir__, 'instagram_send_marionette.py')

      def send_message(thread_id, _subject, body)
        return { success: false, message: "No thread ID" } unless thread_id
        return { success: false, message: "Empty message" } if body.nil? || body.strip.empty?

        result = `python3 #{Shellwords.escape(SEND_SCRIPT)} #{Shellwords.escape(thread_id)} #{Shellwords.escape(body.strip)} 2>/dev/null`

        data = JSON.parse(result) rescue nil
        if data
          data.transform_keys!(&:to_sym)
          data
        else
          { success: false, message: "Instagram send: no response from script" }
        end
      rescue => e
        { success: false, message: "Instagram send error: #{e.message}" }
      end

      private

      class SessionExpiredError < StandardError; end

      def load_cookies
        return {} unless File.exist?(COOKIE_FILE)
        JSON.parse(File.read(COOKIE_FILE))
      rescue
        {}
      end

      def cookie_header
        @cookies.map { |k, v| "#{k}=#{v}" }.join('; ')
      end

      def csrf_token
        @cookies['csrftoken'] || ''
      end

      FETCH_SCRIPT = File.join(__dir__, 'instagram_fetch.py')

      def fetch_inbox
        # Use Marionette (real Firefox tab) since Meta blocks API calls from non-browsers
        result = `python3 #{Shellwords.escape(FETCH_SCRIPT)} 2>/dev/null`

        return nil if result.nil? || result.strip.empty?

        begin
          data = JSON.parse(result)
          if data['error']
            STDERR.puts "Instagram fetch error: #{data['error']}" if ENV['DEBUG']
            return nil
          end
          if data['status'] != 'ok'
            raise SessionExpiredError, "API returned status: #{data['status']}"
          end
          data
        rescue JSON::ParserError => e
          STDERR.puts "Instagram JSON parse error: #{e.message}" if ENV['DEBUG']
          nil
        end
      end

      def process_thread(source_id, thread)
        return 0 unless thread

        thread_id = thread['thread_id']
        return 0 unless thread_id

        # Get thread participants
        users = thread['users'] || []
        other_users = users.map { |u| u['full_name'].to_s.empty? ? u['username'] : u['full_name'] }
        thread_title = thread['thread_title']
        thread_title = other_users.join(', ') if thread_title.nil? || thread_title.empty?
        thread_title = 'Unknown' if thread_title.empty?

        items = thread['items'] || []
        return 0 if items.empty?

        count = 0
        items.each do |item|
          next unless item

          content = extract_message_content(item)
          timestamp = (item['timestamp'].to_i / 1_000_000) rescue Time.now.to_i

          ext_id = "ig_#{thread_id}_#{item['item_id']}"

          # Determine sender
          sender_id = item['user_id'].to_s
          sender = users.find { |u| u['pk'].to_s == sender_id }
          sender_name = if sender
                          sender['full_name'].to_s.empty? ? sender['username'] : sender['full_name']
                        else
                          thread_title
                        end

          attachments = extract_attachments(item)

          data = {
            source_id: source_id,
            external_id: ext_id,
            thread_id: thread_id,
            sender: sender_name,
            sender_name: sender_name,
            recipients: [thread_title],
            subject: thread_title,
            content: content,
            html_content: nil,
            timestamp: timestamp,
            received_at: Time.now.to_i,
            read: item == items.first ? false : true,
            starred: false,
            archived: false,
            labels: ['Instagram'],
            attachments: attachments.empty? ? nil : attachments,
            metadata: {
              thread_id: thread_id,
              item_id: item['item_id'],
              participants: other_users,
              is_group: thread['is_group'],
              platform: 'instagram'
            },
            raw_data: { thread_id: thread_id, sender: sender_name }
          }

          begin
            @db.insert_message(data)
            count += 1
          rescue SQLite3::ConstraintException
            # Already exists
          end
        end
        count
      end

      def extract_message_content(item)
        case item['item_type']
        when 'text'
          item['text'] || ''
        when 'media', 'media_share'
          media = item['media'] || item['media_share'] || {}
          caption = media.dig('caption', 'text') || ''
          "[Media] #{caption}".strip
        when 'raven_media'
          '[Disappearing photo/video]'
        when 'voice_media'
          '[Voice message]'
        when 'animated_media'
          '[GIF]'
        when 'clip'
          clip = item['clip'] || {}
          caption = clip.dig('clip', 'caption', 'text') || ''
          "[Reel] #{caption}".strip
        when 'story_share'
          story = item['story_share'] || {}
          "[Shared story] #{story['title'] || ''}".strip
        when 'link'
          link = item['link'] || {}
          text = link['text'] || ''
          url = link.dig('link_context', 'link_url') || ''
          "#{text} #{url}".strip
        when 'like'
          '❤️'
        when 'reel_share'
          reel = item['reel_share'] || {}
          "[Reel share] #{reel['text'] || ''}".strip
        when 'xma'
          '[Shared content]'
        else
          item['text'] || "[#{item['item_type'] || 'unknown'}]"
        end
      end

      def extract_attachments(item)
        attachments = []
        case item['item_type']
        when 'media', 'media_share'
          media = item['media'] || item['media_share'] || {}
          url = best_image_url(media)
          if url
            attachments << { 'url' => url, 'content_type' => media_type(media), 'name' => 'image.jpg' }
          end
        when 'raven_media'
          media = item.dig('visual_media', 'media') || {}
          url = best_image_url(media)
          if url
            attachments << { 'url' => url, 'content_type' => media_type(media), 'name' => 'disappearing.jpg' }
          end
        when 'animated_media'
          images = item.dig('animated_media', 'images') || {}
          url = images.dig('fixed_height', 'url') || images.values.first&.dig('url')
          if url
            attachments << { 'url' => url, 'content_type' => 'image/gif', 'name' => 'animation.gif' }
          end
        when 'clip'
          media = item.dig('clip', 'clip') || {}
          url = best_image_url(media)
          if url
            attachments << { 'url' => url, 'content_type' => 'image/jpeg', 'name' => 'reel_thumbnail.jpg' }
          end
        when 'story_share'
          media = item.dig('story_share', 'media') || {}
          url = best_image_url(media)
          if url
            attachments << { 'url' => url, 'content_type' => 'image/jpeg', 'name' => 'story.jpg' }
          end
        when 'xma'
          # Shared content may have preview images
          xma = (item['xma'] || []).first || {}
          url = xma.dig('preview_url_info', 'url') || xma['header_icon_url']
          if url
            attachments << { 'url' => url, 'content_type' => 'image/jpeg', 'name' => 'shared.jpg' }
          end
        end
        attachments
      end

      def best_image_url(media)
        # Try candidates: highest quality first
        candidates = media.dig('image_versions2', 'candidates') || []
        best = candidates.max_by { |c| (c['width'] || 0) * (c['height'] || 0) }
        best&.dig('url')
      end

      def media_type(media)
        case media['media_type']
        when 1 then 'image/jpeg'
        when 2 then 'video/mp4'
        else 'image/jpeg'
        end
      end

      def save_session_error(message)
        error_file = File.join(COOKIE_DIR, 'instagram_error.txt')
        Dir.mkdir(COOKIE_DIR) unless Dir.exist?(COOKIE_DIR)
        File.write(error_file, "#{Time.now.iso8601}: #{message}\n", mode: 'a')
      end
    end
  end
end
