#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tempfile'
require 'shellwords'

module Heathrow
  class MessageComposer
    attr_reader :editor, :message

    def initialize(message = nil, identity: nil, address_book: nil, editor_args: nil)
      @message = message
      @editor = ENV['EDITOR'] || 'vim'
      @identity = identity
      @address_book = address_book
      @editor_args = editor_args
    end

    # Compose a reply to a message
    def compose_reply(include_all_recipients = false)
      template = build_reply_template(include_all_recipients)
      content = edit_in_editor(template)
      return nil if content.nil? || content.strip.empty?
      parse_composed_message(content)
    end

    # Compose a forward of a message
    def compose_forward
      template = build_forward_template
      content = edit_in_editor(template)
      return nil if content.nil? || content.strip.empty?
      parse_composed_message(content)
    end

    # Compose a new message
    def compose_new(to = nil, subject = nil)
      template = build_new_template(to, subject)
      # Cursor on "To: " line (line 2)
      content = edit_in_editor(template, cursor_line: 2)
      return nil if content.nil? || content.strip.empty?
      parse_composed_message(content)
    end

    # Resume a postponed draft
    def compose_draft(draft)
      template = header_block(
        to: draft['to'] || '',
        cc: draft['cc'] || '',
        bcc: draft['bcc'] || '',
        subject: draft['subject'] || '',
        reply_to: draft['reply_to']
      )
      template << ""
      template << (draft['body'] || '')

      content = edit_in_editor(template.join("\n"))
      return nil if content.nil? || content.strip.empty?
      parse_composed_message(content)
    end

    private

    # --- Header block shared by all templates ---

    def header_block(to: '', cc: '', bcc: '', subject: '', reply_to: nil)
      from = @identity ? @identity[:from] : ''
      reply_to ||= @identity ? (@identity[:from][/<([^>]+)>/, 1] || @identity[:from]) : ''

      lines = []
      lines << "From: #{from}"
      lines << "To: #{to}"
      lines << "Cc: #{cc}"
      lines << "Bcc: "
      lines << "Reply-To: #{reply_to}"
      lines << "Subject: #{subject}"

      # Custom headers from identity (includes global headers merged by Config)
      if @identity && @identity[:headers]
        @identity[:headers].each { |k, v| lines << "#{k}: #{v}" }
      end

      lines
    end

    # --- Templates ---

    def build_reply_template(include_all)
      return build_new_template unless @message

      original_from = @message['sender'] || 'Unknown'
      original_to = @message['recipient'] || @message['recipients'] || ''
      original_subject = @message['subject'] || ''
      original_content = @message['content'] || ''
      original_date = @message['timestamp'] || Time.now.to_s
      source_type = @message['source_type']

      original_cc = @message['cc']
      original_cc = JSON.parse(original_cc) if original_cc.is_a?(String) rescue []
      original_cc = Array(original_cc)
      my_addr = @identity ? (@identity[:from][/<([^>]+)>/, 1] || @identity[:from]) : nil

      # To: always the original sender
      to = if %w[discord slack telegram].include?(source_type)
             original_to
           else
             original_from
           end

      # Cc: for reply-all, gather original To + Cc minus ourselves
      cc = ''
      if include_all && !%w[discord slack telegram].include?(source_type)
        all = []
        if original_to.is_a?(Array)
          all += original_to
        elsif original_to.is_a?(String) && !original_to.empty?
          all += original_to.split(',').map(&:strip)
        end
        all += original_cc
        all.reject! { |a| a == 'Me' || (my_addr && a.downcase.include?(my_addr.downcase)) }
        cc = all.uniq.join(', ')
      end

      subject = original_subject
      subject = "Re: #{subject}" unless subject.start_with?('Re:')

      template = header_block(to: to, cc: cc, subject: subject)
      template << ""
      template << ""

      # Attribution line + quoted text
      template << format_attribution(original_date, original_from)
      original_content.each_line { |line| template << "> #{line.chomp}" }

      # Signature at the bottom (after quoted text, like mutt)
      sig = get_signature
      if sig
        template << ""
        template << ""
        template << "-- "
        template << sig
      end

      template.map { |s| s.encode('UTF-8', invalid: :replace, undef: :replace) }.join("\n")
    end

    def build_forward_template
      return build_new_template unless @message

      original_from = @message['sender'] || 'Unknown'
      original_subject = @message['subject'] || ''
      original_content = @message['content'] || ''
      original_date = @message['timestamp'] || Time.now.to_s

      subject = original_subject
      subject = "Fwd: #{subject}" unless subject.start_with?('Fwd:')

      template = header_block(subject: subject)
      template << ""
      template << ""
      template << "---------- Forwarded message ----------"
      template << "From: #{original_from}"
      template << "Date: #{format_date(original_date)}"
      template << "Subject: #{original_subject}"
      template << ""
      template << original_content

      # Signature at the bottom
      sig = get_signature
      if sig
        template << ""
        template << ""
        template << "-- "
        template << sig
      end

      template.map { |s| s.encode('UTF-8', invalid: :replace, undef: :replace) }.join("\n")
    end

    def build_new_template(to = nil, subject = nil)
      template = header_block(to: to || '', subject: subject || '')
      template << ""
      template << ""

      sig = get_signature
      if sig
        template << ""
        template << "-- "
        template << sig
      end

      template.join("\n")
    end

    # --- Attribution ---

    def format_date(timestamp)
      t = case timestamp
          when Integer then Time.at(timestamp)
          when String
            Integer(timestamp) rescue nil ? Time.at(Integer(timestamp)) : (Time.parse(timestamp) rescue Time.now)
          else Time.now
          end
      t.strftime('%a, %b %d, %Y at %H:%M:%S(%P) %z')
    end

    def format_attribution(timestamp, sender)
      date_str = format_date(timestamp)
      # Use sender_name if available, otherwise extract from "Name <email>" or use as-is
      name = @message && @message['sender_name'] && !@message['sender_name'].to_s.empty? ?
             @message['sender_name'] : (sender[/^([^<]+)/, 1]&.strip || sender)

      # Configurable via RC: set :attribution, 'On %d, %n wrote:'
      # %d = date, %n = name, %e = email
      pattern = Heathrow::Config.instance&.rc('attribution') rescue nil
      if pattern
        email = sender[/<([^>]+)>/, 1] || sender
        line = pattern.gsub('%d', date_str).gsub('%n', name).gsub('%e', email)
      else
        line = "On #{date_str}, #{name} wrote:"
      end
      line
    end

    # --- Signature ---

    def get_signature
      return nil unless @identity && @identity[:signature]
      sig_path = @identity[:signature]
      return nil unless File.exist?(sig_path)

      if File.executable?(sig_path)
        `#{Shellwords.escape(sig_path)}`.chomp
      else
        File.read(sig_path).chomp
      end
    rescue
      nil
    end

    # --- Address expansion ---

    # Expand aliases in a comma-separated address field.
    # "b, bent" → "Brendan Martin <brendan@example.com>, Bent Brakas <bent@example.com>"
    def expand_addresses(field)
      return field if field.nil? || field.empty?
      field.split(',').map { |addr|
        addr = addr.strip
        expanded = @address_book.expand(addr)
        # If unchanged and no angle brackets, try case-insensitive lookup
        if expanded == addr && !addr.include?('@') && !addr.include?('<')
          matches = @address_book.lookup(addr)
          expanded = matches.values.first if matches.size == 1
        end
        expanded
      }.join(', ')
    end

    # --- Editor ---

    def edit_in_editor(template, cursor_line: nil)
      tempfile = Tempfile.new(['heathrow-compose', '.eml'])

      begin
        tempfile.write(template)
        tempfile.flush

        # Find cursor line: second blank line after headers (body start) if not specified
        unless cursor_line
          lines = template.lines
          found_separator = false
          lines.each_with_index do |line, i|
            if !found_separator && line.strip.empty?
              found_separator = true
              next
            end
            if found_separator
              cursor_line = i + 1  # vim is 1-indexed, line after separator
              break
            end
          end
          cursor_line ||= 1
        end

        # Restore terminal for editor
        system("stty sane 2>/dev/null")
        print "\e[?25h"
        # Position cursor with user-configurable editor args
        args = @editor_args.to_s.strip
        if @editor =~ /vim?\b/
          args = "-c 'startinsert!'" if args.empty?
          system("#{@editor} +#{cursor_line} #{args} #{Shellwords.escape(tempfile.path)}")
        else
          system("#{@editor} #{args} #{Shellwords.escape(tempfile.path)}")
        end
        success = $?.success?
        # Restore raw mode for rcurses
        $stdin.raw!
        $stdin.echo = false
        print "\e[?25l"
        Rcurses.clear_screen if defined?(Rcurses)

        if success
          tempfile.rewind
          content = tempfile.read

          # Treat unchanged content as cancel
          return nil if content.rstrip == template.rstrip

          content
        else
          nil
        end
      ensure
        tempfile.close
        tempfile.unlink
      end
    end

    # --- Parser ---

    def parse_composed_message(content)
      lines = content.lines

      from = nil
      to = nil
      cc = nil
      bcc = nil
      reply_to = nil
      subject = nil
      extra_headers = {}
      body_lines = []
      in_body = false

      lines.each do |line|
        line = line.chomp
        next if line.start_with?('#')

        if !in_body
          case line
          when /^From:\s*(.*)/   then from = $1.strip
          when /^To:\s*(.*)/     then to = $1.strip
          when /^Cc:\s*(.*)/     then cc = $1.strip
          when /^Bcc:\s*(.*)/    then bcc = $1.strip
          when /^Reply-To:\s*(.*)/ then reply_to = $1.strip
          when /^Subject:\s*(.*)/ then subject = $1.strip
          when /^(X-[^:]+):\s*(.*)/  then extra_headers[$1] = $2.strip
          when /^\s*$/           then in_body = true
          else
            in_body = true
            body_lines << line
          end
        else
          body_lines << line
        end
      end

      body = body_lines.join("\n").strip

      # Expand address book aliases in To/Cc/Bcc
      if @address_book
        to  = expand_addresses(to)  if to
        cc  = expand_addresses(cc)  if cc
        bcc = expand_addresses(bcc) if bcc
      end

      return nil if to.nil? || to.empty?
      return nil if body.empty?

      # If user wrote nothing new (only quoted text + signature), treat as cancel
      in_sig = false
      new_content = []
      body.each_line do |l|
        if l.rstrip == '-- ' || l.rstrip == '--'
          in_sig = true
          next
        end
        next if in_sig
        next if l.start_with?('>')
        next if l =~ /^On .+ wrote:$/
        next if l =~ /^-+ Forwarded message -+$/
        next if l =~ /^(From|Date|Subject): /
        new_content << l
      end
      return nil if new_content.all? { |l| l.strip.empty? }

      {
        from: from,
        to: to,
        cc: (cc && !cc.empty?) ? cc : nil,
        bcc: (bcc && !bcc.empty?) ? bcc : nil,
        reply_to: (reply_to && !reply_to.empty?) ? reply_to : nil,
        subject: (subject.nil? || subject.empty?) ? '(no subject)' : subject,
        extra_headers: extra_headers.empty? ? nil : extra_headers,
        body: body,
        original_message: @message
      }
    end
  end
end
