require 'mail'
require 'time'
require 'timeout'
require 'fileutils'
require_relative '../plugin/base'

module Heathrow
  module Sources
    # Maildir++ source - Read emails from local Maildir format directories
    #
    # Supports Maildir++ subfolder format where subfolders are dot-prefixed
    # directories (e.g., .Personal, .Work.Archive) each containing
    # their own cur/new/tmp structure.
    #
    # Configuration:
    #   {
    #     "maildir_path": "/home/user/Maildir",
    #     "max_age_days": 30,
    #     "include_folders": ["Geir", "AA"],    # Optional whitelist
    #     "exclude_folders": ["Trash", "Spam"]   # Optional blacklist
    #   }
    #
    class Maildir < Heathrow::Plugin::Base
      def initialize(source, logger: nil, event_bus: nil)
        super(source, logger: logger, event_bus: event_bus)
        @maildir_path = @config['maildir_path'] || File.join(Dir.home, 'Maildir')
        @max_age_days = @config['max_age_days']
        @include_folders = @config['include_folders']
        @exclude_folders = @config['exclude_folders']
        @capabilities = ['read', 'send']

        validate_maildir_path!
      end

      # Discover all Maildir++ folders
      def discover_folders
        folders = [{ name: 'INBOX', path: @maildir_path }]
        Dir.glob(File.join(@maildir_path, '.*')).sort.each do |dir|
          basename = File.basename(dir)
          next if basename == '.' || basename == '..'
          next unless File.directory?(dir)
          next unless File.directory?(File.join(dir, 'cur')) || File.directory?(File.join(dir, 'new'))
          folder_name = basename.sub(/^\./, '')
          folders << { name: folder_name, path: dir }
        end
        folders
      end

      # List all folder names
      def list_folders
        discover_folders.map { |f| f[:name] }
      end

      def fetch_messages
        messages = []
        folders = apply_folder_filters(discover_folders)

        log_info("Scanning #{folders.size} Maildir++ folders", path: @maildir_path)

        folders.each do |folder|
          ['cur', 'new'].each do |subdir|
            folder_path = File.join(folder[:path], subdir)
            next unless Dir.exist?(folder_path)

            Dir.glob(File.join(folder_path, '*')).each do |file_path|
              next if File.directory?(file_path)

              begin
                msg = parse_maildir_file(file_path, folder[:name])
                messages << msg if msg && (!@max_age_days || msg[:timestamp] > cutoff_time)
              rescue => e
                log_error("Error parsing Maildir file #{file_path}", e)
              end
            end
          end
        end

        log_info("Fetched #{messages.size} messages from #{folders.size} folders", path: @maildir_path)
        publish_event('maildir.fetched', count: messages.size, path: @maildir_path)

        messages
      end

      def setup_wizard
        [
          {
            key: 'maildir_path',
            prompt: 'Enter path to your Maildir folder:',
            type: 'text',
            default: File.join(Dir.home, 'Maildir'),
            required: true
          },
          {
            key: 'max_age_days',
            prompt: 'Only sync messages from last N days (blank for all):',
            type: 'number',
            required: false
          }
        ]
      end

      def validate_config
        unless @config['maildir_path']
          return [false, "maildir_path is required"]
        end

        unless Dir.exist?(@config['maildir_path'])
          return [false, "Maildir directory does not exist: #{@config['maildir_path']}"]
        end

        [true, nil]
      end

      # Incremental sync: compare disk files with DB for a single folder
      def sync_folder(db, source_id, folder_name, folder_path)
        # 1. List all files on disk (cur/ + new/)
        disk_files = {}  # base_id => full_path
        ['cur', 'new'].each do |subdir|
          dir = File.join(folder_path, subdir)
          next unless Dir.exist?(dir)
          Dir.foreach(dir) do |f|
            next if f.start_with?('.')
            path = File.join(dir, f)
            next if File.directory?(path)
            base_id = f.split(':2,', 2).first
            disk_files[base_id] = path
          end
        end

        # 2. Get DB index for this folder
        db_index = db.get_folder_index(source_id, folder_name)

        new_base_ids = disk_files.keys - db_index.keys
        deleted_base_ids = db_index.keys - disk_files.keys
        changed_base_ids = disk_files.keys & db_index.keys

        # Skip if nothing changed (return false)
        return false if new_base_ids.empty? && deleted_base_ids.empty? && changed_base_ids.all? { |bid|
          flags = self.class.parse_maildir_flags(disk_files[bid])
          db_row = db_index[bid]
          flags[:seen] == (db_row[:read] == 1) &&
            flags[:flagged] == (db_row[:starred] == 1) &&
            flags[:replied] == (db_row[:replied] == 1) &&
            File.basename(disk_files[bid]) == db_row[:external_id]
        }

        structural_change = !new_base_ids.empty? || !deleted_base_ids.empty?

        # Batch all writes in one transaction (single lock acquisition)
        db.transaction do
          # 3. New files (on disk, not in DB) — parse and insert
          new_base_ids.each do |base_id|
            begin
              msg = parse_maildir_file(disk_files[base_id], folder_name)
              next unless msg
              msg[:source_id] = source_id
              db.insert_message(msg)
            rescue => e
              log_error("Error parsing new Maildir file #{disk_files[base_id]}", e)
            end
          end

          # 4. Deleted files (in DB, not on disk) — remove
          unless deleted_base_ids.empty?
            ids_to_delete = deleted_base_ids.map { |bid| db_index[bid][:id] }
            db.delete_messages_by_ids(ids_to_delete)
          end

          # 5. Flag changes (both exist, but flags differ)
          changed_base_ids.each do |base_id|
            flags = self.class.parse_maildir_flags(disk_files[base_id])
            db_row = db_index[base_id]
            if flags[:seen] != (db_row[:read] == 1) || flags[:flagged] != (db_row[:starred] == 1) || flags[:replied] != (db_row[:replied] == 1)
              db.execute("UPDATE messages SET read = ?, starred = ?, replied = ? WHERE id = ?",
                         flags[:seen] ? 1 : 0, flags[:flagged] ? 1 : 0, flags[:replied] ? 1 : 0, db_row[:id])
            end
            # Update external_id and metadata if filename changed
            current_filename = File.basename(disk_files[base_id])
            if current_filename != db_row[:external_id]
              begin
                db.execute("UPDATE messages SET external_id = ? WHERE id = ?",
                           current_filename, db_row[:id])
                db.execute("UPDATE messages SET metadata = json_set(metadata, '$.maildir_file', ?) WHERE id = ?",
                           disk_files[base_id], db_row[:id])
              rescue SQLite3::ConstraintException
                # Duplicate — skip
              end
            end
          end
        end
        # Only return true for new/deleted messages (structural changes).
        # Flag-only changes are already reflected in the UI and don't need
        # a view refresh that could shift the selected index.
        structural_change
      end

      # Full sync across all folders (with include/exclude filters).
      # Returns true if any folder had changes.
      # Yields between folders so caller can pause/abort.
      def sync_all(db, source_id)
        changed = false
        apply_folder_filters(discover_folders).each do |f|
          changed = true if sync_folder(db, source_id, f[:name], f[:path])
          yield if block_given?
        end
        changed
      end

      def health_check
        begin
          unless Dir.exist?(@maildir_path)
            return [false, "Maildir directory not found: #{@maildir_path}"]
          end

          folder_count = discover_folders.size
          [true, "OK - #{@maildir_path} (#{folder_count} folders)"]
        rescue => e
          [false, e.message]
        end
      end

      # Send an email by piping RFC822 message through the SMTP script.
      # Returns { success: bool, message: string }
      def send_message(to, subject, body, in_reply_to = nil,
                        from: nil, cc: nil, bcc: nil, reply_to: nil,
                        extra_headers: nil, smtp_command: nil, attachments: nil)
        msg_from = from || @config['from']
        return { success: false, message: "No From address configured" } unless msg_from
        return { success: false, message: "No SMTP command configured" } unless smtp_command

        from_addr = msg_from[/<([^>]+)>/, 1] || msg_from

        # Build RFC822 email
        msg_to = to; msg_cc = cc; msg_bcc = bcc
        msg_subj = subject; msg_body = body; msg_reply_to = reply_to
        msg_attachments = attachments
        if msg_attachments && !msg_attachments.empty?
          # Multipart message with attachments
          mail = Mail.new do
            from         msg_from
            to           msg_to
            cc           msg_cc if msg_cc && !msg_cc.empty?
            bcc          msg_bcc if msg_bcc && !msg_bcc.empty?
            reply_to     msg_reply_to if msg_reply_to && !msg_reply_to.empty?
            subject      msg_subj
          end
          mail.text_part = Mail::Part.new do
            content_type 'text/plain; charset=UTF-8'
            body msg_body
          end
          msg_attachments.each do |filepath|
            mail.add_file(filepath)
          end
        else
          mail = Mail.new do
            from         msg_from
            to           msg_to
            cc           msg_cc if msg_cc && !msg_cc.empty?
            bcc          msg_bcc if msg_bcc && !msg_bcc.empty?
            reply_to     msg_reply_to if msg_reply_to && !msg_reply_to.empty?
            subject      msg_subj
            content_type 'text/plain; charset=UTF-8'
            body         msg_body
          end
        end
        mail.in_reply_to = in_reply_to if in_reply_to
        mail.message_id = Mail::MessageIdField.new.message_id

        if extra_headers
          extra_headers.each { |k, v| mail[k] = v }
        end

        # Suppress STDERR from mail gem and SMTP script (charset warnings etc.)
        # Strip CR from CRLF — mail gem outputs RFC822 CRLF but Maildir expects LF
        mail_str = suppress_stderr { mail.to_s }.gsub("\r\n", "\n")

        # Collect all envelope recipients (bare email addresses for SMTP)
        all_recipients = Array(to).flat_map { |r| r.split(',').map(&:strip) }
        all_recipients += Array(cc).flat_map { |r| r.split(',').map(&:strip) } if cc
        all_recipients += Array(bcc).flat_map { |r| r.split(',').map(&:strip) } if bcc
        all_recipients.map! { |r| r[/<([^>]+)>/, 1] || r }

        # Pipe through SMTP script (same interface as mutt's sendmail)
        cmd_args = [smtp_command, '-f', from_addr, '--'] + all_recipients
        stderr_output = ""
        require 'open3'
        status = nil
        Open3.popen3(*cmd_args) do |stdin, stdout, stderr, wait_thr|
          stdin.write(mail_str)
          stdin.close
          stderr_output = stderr.read
          status = wait_thr.value
        end

        if status&.success?
          save_to_sent(mail_str)
          { success: true, message: "Message sent to #{to}" }
        else
          err_detail = stderr_output.strip.lines.last(2).join(' ').strip
          err_detail = "exit #{status&.exitstatus || '?'}" if err_detail.empty?
          { success: false, message: "SMTP failed: #{err_detail}" }
        end
      rescue => e
        { success: false, message: "Send failed: #{e.message}" }
      end

      # Parse Maildir flags from filename
      # Returns hash: {seen: bool, flagged: bool, replied: bool, trashed: bool}
      def self.parse_maildir_flags(filename)
        basename = File.basename(filename)
        flags = { seen: false, flagged: false, replied: false, trashed: false, draft: false, passed: false }
        if basename.include?(':2,')
          flag_str = basename.split(':2,', 2).last
          flags[:draft]   = flag_str.include?('D')
          flags[:flagged] = flag_str.include?('F')
          flags[:passed]  = flag_str.include?('P')
          flags[:replied] = flag_str.include?('R')
          flags[:seen]    = flag_str.include?('S')
          flags[:trashed] = flag_str.include?('T')
        end
        flags
      end

      # Rename a Maildir file to add or remove a flag character
      # Returns the new file path
      def self.rename_with_flag(file_path, flag_char, add: true)
        return file_path unless File.exist?(file_path)

        dir = File.dirname(file_path)
        basename = File.basename(file_path)

        if basename.include?(':2,')
          prefix, flags = basename.split(':2,', 2)
          if add
            flags = (flags.chars + [flag_char]).uniq.sort.join
          else
            flags = flags.delete(flag_char)
          end
          new_name = "#{prefix}:2,#{flags}"
        else
          new_name = add ? "#{basename}:2,#{flag_char}" : basename
        end

        # Maildir spec: messages with flags must live in cur/, not new/
        target_dir = if dir.end_with?('/new')
                       dir.sub(/\/new\z/, '/cur')
                     else
                       dir
                     end
        new_path = File.join(target_dir, new_name)
        if file_path != new_path
          File.rename(file_path, new_path)
        end
        new_path
      end

      # Sync read status to Maildir file (add/remove S flag)
      def self.sync_read_flag(file_path, is_read)
        rename_with_flag(file_path, 'S', add: is_read)
      end

      # Sync star/flagged status to Maildir file (add/remove F flag)
      def self.sync_flagged(file_path, is_flagged)
        rename_with_flag(file_path, 'F', add: is_flagged)
      end

      # Sync trashed status to Maildir file (add/remove T flag)
      def self.sync_trashed(file_path)
        rename_with_flag(file_path, 'T', add: true)
      end

      # Move a message file to a different folder
      # Returns new file path
      def self.move_to_folder(file_path, maildir_root, dest_folder_name)
        return nil unless File.exist?(file_path)

        # Determine destination directory
        if dest_folder_name == 'INBOX'
          dest_dir = File.join(maildir_root, 'cur')
        else
          dest_dir = File.join(maildir_root, ".#{dest_folder_name}", 'cur')
        end

        # Create destination if needed
        FileUtils.mkdir_p(dest_dir)
        tmp_dir = File.join(File.dirname(dest_dir), 'tmp')
        new_dir = File.join(File.dirname(dest_dir), 'new')
        FileUtils.mkdir_p(tmp_dir)
        FileUtils.mkdir_p(new_dir)

        new_path = File.join(dest_dir, File.basename(file_path))
        File.rename(file_path, new_path)
        new_path
      end

      private

      # Apply include/exclude folder filters
      def apply_folder_filters(folders)
        if @include_folders && !@include_folders.empty?
          folders.select! { |f| f[:name] == 'INBOX' || @include_folders.any? { |inc| f[:name].start_with?(inc) } }
        end
        if @exclude_folders && !@exclude_folders.empty?
          folders.reject! { |f| @exclude_folders.any? { |exc| f[:name].start_with?(exc) } }
        end
        folders
      end

      def validate_maildir_path!
        unless Dir.exist?(@maildir_path)
          log_error("Maildir directory does not exist", path: @maildir_path)
          raise "Maildir directory not found: #{@maildir_path}"
        end
      end

      def cutoff_time
        return 0 unless @max_age_days
        Time.now.to_i - (@max_age_days * 86400)
      end

      def parse_maildir_file(file_path, folder_name)
        Timeout.timeout(5) do
          _parse_maildir_file_inner(file_path, folder_name)
        end
      rescue Timeout::Error
        log_error("Timeout parsing #{file_path}", nil)
        nil
      end

      def _parse_maildir_file_inner(file_path, folder_name)
        raw_email = File.binread(file_path)
        mail = Mail.new(raw_email)

        external_id = File.basename(file_path)

        # Parse flags from filename
        flags = self.class.parse_maildir_flags(file_path)
        is_read = flags[:seen]
        is_starred = flags[:flagged]

        # Extract recipients
        recipients = []
        recipients << mail.to if mail.to
        recipients = recipients.flatten.compact

        cc = mail.cc ? Array(mail.cc).flatten.compact : []

        # Parse timestamp
        timestamp = mail.date ? mail.date.to_time.to_i : File.mtime(file_path).to_i

        # Extract sender info
        sender = mail.from ? Array(mail.from).first : 'unknown'
        sender_name = extract_sender_name(mail)

        # Get message content
        content = extract_content(mail)
        html_content = extract_html_content(mail)

        # Extract attachments info
        attachments = extract_attachments(mail, file_path)

        # Build metadata
        metadata = {
          'maildir_folder' => folder_name,
          'maildir_file' => file_path,
          'message_id' => mail.message_id,
          'in_reply_to' => mail.in_reply_to,
          'references' => mail.references
        }

        # Store folder name in labels for filtering
        labels = [folder_name]

        normalize_message(
          external_id: external_id,
          sender: sender,
          sender_name: sender_name,
          recipients: recipients,
          cc: cc,
          subject: mail.subject || '(no subject)',
          content: content,
          html_content: html_content,
          timestamp: timestamp,
          read: is_read,
          starred: is_starred,
          replied: flags[:replied],
          attachments: attachments,
          metadata: metadata,
          labels: labels
        )
      end

      def extract_sender_name(mail)
        return nil unless mail.from
        if mail[:from] && mail[:from].display_names.any?
          mail[:from].display_names.first
        else
          nil
        end
      end

      def ensure_utf8(str, charset = nil)
        return str unless str.is_a?(String)
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

        charset = charset&.strip&.downcase
        # Map common charset names
        enc = case charset
              when nil, '', 'us-ascii', 'ascii' then Encoding::ISO_8859_1
              when 'utf-8', 'utf8' then Encoding::UTF_8
              when /iso-?8859-?1/i then Encoding::ISO_8859_1
              when /iso-?8859-?15/i then Encoding::ISO_8859_15
              when /windows-?1252/i, 'cp1252' then Encoding::Windows_1252
              else
                begin
                  Encoding.find(charset)
                rescue ArgumentError
                  Encoding::ISO_8859_1
                end
              end

        str.encode(Encoding::UTF_8, enc, invalid: :replace, undef: :replace, replace: '?')
      rescue => e
        str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
      end

      def extract_content(mail)
        if mail.multipart?
          text_part = mail.text_part
          return ensure_utf8(text_part.decoded, text_part.charset) if text_part

          html_part = mail.html_part
          return strip_html(ensure_utf8(html_part.decoded, html_part.charset)) if html_part

          ensure_utf8(mail.body.decoded, mail.charset)
        else
          ensure_utf8(mail.body.decoded, mail.charset)
        end
      rescue => e
        log_error("Error extracting content", e)
        "(Error reading message content)"
      end

      def extract_html_content(mail)
        if mail.multipart?
          html_part = mail.html_part
          html_part ? ensure_utf8(html_part.decoded, html_part.charset) : nil
        elsif mail.content_type&.include?('text/html')
          ensure_utf8(mail.body.decoded, mail.charset)
        end
      rescue => e
        log_error("Error extracting HTML content", e)
        nil
      end

      def extract_attachments(mail, file_path)
        return [] unless mail.attachments.any?

        mail.attachments.map do |attachment|
          {
            'name' => attachment.filename,
            'size' => attachment.body.decoded.bytesize,
            'content_type' => attachment.content_type,
            'source_file' => file_path
          }
        end
      rescue => e
        log_error("Error extracting attachments", e)
        []
      end

      def save_to_sent(mail_str)
        # Sent folder from RC config, with strftime expansion
        pattern = Heathrow::Config.instance&.rc('sent_folder', 'Sent.%Y-%m') || 'Sent.%Y-%m'
        folder_name = Time.now.strftime(pattern)
        sent_base = File.join(@maildir_path, ".#{folder_name}")
        sent_dir = File.join(sent_base, 'cur')
        FileUtils.mkdir_p(sent_dir)
        FileUtils.mkdir_p(File.join(sent_base, 'new'))
        FileUtils.mkdir_p(File.join(sent_base, 'tmp'))

        hostname = suppress_stderr { `hostname`.strip } rescue 'localhost'
        unique_id = "#{Time.now.to_f}.#{$$}.#{hostname}"
        filename = "#{unique_id}:2,S"
        File.write(File.join(sent_dir, filename), mail_str)
      rescue => e
        log_error("Failed to save to Sent folder", e)
      end

      def suppress_stderr
        old_stderr = $stderr.dup
        $stderr.reopen(File.open(File::NULL, 'w'))
        yield
      ensure
        $stderr.reopen(old_stderr)
        old_stderr.close
      end

      def strip_html(html)
        html.gsub(/<[^>]+>/, ' ')
            .gsub(/\s+/, ' ')
            .strip
      end
    end
  end
end
