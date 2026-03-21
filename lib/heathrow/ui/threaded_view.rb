#!/usr/bin/env ruby
# frozen_string_literal: true

module Heathrow
  module UI
    # Threaded message view with collapsible threads
    module ThreadedView
      # Thread state tracking
      def initialize_threading
        @thread_collapsed = {}  # Track which threads are collapsed
        @channel_collapsed = {}  # Track which channels are collapsed
        @dm_section_collapsed = true  # DM section state - START COLLAPSED (single section mode)
        @dm_collapsed = {}  # Per-conversation DM collapse tracking
        @show_threaded = true  # Toggle between flat and threaded view
        @group_by_folder = false  # Toggle between threaded and folder grouping
        @thread_indent = "  "  # Indentation for thread replies
        @organizer = nil
        @base_messages = nil  # Base messages from database (never changes during threading)
        @display_messages = []  # Messages currently displayed (including headers)
        @threading_initialized = false  # Track if we've started threading
        @all_start_collapsed = true  # Start with everything collapsed
        @section_order = nil  # Custom section order (array of names)
        @view_thread_modes = {}  # Per-view threading mode: key => {threaded:, folder:}
        @organized_cache = nil
        @organized_cache_key = nil
      end
      
      # Toggle between flat and threaded view
      def toggle_thread_view
        @show_threaded = !@show_threaded
        @group_by_folder = false  # Disable folder grouping when switching to threaded
        organize_current_messages
        render_all
      end

      # Toggle folder grouping view
      def toggle_folder_view
        @group_by_folder = !@group_by_folder
        if @group_by_folder
          @show_threaded = true  # Enable threaded view for folder grouping to work
        end
        reset_threading  # Force re-organization
        organize_current_messages(force_reinit: true)
        render_all
      end
      
      # Cycle: flat → threaded → folder-grouped → flat
      def cycle_view_mode
        if !@show_threaded
          # flat → threaded
          @show_threaded = true
          @group_by_folder = false
          set_feedback("Threaded view", 156, 2)
        elsif @show_threaded && !@group_by_folder
          # threaded → folder-grouped
          @group_by_folder = true
          set_feedback("Folder-grouped view", 156, 2)
        else
          # folder-grouped → flat
          @show_threaded = false
          @group_by_folder = false
          set_feedback("Flat view", 156, 2)
        end
        save_view_thread_mode
        reset_threading
        organize_current_messages(true) if @show_threaded
        render_all
      end

      # Save current threading mode for the active view (persistent)
      def save_view_thread_mode
        return unless @current_view
        @view_thread_modes[@current_view] = { threaded: @show_threaded, folder: @group_by_folder }
        @db.execute(
          "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
          ["thread_mode_#{@current_view}", thread_mode_key, Time.now.to_i]
        )
      end

      # Restore threading mode for the active view
      def restore_view_thread_mode
        return false unless @current_view

        # Check in-memory cache first
        if @view_thread_modes.key?(@current_view)
          mode = @view_thread_modes[@current_view]
          @show_threaded = mode[:threaded]
          @group_by_folder = mode[:folder]
          return true
        end

        # Load from settings table
        row = @db.db.get_first_row(
          "SELECT value FROM settings WHERE key = ?",
          ["thread_mode_#{@current_view}"]
        )
        mode_key = row && row['value']
        return false unless mode_key

        apply_thread_mode_key(mode_key)
        @view_thread_modes[@current_view] = { threaded: @show_threaded, folder: @group_by_folder }
        true
      end

      # Convert current mode to a string key
      def thread_mode_key
        if !@show_threaded
          'flat'
        elsif @group_by_folder
          'folders'
        else
          'threaded'
        end
      end

      # Apply a mode from a string key
      def apply_thread_mode_key(key)
        case key
        when 'flat'
          @show_threaded = false
          @group_by_folder = false
        when 'folders'
          @show_threaded = true
          @group_by_folder = true
        else # 'threaded'
          @show_threaded = true
          @group_by_folder = false
        end
      end

      # Short label for current threading mode
      def thread_mode_label
        if !@show_threaded
          "Flat"
        elsif @group_by_folder
          "Folders"
        else
          "Threaded"
        end
      end

      # Reset threading state when messages change
      def reset_threading(preserve_collapsed_state = false)
        @base_messages = nil
        @organizer = nil
        @threading_initialized = false
        @display_messages = []
        @scroll_offset = 0  # Reset scroll position
        @organized_cache = nil
        @organized_cache_key = nil

        # Preserve or reset collapsed states
        if !preserve_collapsed_state
          # Reset collapsed states to start collapsed
          @thread_collapsed = {}
          @channel_collapsed = {}
          @dm_section_collapsed = true
          @dm_collapsed = {}
          @section_order = nil
        end
        # If preserve_collapsed_state is true, keep existing collapsed states
      end
      
      # Get the current message for navigation (works with both flat and threaded views)
      def current_message_for_navigation
        if @show_threaded && !@display_messages.empty?
          @display_messages[@index]
        else
          @filtered_messages[@index]
        end
      end
      
      # Get the size of the current message array for navigation
      def filtered_messages_size
        if @show_threaded && !@display_messages.empty?
          @display_messages.size
        else
          @filtered_messages.size
        end
      end
      
      # Organize messages for current view
      def organize_current_messages(force_reinit = false)
        return unless @show_threaded

        # Only organize once per message set - capture the base messages on first run
        # OR if we're forcing reinitialization after a sort change
        if !@threading_initialized || force_reinit
          @base_messages = @filtered_messages.dup
          @threading_initialized = true
          @organized_cache = nil
          @organized_cache_key = nil

          require_relative '../message_organizer'
          @organizer = MessageOrganizer.new(@base_messages, @db, group_by_folder: @group_by_folder)
        end
      end
      
      # Toggle collapse state of current item
      def toggle_collapse
        return unless @show_threaded && @organizer
        
        msg = current_message_for_navigation
        return unless msg
        
        # Determine what type of item this is
        if msg['is_channel_header']
          # Toggle channel collapse
          @channel_collapsed[msg['channel_id']] = !@channel_collapsed[msg['channel_id']]
        elsif msg['is_thread_header']
          # Toggle thread collapse
          @thread_collapsed[msg['thread_id']] = !@thread_collapsed[msg['thread_id']]
        elsif msg['is_dm_header']
          # Toggle DM section (per-conversation or single)
          dm_key = msg['channel_id']
          if @dm_collapsed.key?(dm_key) || @sort_order == 'conversation'
            @dm_collapsed[dm_key] = !@dm_collapsed.fetch(dm_key, true)
          else
            @dm_section_collapsed = !@dm_section_collapsed
          end
        elsif msg['thread_id']
          # Toggle the thread this message belongs to
          @thread_collapsed[msg['thread_id']] = !@thread_collapsed[msg['thread_id']]
        end
        
        # Re-render
        render_message_list_threaded
      end

      # Move current section up or down in the list
      def move_section(direction)
        return unless @show_threaded && @organizer

        msg = current_message_for_navigation
        return unless msg
        # Allow moving channel headers and thread headers
        return unless msg['is_channel_header'] || msg['is_thread_header']

        section_name = msg['channel_id'] || msg['thread_id']
        return unless section_name

        # Build section order from current organized view if not set
        organized = @organizer.get_organized_view(@sort_order, @sort_inverted)
        @section_order ||= organized.map { |s| s[:name] || s[:subject] }

        idx = @section_order.index(section_name)
        return unless idx

        new_idx = idx + direction
        return if new_idx < 0 || new_idx >= @section_order.size

        # Swap
        @section_order[idx], @section_order[new_idx] = @section_order[new_idx], @section_order[idx]

        # Persist to view config
        save_section_order

        # Re-render and find new cursor position
        render_message_list_threaded
        key = msg['is_channel_header'] ? 'channel_id' : 'thread_id'
        new_display_idx = @display_messages.index { |m| m[key] == section_name }
        @index = new_display_idx if new_display_idx
        render_message_list_threaded
      end

      # Save section order into the current view's filters in the database
      def save_section_order
        return unless @current_view && @views[@current_view] && @section_order
        view = @views[@current_view]
        view[:filters] ||= {}
        view[:filters]['section_order'] = @section_order

        # Persist to database
        if view[:id]
          @db.save_view({
            id: view[:id],
            name: view[:name],
            key_binding: @current_view,
            filters: view[:filters],
            sort_order: view[:sort_order] || 'timestamp DESC'
          })
        end
      end

      # Render threaded message list
      def render_message_list_threaded
        return render_message_list unless @show_threaded && @organizer
        
        lines = []
        visible_messages = []
        current_index = 0
        @scroll_offset ||= 0  # Track scroll position

        cache_key = "#{@sort_order}|#{@sort_inverted}|#{@filtered_messages.size}"
        if @organized_cache && @organized_cache_key == cache_key
          organized = @organized_cache
        else
          organized = @organizer.get_organized_view(@sort_order, @sort_inverted)
          @organized_cache = organized
          @organized_cache_key = cache_key
        end

        # Apply custom section order if set
        if @section_order && !@section_order.empty?
          order_map = {}
          @section_order.each_with_index { |name, i| order_map[name] = i }
          organized.sort_by! { |s| order_map[s[:name] || s[:subject]] || 9999 }
        end

        organized.each do |section|
          case section[:type]
          when 'channel'
            # Channel header
            header_msg = create_section_header(section, 'channel')
            
            # Initialize collapse state if not set
            if !@channel_collapsed.key?(section[:name])
              @channel_collapsed[section[:name]] = @all_start_collapsed
            end
            
            # Store line index for scrolling
            lines << format_channel_header(section, current_index == @index)
            visible_messages << header_msg
            current_index += 1
            
            # Channel messages if not collapsed
            unless @channel_collapsed[section[:name]]
              # Set current channel ID for messages
              @current_channel_id = section[:name]
              render_channel_messages(section[:messages], lines, visible_messages, current_index, section[:source])
              current_index += section[:messages].size
            end
            
          when 'dm_section'
            # DM section header
            dm_key = section[:name]
            # Use per-conversation collapse if in conversation sort, otherwise single toggle
            collapsed = if @sort_order == 'conversation'
                          @dm_collapsed.fetch(dm_key, true)  # Default collapsed
                        else
                          @dm_section_collapsed
                        end
            header_msg = create_section_header(section, 'dm')
            lines << format_dm_header(section, current_index == @index, collapsed: collapsed)
            visible_messages << header_msg
            current_index += 1

            # DMs if not collapsed
            unless collapsed
              section[:messages].each do |msg|
                lines << format_dm_message(msg, current_index == @index)
                visible_messages << msg
                current_index += 1
              end
            end
            
          when 'thread'
            if section[:messages] && section[:messages].size == 1
              # Single message — show as flat item, no header
              msg = section[:messages].first
              lines << format_thread_message(msg, current_index == @index, "")
              visible_messages << msg
              current_index += 1
            else
              # Multi-message thread — collapsible header
              header_msg = create_section_header(section, 'thread')

              if !@thread_collapsed.key?(section[:subject])
                @thread_collapsed[section[:subject]] = @all_start_collapsed
              end

              lines << format_thread_header(section, current_index == @index)
              visible_messages << header_msg
              current_index += 1

              unless @thread_collapsed[section[:subject]]
                render_thread_messages(section[:messages], lines, visible_messages, current_index)
                current_index += section[:messages].size
              end
            end
          end
        end
        
        # Store display messages for navigation (don't overwrite @filtered_messages)
        @display_messages = visible_messages

        # Restore index by message ID after a background refresh rebuilt the list.
        # @pending_restore_id is set by the pending_view_refresh handler because
        # @display_messages is empty at that point (reset_threading clears it).
        if @pending_restore_id
          new_idx = @display_messages.index { |m| m['id'] == @pending_restore_id }
          @pending_restore_id = nil
          if new_idx && new_idx != @index
            @index = new_idx
            return render_message_list_threaded  # Re-render with correct highlight
          end
        end

        # Give full text to rcurses and use its scrolling with markers
        @panes[:left].scroll = true
        new_text = lines.join("\n")

        # Calculate scroll position to keep current item visible
        pane_height = @panes[:left].h - 2
        scrolloff = 3
        old_ix = @panes[:left].ix

        if @index < @panes[:left].ix + scrolloff
          @panes[:left].ix = [@index - scrolloff, 0].max
        elsif @index > @panes[:left].ix + pane_height - scrolloff - 1
          max_ix = [lines.size - pane_height, 0].max
          @panes[:left].ix = [@index - pane_height + scrolloff + 1, max_ix].min
        end

        @panes[:left].text = new_text
        @panes[:left].refresh
      end
      
      # Get date range string for a section's messages
      def section_date_range(messages)
        return "" if messages.nil? || messages.empty?
        timestamps = messages.map { |m| m['timestamp'] }.compact
        return "" if timestamps.empty?
        times = timestamps.map { |t|
          if t.is_a?(Integer) || t.to_s.match?(/^\d+$/)
            Time.at(t.to_i)
          else
            Time.parse(t.to_s) rescue nil
          end
        }.compact
        return "" if times.empty?
        oldest = times.min
        newest = times.max
        fmt = @date_format || '%b %-d'
        if oldest.to_date == newest.to_date
          newest.strftime(fmt)
        else
          "#{oldest.strftime(fmt)} – #{newest.strftime(fmt)}"
        end
      end

      # Shared section header formatter
      def format_section_header(display_name, collapsed, color, section, selected, source_icon: nil)
        icon = collapsed ? "▶" : "▼"
        unread = section[:unread_count].to_i > 0 ? " (#{section[:unread_count]})" : ""
        dates = section_date_range(section[:messages])
        date_suffix = dates.empty? ? "" : " #{dates}"

        pane_width = @panes[:left].w - 5
        prefix = source_icon ? "#{icon} #{source_icon} " : "#{icon} "
        used_space = prefix.length + unread.length + date_suffix.length
        available = pane_width - used_space

        if display_name.length > available && available > 3
          display_name = display_name[0..(available-2)] + "…"
        end

        name_part = "#{display_name}#{unread}"

        if selected
          prefix.b.fg(color) + name_part.u.b.fg(color) + date_suffix.fg(245)
        elsif section[:unread_count].to_i > 0
          prefix.b.fg(color) + name_part.b.fg(color) + date_suffix.fg(245)
        else
          (prefix + name_part).fg(color) + date_suffix.fg(245)
        end
      end

      # Format channel header line
      def format_channel_header(section, selected)
        collapsed = @channel_collapsed[section[:name]]
        display_name = section[:display_name] || section[:name]
        color = get_source_color({'source_type' => section[:source]})
        format_section_header(display_name, collapsed, color, section, selected,
                              source_icon: get_source_icon(section[:source]))
      end

      # Format DM section header
      def format_dm_header(section, selected, collapsed: @dm_section_collapsed)
        dm_text = section[:name] || "Direct Messages"
        format_section_header(dm_text, collapsed, theme[:dm], section, selected, source_icon: "⇔")
      end

      # Format thread header
      def format_thread_header(section, selected)
        collapsed = @thread_collapsed[section[:subject]]
        subject = section[:subject] || "(no subject)"
        format_section_header(subject, collapsed, theme[:thread], section, selected)
      end
      
      # Format channel message
      def render_channel_messages(messages, lines, visible_messages, start_index, section_source = nil)
        messages.each_with_index do |msg, i|
          # Use section source (from organizer) since DB messages don't have source_type
          source_type = section_source || msg['source_type'] || 'unknown'
          lines << format_channel_message(msg, start_index + i == @index, "", source_type)
          
          # Don't duplicate the message - just add channel_id directly
          # This ensures updates to is_read status are preserved
          msg['channel_id'] ||= @current_channel_id
          visible_messages << msg
        end
      end
      
      # Format thread messages
      def render_thread_messages(messages, lines, visible_messages, start_index)
        messages.each_with_index do |msg, i|
          level = (msg['thread_level'] || 0) + 1  # +1 to indent under thread header
          indent = @thread_indent * level

          lines << format_thread_message(msg, start_index + i == @index, indent)
          visible_messages << msg
        end
      end
      
      # Format a channel message line
      def format_channel_message(msg, selected, indent = "", source_type = nil)
        sender = display_sender(msg)
        
        # For RSS, show article title not sender (use passed source_type since DB lacks it)
        if (source_type || msg['source_type']) == 'rss'
          sender = ''  # Don't show sender for RSS
        else
          sender = truncate_to_width(sender, 14) + '…' if Rcurses.display_width(sender) > 15
        end
        
        # For Discord/Slack channels, show content not channel name
        content = msg['content'] || ''
        
        # Check if subject is a channel name or ID
        if msg['subject'] =~ /^\d+$/ || msg['subject'] =~ /#/
          # It's a channel indicator, show content instead
          display_content = content.gsub(/\n/, ' ')
        elsif msg['subject'] == msg['recipient']
          # Subject is same as recipient (channel name), show content
          display_content = content.gsub(/\n/, ' ')
        else
          # Normal subject, show it
          display_content = msg['subject'] || content
          display_content = display_content.gsub(/\n/, ' ')
        end
        
        unread = msg['is_read'].to_i == 0 ? "•" : " "
        color = get_source_color(msg)

        if sender.empty?
          prefix = "#{unread} "
        else
          prefix = "#{unread} #{sender + ' ' * [15 - Rcurses.display_width(sender), 0].max} "
        end

        # Truncate content to fit single line (prefix + 2 for nflag+ind from finalize_line)
        pane_width = @panes[:left].w - 5
        available = pane_width - Rcurses.display_width(prefix)
        if display_content && Rcurses.display_width(display_content) > available && available > 0
          display_content = truncate_to_width(display_content, available - 1) + "…"
        end

        finalize_line(msg, selected, prefix, display_content, color)
      end

      # Format a thread reply
      def format_thread_reply(msg, selected, indent)
        sender = display_sender(msg)
        sender = truncate_to_width(sender, 12) if Rcurses.display_width(sender) > 12

        content = msg['content'] || ''
        content = content.gsub(/\n/, ' ')

        # Truncate based on pane width
        pane_width = @panes[:left].w - 5
        used_space = 2 + Rcurses.display_width(indent) + 3 + Rcurses.display_width(sender) + 2
        available = pane_width - used_space
        if Rcurses.display_width(content) > available && available > 0
          content = truncate_to_width(content, available - 1) + "…"
        end
        
        prefix = "#{indent}└─ #{sender}: "
        finalize_line(msg, selected, prefix, content, 245)
      end
      
      # Format a thread message
      def format_thread_message(msg, selected, indent)
        sender = display_sender(msg)
        pane_width = @panes[:left].w - 5
        icon = get_source_icon(msg['source_type'])

        timestamp = (parse_timestamp(msg['timestamp']) || "").ljust(6)
        sender_max = 15
        sdw = Rcurses.display_width(sender)
        sender = sdw > sender_max ? truncate_to_width(sender, sender_max - 1) + '…' : sender + ' ' * [sender_max - sdw, 0].max
        child_indent = indent.empty? ? "" : "    "
        prefix = "#{child_indent}#{timestamp} #{icon} #{sender} "

        content = msg['subject'] || msg['content'] || ''
        content = content.dup if content.frozen?
        content = content.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?') rescue content.force_encoding('UTF-8').scrub('?')
        content = content.gsub(/\n/, ' ')

        used_space = Rcurses.display_width(prefix) + 1
        available = pane_width - used_space
        if Rcurses.display_width(content) > available && available > 0
          content = truncate_to_width(content, available - 1) + "…"
        end

        color = get_source_color(msg)
        finalize_line(msg, selected, prefix, content, color)
      end

      # Format DM message
      def format_dm_message(msg, selected)
        sender = display_sender(msg)
        platform = get_source_icon(msg['source_type'])

        # Truncate sender to fixed width
        sender_max = 15
        sdw = Rcurses.display_width(sender)
        sender = sdw > sender_max ? truncate_to_width(sender, sender_max - 1) + '…' : sender + ' ' * [sender_max - sdw, 0].max

        content = msg['content'] || ''
        content = content.gsub(/\n/, ' ')

        unread = msg['is_read'].to_i == 0 ? "•" : " "
        prefix = "#{unread} #{platform} #{sender} "

        # Truncate content to fit single line
        pane_width = @panes[:left].w - 5
        available = pane_width - Rcurses.display_width(prefix)
        if Rcurses.display_width(content) > available && available > 0
          content = truncate_to_width(content, available - 1) + "…"
        end

        color = get_source_color(msg)
        finalize_line(msg, selected, prefix, content, color)
      end

      # Get source platform icon
      def get_source_icon(source)
        case source.to_s
        when 'discord' then '◆'  # Diamond for Discord (no emoji)
        when 'slack' then '#'     # Hash remains for Slack
        when 'telegram' then '✈'  # Airplane works fine
        when 'whatsapp' then '◉'  # Filled circle works fine
        when 'reddit' then '®'    # Registered mark for Reddit
        when 'email', 'gmail', 'imap', 'maildir' then '✉'  # Letter symbol for email
        when 'rss' then '◈'     # Diamond for RSS
        when 'web' then '◎'     # Target for web watch
        when 'messenger' then '◉'  # Filled circle for Messenger
        when 'instagram' then '◈'  # Diamond for Instagram
        when 'weechat' then '⊞'   # WeeChat relay
        else '•'
        end
      end
      
      # Create a section header message object
      def create_section_header(section, type)
        # Get the timestamp from the most recent message in this section
        latest_timestamp = if section[:messages] && !section[:messages].empty?
          msg_timestamp = section[:messages].first['timestamp']
          # Validate timestamp - some sources have invalid values like "0"
          if msg_timestamp && !msg_timestamp.to_s.empty? && msg_timestamp.to_s != "0"
            begin
              Time.parse(msg_timestamp.to_s)
              msg_timestamp
            rescue
              Time.now.iso8601
            end
          else
            Time.now.iso8601
          end
        else
          Time.now.iso8601
        end
        
        {
          'id' => "header_#{type}_#{section[:name] || Time.now.to_i}",
          'is_header' => true,
          "is_#{type}_header" => true,
          'channel_id' => section[:name],
          'channel_name' => section[:name],  # Add for toggle_group_read_status
          'thread_id' => section[:subject],
          'subject' => section[:name] || section[:subject],
          'content' => "#{section[:messages].size} messages",
          'is_read' => section[:unread_count] == 0 ? 1 : 0,
          'timestamp' => latest_timestamp,
          'sender' => '',
          'source_type' => section[:messages].first&.dig('source_type') || 'unknown',
          'source_id' => section[:messages].first&.dig('source_id'),  # Add source_id from first message
          'section_messages' => section[:messages]  # Store reference to messages for toggle
        }
      end
      
      # Shared line formatting: selection arrow, underline on subject only, delete/tag/star indicators
      def finalize_line(msg, selected, prefix_text, subject_text, color, padding = "")
        # Unread flag (like mutt's N)
        nflag = msg['is_read'].to_i == 0 ? "N".fg(226) : " "
        # Replied flag (like mutt's r)
        rflag = msg['replied'].to_i == 1 ? "←".fg(45) : " "
        tag_color = theme[:tag] || 14
        star_color = theme[:star] || 226

        ind = if @delete_marked&.include?(msg['id'])
                "D".fg(88)
              elsif @tagged_messages&.include?(msg['id'])
                "•".fg(tag_color)
              elsif msg['is_starred'] == 1
                "★".fg(star_color)
              elsif msg['attachments'].is_a?(Array) && !msg['attachments'].empty? && !prefix_text.include?("₊")
                "₊".fg(208)
              else
                " "
              end

        flags = nflag + rflag + ind
        content = prefix_text + subject_text
        if @delete_marked&.include?(msg['id'])
          if selected
            flags + content.u.fg(88) + padding
          else
            flags + content.fg(88) + padding
          end
        elsif @tagged_messages&.include?(msg['id'])
          if selected
            lead = content[/\A */]
            rest = content[lead.length..]
            flags + lead.b.fg(tag_color) + rest.u.b.fg(tag_color) + padding
          else
            flags + content.fg(tag_color) + padding
          end
        elsif msg['is_starred'] == 1
          if selected
            lead = content[/\A */]
            rest = content[lead.length..]
            flags + lead.b.fg(star_color) + rest.u.b.fg(star_color) + padding
          else
            flags + content.fg(star_color) + padding
          end
        elsif selected
          lead = content[/\A */]
          rest = content[lead.length..]
          flags + lead.b.fg(color) + rest.u.b.fg(color) + padding
        elsif msg['is_read'].to_i == 0
          flags + content.b.fg(color) + padding
        else
          flags + content.fg(color) + padding
        end
      end

      # Format timestamp
      def format_time(timestamp)
        return "" unless timestamp

        begin
          # Handle both Unix timestamps and date strings
          time = if timestamp.is_a?(Integer) || timestamp.to_s.match?(/^\d+$/)
            Time.at(timestamp.to_i)
          else
            Time.parse(timestamp.to_s)
          end

          if time.to_date == Date.today
            time.strftime("%H:%M")
          else
            time.strftime("%m/%d")
          end
        rescue
          ""
        end
      end
    end
  end
end