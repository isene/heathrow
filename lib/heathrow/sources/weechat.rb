#!/usr/bin/env ruby
# frozen_string_literal: true

# WeeChat source via Relay protocol (binary)
# Connects to a running WeeChat instance's relay to read IRC/Slack buffers

require 'socket'
require 'digest'
require 'json'
require 'time'
require 'zlib'
require_relative 'base'

module Heathrow
  module Sources
    class Weechat < Base
      CONFIG_DIR = File.join(Dir.home, '.heathrow', 'cookies')
      CONFIG_FILE = File.join(CONFIG_DIR, 'weechat.json')

      def initialize(name_or_source, config = nil, db = nil)
        if name_or_source.is_a?(Hash)
          source = name_or_source
          config = source['config']
          config = JSON.parse(config) if config.is_a?(String)
          super(source['name'] || 'WeeChat', config, db)
        else
          super(name_or_source, config, db)
        end
        @host = config['host'] || 'localhost'
        @port = (config['port'] || 8001).to_i
        @password = config['password'] || ''
        @buffer_filter = config['buffer_filter'] # e.g., 'irc.*,python.slack.*'
        @lines_per_buffer = (config['lines_per_buffer'] || 50).to_i
      end

      def sync(source_id)
        sock = connect_and_auth
        return 0 unless sock

        count = 0
        begin
          # Request buffer list
          sock.write("(listbuffers) hdata buffer:gui_buffers(*) number,full_name,short_name,title,type,local_variables\n")
          buffers_msg = read_and_parse(sock)
          buffer_list = extract_hdata(buffers_msg)
          return 0 if buffer_list.empty?

          buffer_list.each do |buf|
            full_name = buf['full_name'].to_s
            # Skip non-message buffers
            next if full_name == 'core.weechat'
            next if full_name =~ /^(relay\.|fset\.|script\.|irc\.server\.)/

            # Apply buffer filter
            if @buffer_filter
              patterns = @buffer_filter.split(',').map(&:strip)
              next unless patterns.any? { |p| File.fnmatch(p, full_name) }
            end

            ptr = buf['__path']&.first
            next unless ptr

            # Fetch recent lines (hdata path: buffer:PTR/own_lines/last_line/data)
            sock.write("(lines_#{ptr}) hdata buffer:#{ptr}/own_lines/last_line(-#{@lines_per_buffer})/data date,prefix,message,tags_array,displayed,highlight,notify_level\n")
            lines_msg = read_and_parse(sock)
            next unless lines_msg

            lines = extract_hdata(lines_msg)
            lines.each do |line|
              next unless line['displayed'].to_i == 1
              count += process_line(source_id, buf, line)
            end
          end
        ensure
          sock.write("quit\n") rescue nil
          sock.close rescue nil
        end

        count
      rescue Errno::ECONNREFUSED
        STDERR.puts "WeeChat relay not available at #{@host}:#{@port}" if ENV['DEBUG']
        0
      rescue => e
        STDERR.puts "WeeChat error: #{e.message}" if ENV['DEBUG']
        STDERR.puts e.backtrace.first(3).join("\n") if ENV['DEBUG']
        0
      end

      def fetch
        return [] unless enabled?
        source = @db.get_source_by_name(@name)
        return [] unless source
        sync(source['id'])
        update_last_fetch
        []
      end

      def test_connection
        sock = connect_and_auth
        return { success: false, message: "Auth failed at #{@host}:#{@port}" } unless sock

        sock.write("(version) info version\n")
        msg = read_and_parse(sock)
        version = extract_info(msg)

        sock.write("(buflist) hdata buffer:gui_buffers(*) full_name\n")
        buf_msg = read_and_parse(sock)
        buffers = extract_hdata(buf_msg)

        sock.write("quit\n") rescue nil
        sock.close rescue nil

        { success: true, message: "WeeChat #{version} - #{buffers.size} buffers" }
      rescue Errno::ECONNREFUSED
        { success: false, message: "Cannot connect to #{@host}:#{@port}" }
      rescue => e
        { success: false, message: "Error: #{e.message}" }
      end

      # Send a message to a buffer via the relay
      def send_to_buffer(buffer_name, text)
        sock = connect_and_auth
        return { success: false, message: "Auth failed" } unless sock

        sock.write("input #{buffer_name} #{text}\n")
        sock.write("quit\n") rescue nil
        sock.close rescue nil

        { success: true, message: "Sent to #{buffer_name}" }
      rescue => e
        { success: false, message: "Send failed: #{e.message}" }
      end

      # Standard send_message interface (used by send_composed_message)
      def send_message(to, subject, body)
        send_to_buffer(to, body)
      end

      private

      def connect_and_auth
        sock = TCPSocket.new(@host, @port)
        sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

        # Plain password auth (relay should be behind SSH tunnel or trusted network)
        sock.write("init password=#{@password},compression=off\n")

        # Verify auth with a ping
        sock.write("(auth_check) ping auth\n")
        response = read_and_parse(sock)
        response ? sock : (sock.close; nil)
      rescue => e
        STDERR.puts "WeeChat connect error: #{e.message}" if ENV['DEBUG']
        nil
      end

      # ── Binary protocol reader ──

      def read_message(sock)
        len_bytes = read_exact(sock, 4)
        return nil unless len_bytes

        length = len_bytes.unpack1('N')
        return nil if length < 5 || length > 10_000_000

        data = read_exact(sock, length - 4)
        return nil unless data

        compression = data[0].unpack1('C')
        payload = data[1..]

        if compression == 1
          payload = Zlib::Inflate.inflate(payload)
        end

        payload
      end

      def read_exact(sock, n)
        buf = String.new(encoding: 'ASCII-8BIT')
        while buf.size < n
          chunk = sock.read(n - buf.size)
          return nil unless chunk && !chunk.empty?
          buf << chunk
        end
        buf
      end

      def read_and_parse(sock)
        payload = read_message(sock)
        return nil unless payload
        parse_message(payload)
      rescue => e
        STDERR.puts "WeeChat parse error: #{e.message}" if ENV['DEBUG']
        nil
      end

      # ── Binary protocol parser ──

      def parse_message(data)
        pos = 0
        msg = {}
        msg[:id], pos = read_str(data, pos)
        msg[:objects] = []

        while pos < data.size - 2
          type = data[pos, 3]
          break unless type && type.size == 3
          pos += 3
          obj, pos = read_object(data, pos, type)
          msg[:objects] << { type: type, value: obj }
        end

        msg
      end

      def read_object(data, pos, type)
        case type
        when 'chr' then [data[pos].unpack1('c'), pos + 1]
        when 'int' then read_int(data, pos)
        when 'lon' then read_length_prefixed_ascii(data, pos)
        when 'str', 'buf' then read_str(data, pos)
        when 'ptr' then read_ptr(data, pos)
        when 'tim' then read_length_prefixed_ascii(data, pos)
        when 'htb' then read_hashtable(data, pos)
        when 'hda' then read_hdata(data, pos)
        when 'inf' then read_info(data, pos)
        when 'inl' then read_infolist(data, pos)
        when 'arr' then read_array(data, pos)
        else [nil, data.size]
        end
      end

      def read_int(data, pos)
        val = data[pos, 4].unpack1('N')
        val = val - 0x100000000 if val > 0x7FFFFFFF
        [val, pos + 4]
      end

      def read_str(data, pos)
        return [nil, pos + 4] if data.size < pos + 4
        len = data[pos, 4].unpack1('N')
        pos += 4
        return [nil, pos] if len >= 0xFFFFFFF0  # NULL
        return ['', pos] if len == 0
        str = data[pos, len]
        str = str.force_encoding('UTF-8') rescue str
        [str, pos + len]
      end

      def read_ptr(data, pos)
        len = data[pos].unpack1('C')
        pos += 1
        ["0x#{data[pos, len]}", pos + len]
      end

      def read_length_prefixed_ascii(data, pos)
        len = data[pos].unpack1('C')
        pos += 1
        [data[pos, len].to_i, pos + len]
      end

      def read_hashtable(data, pos)
        key_type = data[pos, 3]; pos += 3
        val_type = data[pos, 3]; pos += 3
        count, pos = read_int(data, pos)

        hash = {}
        count.times do
          key, pos = read_object(data, pos, key_type)
          val, pos = read_object(data, pos, val_type)
          hash[key.to_s] = val
        end
        [hash, pos]
      end

      def read_hdata(data, pos)
        path, pos = read_str(data, pos)
        keys_str, pos = read_str(data, pos)
        count, pos = read_int(data, pos)

        path_parts = (path || '').split('/')
        keys = (keys_str || '').split(',').map { |k| k.split(':', 2) }

        items = []
        count.times do
          item = {}
          ptrs = []
          path_parts.size.times do
            ptr, pos = read_object(data, pos, 'ptr')
            ptrs << ptr
          end
          item['__path'] = ptrs

          keys.each do |name, ktype|
            val, pos = read_object(data, pos, ktype)
            item[name] = val
          end
          items << item
        end

        [items, pos]
      end

      def read_info(data, pos)
        name, pos = read_str(data, pos)
        value, pos = read_str(data, pos)
        [{ name: name, value: value }, pos]
      end

      def read_infolist(data, pos)
        name, pos = read_str(data, pos)
        count, pos = read_int(data, pos)

        items = []
        count.times do
          var_count, pos = read_int(data, pos)
          item = {}
          var_count.times do
            var_name, pos = read_str(data, pos)
            var_type = data[pos, 3]; pos += 3
            var_val, pos = read_object(data, pos, var_type)
            item[var_name.to_s] = var_val
          end
          items << item
        end
        [{ name: name, items: items }, pos]
      end

      def read_array(data, pos)
        elem_type = data[pos, 3]; pos += 3
        count, pos = read_int(data, pos)

        arr = []
        count.times do
          val, pos = read_object(data, pos, elem_type)
          arr << val
        end
        [arr, pos]
      end

      # ── Helpers ──

      def extract_hdata(msg)
        return [] unless msg && msg[:objects]
        msg[:objects].each do |obj|
          return obj[:value] if obj[:type] == 'hda' && obj[:value].is_a?(Array)
        end
        []
      end

      def extract_info(msg)
        return nil unless msg && msg[:objects]
        msg[:objects].each do |obj|
          return obj[:value][:value] if obj[:type] == 'inf' && obj[:value].is_a?(Hash)
        end
        nil
      end

      # Strip WeeChat color codes from text
      # Format: \x19 followed by color type char and color value, terminated by \x1C or next \x19
      # Color types: F=foreground, B=background, *=bold, etc.
      # Color values: NN (2-digit) or @NNNNN (extended 5-digit)
      def strip_colors(text)
        return '' unless text
        # Remove \x19 + type char + optional @ + digits (color sequences)
        text.gsub(/\x19[FB*_\/|][~@]?\d{0,5}/, '')
            .gsub(/\x19\x1C/, '')  # reset sequence
            .gsub(/\x19[^\x19\x1C]*/, '')  # catch remaining color codes
            .gsub(/[\x00-\x1f]/, '')  # strip all remaining control chars
      end

      def buffer_type(buf)
        full_name = buf['full_name'].to_s
        local_vars = buf['local_variables']
        local_vars = {} unless local_vars.is_a?(Hash)
        type = local_vars['type'] || ''

        if full_name.start_with?('irc.')
          type == 'private' ? :irc_dm : :irc_channel
        elsif full_name =~ /^python\.slack\./
          if type == 'private'
            :slack_dm
          elsif full_name =~ /&/
            :slack_group
          else
            :slack_channel
          end
        else
          :other
        end
      end

      def process_line(source_id, buf, line)
        prefix = strip_colors(line['prefix'] || '')
        message = strip_colors(line['message'] || '')
        timestamp = line['date'].to_i
        tags = line['tags_array'] || []

        # Skip system messages (joins, parts, quits, mode changes)
        return 0 if tags.any? { |t| t =~ /irc_join|irc_part|irc_quit|irc_nick|irc_mode|irc_numeric/ }
        return 0 if tags.include?('no_log')
        # Must have a nick tag (real messages) or a non-empty prefix
        return 0 unless tags.any? { |t| t.start_with?('nick_') } || prefix =~ /\w/
        return 0 if message.strip.empty?

        nick = tags.find { |t| t.start_with?('nick_') }&.sub('nick_', '') || prefix
        full_name = buf['full_name'].to_s
        short_name = buf['short_name'] || full_name.split('.').last

        ext_id = "weechat_#{Digest::MD5.hexdigest("#{full_name}_#{timestamp}_#{nick}_#{message[0..80]}")}"

        btype = buffer_type(buf)
        is_dm = (btype == :irc_dm || btype == :slack_dm)

        platform = case btype
                   when :irc_dm, :irc_channel then 'IRC'
                   when :slack_dm, :slack_channel, :slack_group then 'Slack'
                   else 'WeeChat'
                   end

        channel_name = case btype
                       when :irc_channel
                         net = full_name.split('.')[1] || 'irc'
                         "#{net}/#{short_name}"
                       when :irc_dm
                         nick
                       when :slack_channel, :slack_group
                         parts = full_name.split('.')
                         ws = parts[2] || 'slack'
                         chan = parts[3..].join('.') rescue short_name
                         "#{ws}/#{chan}"
                       when :slack_dm
                         parts = full_name.split('.')
                         parts[3..].join('.') rescue nick
                       else
                         short_name
                       end

        data = {
          source_id: source_id,
          external_id: ext_id,
          sender: nick,
          sender_name: nick,
          recipients: [channel_name],
          subject: message.gsub(/\n/, ' ')[0..200],
          content: message,
          html_content: nil,
          timestamp: timestamp,
          received_at: Time.now.to_i,
          read: false,
          starred: false,
          archived: false,
          labels: [platform],
          attachments: nil,
          metadata: {
            buffer: full_name,
            buffer_short: short_name,
            buffer_type: btype.to_s,
            channel_name: channel_name,
            nick: nick,
            is_dm: is_dm,
            platform: platform.downcase,
            highlight: (line['highlight'].to_i == 1),
            tags: tags
          },
          raw_data: { buffer: full_name, nick: nick }
        }

        begin
          @db.insert_message(data)
          1
        rescue SQLite3::ConstraintException
          0
        end
      end
    end
  end
end
