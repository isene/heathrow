require 'digest'
require 'shellwords'
require 'json'
require 'time'
require_relative 'base'

module Heathrow
  module Sources
    class Messenger < Base
      COOKIE_DIR = File.join(Dir.home, '.heathrow', 'cookies')
      COOKIE_FILE = File.join(COOKIE_DIR, 'messenger.json')
      FETCH_SCRIPT = File.join(__dir__, 'messenger_fetch_marionette.py')

      # Required cookies for authentication
      REQUIRED_COOKIES = %w[c_user xs]
      OPTIONAL_COOKIES = %w[datr fr]

      def initialize(name, config, db)
        super
        @cookies = config['cookies'] || load_cookies
      end

      def sync(source_id)
        return 0 unless valid_cookies?

        begin
          data = fetch_via_playwright
          return 0 unless data
          threads = data['threads'] || []
          return 0 if threads.empty?

          count = 0
          threads.each do |thread|
            count += process_thread(source_id, thread)
          end
          count
        rescue => e
          STDERR.puts "Messenger error: #{e.message}" if ENV['DEBUG']
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

      def self.extract_firefox_cookies
        profile_dirs = Dir.glob(File.join(Dir.home, '.mozilla', 'firefox', '*'))
        cookies_db = profile_dirs.map { |d| File.join(d, 'cookies.sqlite') }
                                  .find { |f| File.exist?(f) }
        return nil unless cookies_db

        tmp = "/tmp/heathrow_ff_cookies_#{$$}.sqlite"
        system("cp #{Shellwords.escape(cookies_db)} #{Shellwords.escape(tmp)} 2>/dev/null")
        return nil unless File.exist?(tmp)

        cookies = {}
        begin
          require 'sqlite3'
          db = SQLite3::Database.new(tmp)
          db.results_as_hash = true

          (REQUIRED_COOKIES + OPTIONAL_COOKIES).each do |name|
            row = db.get_first_row(
              "SELECT value FROM moz_cookies WHERE name = ? AND (host LIKE '%messenger.com' OR host LIKE '%facebook.com') ORDER BY expiry DESC LIMIT 1",
              [name]
            )
            cookies[name] = row['value'] if row
          end

          db.close
        ensure
          File.delete(tmp) if File.exist?(tmp)
        end

        cookies
      end

      def save_cookies(cookies = nil)
        cookies ||= @cookies
        Dir.mkdir(COOKIE_DIR) unless Dir.exist?(COOKIE_DIR)
        File.write(COOKIE_FILE, cookies.to_json)
        File.chmod(0600, COOKIE_FILE)
        @cookies = cookies
      end

      SEND_SCRIPT = File.join(__dir__, 'messenger_send.py')

      def send_message(thread_id, _subject, body)
        return { success: false, message: "No thread ID" } unless thread_id
        return { success: false, message: "Empty message" } if body.nil? || body.strip.empty?

        result = `python3 #{Shellwords.escape(SEND_SCRIPT)} #{Shellwords.escape(thread_id)} #{Shellwords.escape(body.strip)} 2>/dev/null`

        data = JSON.parse(result) rescue nil
        if data
          data.transform_keys!(&:to_sym)
          data
        else
          { success: false, message: "Messenger send: no response from script" }
        end
      rescue => e
        { success: false, message: "Messenger send error: #{e.message}" }
      end

      private

      def load_cookies
        return {} unless File.exist?(COOKIE_FILE)
        JSON.parse(File.read(COOKIE_FILE))
      rescue
        {}
      end

      def fetch_via_playwright
        # Use Marionette (real Firefox tab) since Meta blocks headless browsers
        result = `python3 #{Shellwords.escape(FETCH_SCRIPT)} 2>/dev/null`
        return nil if result.nil? || result.strip.empty?

        data = JSON.parse(result)
        if data['error']
          STDERR.puts "Messenger fetch error: #{data['error']}" if ENV['DEBUG']
          save_session_error(data['error']) if data['error'] == 'login_required'
          return nil
        end
        data
      rescue JSON::ParserError => e
        STDERR.puts "Messenger JSON parse error: #{e.message}" if ENV['DEBUG']
        nil
      end

      def process_thread(source_id, thread)
        return 0 unless thread['id'] && thread['id'].to_s.match?(/^\d+$/)

        thread_name = thread['name'] || 'Unknown'
        return 0 if thread_name.empty?

        messages = thread['messages'] || []

        # Fallback: old format with just a snippet
        if messages.empty?
          snippet = thread['snippet'] || ''
          snippet = '' if snippet =~ /^Messages and calls are secured|^End-to-end encrypted/i
          return 0 if snippet.empty? && !thread['unread']
          messages = [{ 'id' => "last_#{thread['id']}", 'sender' => thread_name,
                        'text' => snippet, 'timestamp' => Time.now.to_i }]
        end

        count = 0
        messages.each do |msg|
          text = msg['text'] || ''
          text = '' if text =~ /^Messages and calls are secured|^End-to-end encrypted/i
          next if text.empty?

          msg_id = msg['id'] || "#{thread['id']}_#{msg['timestamp']}"
          ext_id = "msng_#{thread['id']}_#{msg_id}"
          sender = msg['sender'] || thread_name
          timestamp = (msg['timestamp'] || Time.now.to_i).to_i

          data = {
            source_id: source_id,
            external_id: ext_id,
            thread_id: thread['id'].to_s,
            sender: sender,
            sender_name: sender,
            recipients: [thread_name],
            subject: thread_name,
            content: text,
            html_content: nil,
            timestamp: timestamp,
            received_at: Time.now.to_i,
            read: msg == messages.first && thread['unread'] ? false : true,
            starred: false,
            archived: false,
            labels: ['Messenger'],
            attachments: nil,
            metadata: {
              thread_id: thread['id'],
              message_id: msg_id,
              platform: 'messenger'
            },
            raw_data: { thread_id: thread['id'], name: thread_name }
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

      def save_session_error(message)
        error_file = File.join(COOKIE_DIR, 'messenger_error.txt')
        Dir.mkdir(COOKIE_DIR) unless Dir.exist?(COOKIE_DIR)
        File.write(error_file, "#{Time.now.iso8601}: #{message}\n", mode: 'a')
      end
    end
  end
end
