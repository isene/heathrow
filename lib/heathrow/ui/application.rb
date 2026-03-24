#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rcurses'
require 'set'
require 'io/wait'
require 'uri'
require 'digest'
require 'timeout'
require 'shellwords'
require 'fileutils'
require 'tmpdir'
require 'tempfile'

require_relative 'threaded_view'

# Add .content_update flag to rcurses Pane.
# When content_update=false, render_all skips re-rendering that pane's content.
# Uses a separate name to avoid conflicting with rcurses internal @update flag.
class Rcurses::Pane
  def content_update=(value)
    @content_update = value
  end

  def content_update
    @content_update.nil? ? true : @content_update
  end
end

module Heathrow
  class Application
    include Rcurses
    include Rcurses::Input
    include Rcurses::Cursor
    include UI::ThreadedView

    COLOR_THEMES = {
      'Default' => { unread: 226, read: 249, accent: 10, thread: 255, dm: 201, tag: 14, star: 226,
                     quote1: 114, quote2: 180, quote3: 139, quote4: 109, sig: 242,
                     top_bg: 235, bottom_bg: 235, cmd_bg: 17,
                     source_email: 39, source_maildir: 39, source_whatsapp: 40,
                     source_discord: 99, source_reddit: 202, source_rss: 226,
                     source_telegram: 51, source_slack: 35, source_web: 208,
                     source_messenger: 33, source_instagram: 205, source_weechat: 75,
                     source_default: 15 },
      'Mutt'    => { unread: 226, read: 249, accent: 14, thread: 252, dm: 213, tag: 81,
                     quote1: 114, quote2: 180, quote3: 139, quote4: 109, sig: 243 },
      'Ocean'   => { unread: 51,  read: 249, accent: 45, thread: 45,  dm: 171, tag: 87,
                     quote1: 75, quote2: 117, quote3: 153, quote4: 189, sig: 242 },
      'Forest'  => { unread: 77,  read: 249, accent: 10, thread: 78,  dm: 176, tag: 48,
                     quote1: 114, quote2: 150, quote3: 186, quote4: 222, sig: 242 },
      'Amber'   => { unread: 220, read: 249, accent: 226, thread: 214, dm: 209, tag: 214,
                     quote1: 222, quote2: 186, quote3: 180, quote4: 174, sig: 242 },
    }

    attr_reader :db, :config, :panes
    
    def initialize
      # Ensure LS_COLORS is loaded (may be missing if not launched from rsh)
      if !ENV['LS_COLORS'] || ENV['LS_COLORS'].empty?
        lscolors_file = File.expand_path('~/.local/share/lscolors.sh')
        if File.exist?(lscolors_file)
          content = File.read(lscolors_file)
          ENV['LS_COLORS'] = $1 if content =~ /LS_COLORS='([^']+)'/
        end
      end

      # Initialize core components FIRST
      @db = Database.new
      @config = Config.new
      @source_manager = SourceManager.new(@db)
      @running = false
      @current_view = 'A' # Start with All messages
      initialize_threading  # Initialize threading support
      @view_names = {
        'A' => 'All Messages',
        'N' => 'New Messages',
        's' => 'Sources',
        'S' => 'Starred'
      }
      
      # UI state - RC settings override YAML config, with defaults
      @width = @config.get('ui.width', @config.rc('pane_width', 3))
      @border = @config.rc('border_style', 1)
      @sort_order = @config.rc('sort_order', 'latest')
      @sort_inverted = false
      @feedback_message = nil
      @feedback_expires_at = nil
      @date_format = @config.rc('date_format', '%b %e')
      @confirm_purge = @config.rc('confirm_purge', false) == true
      @color_theme = @config.rc('color_theme', 'Default')
      @default_view = @config.get('ui.default_view', 'A')
      @editor_args = @config.get('ui.editor_args', "-c 'set nospell' -c 'startinsert!'")
      @default_email = @config.get('default_email', @config.rc('default_email', ''))
      @smtp_command = @config.get('smtp_command', @config.rc('smtp_command', ''))

      # Message list state
      @messages = []
      @filtered_messages = []
      @index = 0
      @min_index = 0
      @source_colors = {}  # Cache for source colors
      @max_index = 0

      # Browsed message tracking for session-based read status
      @browsed_message_ids = Set.new  # Messages viewed this session
      @tagged_messages = Set.new  # Tagged messages for batch operations
      
      # View definitions
      @views = {}
      load_views
      
      # Colors (from theme, with defaults)
      @topcolor = theme[:top_bg] || 235
      @bottomcolor = theme[:bottom_bg] || 235
      @cmdcolor = theme[:cmd_bg] || 17
      
      # Load source colors
      load_source_colors

      # Load address book
      require_relative '../address_book'
      @address_book = AddressBook.new
    end
    
    def setup_display
      # Get terminal dimensions like GiTerm does
      require 'io/console'
      if IO.console
        @h, @w = IO.console.winsize
      else
        # Fallback for non-terminal environments
        @h = ENV['LINES']&.to_i || 24
        @w = ENV['COLUMNS']&.to_i || 80
      end
    end
    
    # Ask user for input via bottom pane, then restore the status line
    def bottom_ask(prompt, default = '')
      @editing = true
      result = @panes[:bottom].ask(prompt, default)
      @editing = false
      render_top_bar
      render_bottom_bar
      result
    end

    def create_panes
      @panes = {}

      # Create main container pane
      @panes[:main] = Pane.new(1, 1, @w, @h, 0, 0)
      
      # Top bar (like RTFM's @pT)
      @panes[:top] = Pane.new(1, 1, @w, 1, 255, @topcolor)
      
      # Left pane for message list (like RTFM's @pL)
      left_width = (@w - 4) * @width / 10
      @panes[:left] = Pane.new(2, 3, left_width, @h - 4)
      
      # Right pane for message content (like RTFM's @pR)
      @panes[:right] = Pane.new(@panes[:left].w + 4, 3, @w - @panes[:left].w - 4, @h - 4)
      
      # Bottom command bar (like RTFM's @pB)
      @panes[:bottom] = Pane.new(1, @h, @w, 1, 252, @bottomcolor)
      @panes[:bottom].emoji = true
      @panes[:bottom].emoji_refresh = -> {
        @panes.each_value { |p| p.full_refresh }
      }
      
      # Command input pane (overlays bottom when active)
      @panes[:cmd] = Pane.new(1, @h, @w, 1, 255, @cmdcolor)
      
      # Initialize scroll positions to 0
      @panes[:left].ix = 0
      @panes[:right].ix = 0
      
      # Set borders
      set_borders
    end
    
    def set_borders
      case @border
      when 0
        @panes[:left].border = false
        @panes[:right].border = false
      when 1
        @panes[:left].border = false
        @panes[:right].border = true
      when 2
        @panes[:left].border = true
        @panes[:right].border = true
      when 3
        @panes[:left].border = true
        @panes[:right].border = false
      end
    end

    def all_themes
      COLOR_THEMES.merge(@config.custom_themes)
    end

    def theme
      base = COLOR_THEMES['Default']
      selected = all_themes[@color_theme]
      selected ? base.merge(selected) : base
    end

    def header_message?(msg)
      msg['is_header'] || msg['is_channel_header'] || msg['is_thread_header'] || msg['is_dm_header']
    end

    def invalidate_counts
      @cached_unread = nil
      @cached_starred = nil
      @cached_total = nil
    end

    # Get the current message at @index (threaded or flat view)
    def current_message
      current_message_for_navigation
    end

    # Get the current message count (threaded or flat view)
    def message_count
      filtered_messages_size
    end

    # Mark the previous message as read when moving away from it
    def track_browsed_message
      flush_pending_read

      # Remember current message so it gets marked read when we leave it
      msg = current_message
      return unless msg
      return if header_message?(msg)
      return unless msg['id'] && !msg['id'].to_s.start_with?('header_')

      if msg['is_read'].to_i == 0
        @browsed_message_ids.add(msg['id'])
        @pending_mark_read = msg
      end
    end

    # Flush any deferred read mark (call when leaving a view)
    def flush_pending_read
      return unless @pending_mark_read
      mark_message_read(@pending_mark_read)
      @pending_mark_read = nil
    end

    # Mark a single message as read in DB, in-memory, and on disk
    def mark_message_read(msg)
      return unless msg && msg['id']
      return if msg['is_read'].to_i == 1

      @db.mark_as_read(msg['id'])
      msg['is_read'] = 1
      invalidate_counts
      sync_maildir_flag(msg, 'S', true)

      # Also update any other references to this message in filtered/display lists
      msg_id = msg['id']
      [@filtered_messages, @display_messages].each do |list|
        next unless list
        list.each do |m|
          next unless m && m['id'] == msg_id && m.object_id != msg.object_id
          m['is_read'] = 1
        end
      end
    end

    # Auto-mark message as read (called when message is displayed)
    def auto_mark_as_read(msg)
      mark_message_read(msg)
    end

    # Mark message as "unseen" - remove from browsed set
    def unsee_current_message
      msg = current_message
      return unless msg
      return if msg['is_header']

      if @browsed_message_ids.delete(msg['id'])
        set_feedback("Message marked as unseen", 226, 2)
        render_all
      end
    end

    # Mark all browsed messages as permanently read
    def mark_browsed_as_read
      count = @browsed_message_ids.size
      return if count == 0

      msg_by_id = @filtered_messages.each_with_object({}) { |m, h| h[m['id']] = m }
      @browsed_message_ids.each do |msg_id|
        @db.mark_as_read(msg_id)
        msg = msg_by_id[msg_id]
        msg['is_read'] = 1 if msg
      end

      @browsed_message_ids.clear
      invalidate_counts
      set_feedback("Marked #{count} browsed messages as read", 156, 3)

      # Remove from view if in unread view
      if is_unread_view?
        @filtered_messages.select! { |m| m['is_read'].to_i == 0 }
        @index = 0
        reset_threading
      end

      render_all
    end

    # Check if current view is an unread filter
    def is_unread_view?
      # Check key binding
      return true if @current_view == 'N'

      # Check if custom view has unread filter
      if @views[@current_view]
        view = @views[@current_view]
        if view && view[:filters]
          filters = view[:filters]
          # Check if filtering by read = false
          return true if filters['read'] == false || filters[:read] == false
          # Check if using rules with read field
          if filters['rules'].is_a?(Array)
            return filters['rules'].any? { |rule| rule['field'] == 'read' && rule['value'] == false }
          end
        end
      end

      false
    end

    # Helper method to safely get messages with automatic pagination for large databases
    def safe_get_messages(filters = {}, custom_limit = nil, light: true)
      # Use custom limit if provided, otherwise auto-paginate for large DBs
      limit = custom_limit
      if limit.nil? && (@total_message_count || 0) > 10000
        limit = 1000  # Default limit for large databases
      end

      @db.get_messages(filters, limit, 0, light: light)
    end

    # Helper method to parse timestamps (handles both Unix timestamps and date strings)
    def parse_timestamp(ts, format = @date_format)
      return nil if ts.nil? || ts.to_s.empty? || ts.to_s == "0"

      if ts.is_a?(Integer) || ts.to_s.match?(/^\d+$/)
        # Unix timestamp - use Time.at
        Time.at(ts.to_i).strftime(format)
      else
        # Date string - use Time.parse
        Time.parse(ts.to_s).strftime(format)
      end
    rescue => e
      nil
    end

    # Extract display name from sender (prefer sender_name, strip email angle brackets)
    def display_sender(msg)
      name = msg['sender_name']
      return name if name && !name.empty?

      raw = msg['sender'] || ''
      # "John Doe <john@example.com>" → "John Doe"
      if raw =~ /^(.+?)\s*<[^>]+>$/
        $1.strip
      else
        raw
      end
    end

    # Helper method to get Time object from timestamp for sorting
    def timestamp_to_time(ts)
      return Time.at(0) if ts.nil? || ts.to_s.empty? || ts.to_s == "0"

      if ts.is_a?(Integer) || ts.to_s.match?(/^\d+$/)
        Time.at(ts.to_i)
      else
        Time.parse(ts.to_s)
      end
    rescue => e
      Time.at(0)
    end

    def run
      # Check database size BEFORE initializing rcurses
      @total_message_count = @db.get_stats[:total_messages]

      # Show loading info before rcurses takes over the screen
      puts "Loading Heathrow..."
      puts "Database: #{@total_message_count} messages"
      if @total_message_count > 10000
        puts "Large database - loading most recent 1000 messages"
        puts "(Use views to filter, press 'N' for unread)"
        sleep 1
      end

      # EXACTLY LIKE RTFM
      # Initialize rcurses
      Rcurses.init!

      # Clear screen to remove any artifacts
      Rcurses.clear_screen

      # Get terminal size
      setup_display

      # Create panes and show skeleton immediately
      create_panes
      @current_view = @default_view || 'A'
      render_top_bar
      @panes[:left].text = "\n\n" + "  Loading...".fg(245)
      @panes[:left].refresh
      render_bottom_bar

      # First-time onboarding wizard
      if @db.get_sources(false).empty?
        run_onboarding_wizard
      end

      # Load initial view data in background so input loop starts immediately
      @initial_load_done = false
      Thread.new do
        begin
          @load_limit = 200
          case @default_view
          when 'N'
            @filtered_messages = @db.get_messages({is_read: false}, @load_limit, 0, light: true)
          when /^[0-9]$/, /^F\d+$/
            view = @views[@default_view]
            if view && view[:filters] && !view[:filters].empty?
              if view[:filters]['section_order']
                @section_order = view[:filters]['section_order'].dup
              end
              apply_view_filters(view)
            else
              @filtered_messages = @db.get_messages({}, @load_limit, 0, light: true)
              @current_view = 'A'
            end
          else
            @filtered_messages = @db.get_messages({}, @load_limit, 0, light: true)
            @current_view = 'A'
          end
          sort_messages
          @index = 0
          reset_threading
          restore_view_thread_mode
          @initial_load_done = true
          @needs_redraw = true
          # Preload the heavy mail gem so 'v' (attachments) doesn't lag
          require 'mail' rescue nil
        rescue => e
          File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "STARTUP ERROR: #{e.message}\n#{e.backtrace.first(5).join("\n")}" }
          @filtered_messages = []
          @initial_load_done = true
          @needs_redraw = true
        end
      end

      # Wait for initial data load before entering main loop
      until @initial_load_done
        sleep 0.05
      end

      # Flush stdin before loop (CRITICAL - FROM RTFM)
      $stdin.getc while $stdin.wait_readable(0)

      # Main loop (like RTFM)
      @running = true
      @pending_view_refresh = false
      @editing = false
      @needs_redraw = true
      loop do
        if @pending_view_refresh && !@editing
          @pending_view_refresh = false
          # Only reload view data if we're in a named view (not a folder browse or source view)
          unless @current_folder || @in_source_view
            # Remember selected message by ID so we can restore position after rebuild
            selected_msg = current_message
            selected_id = selected_msg['id'] if selected_msg
            view = @views[@current_view]
            if view && view[:filters] && !view[:filters].empty?
              apply_view_filters(view)
              sort_messages
            end
            # Force re-organization in threaded mode
            if @show_threaded
              reset_threading(true)
              organize_current_messages(true)
            end
            # Defer index restoration for threaded views (display_messages is empty
            # after reset_threading; it gets populated during render). For flat views,
            # resolve immediately since @filtered_messages is the navigation list.
            if @show_threaded
              @pending_restore_id = selected_id
              @index = 0
            elsif selected_id
              new_idx = @filtered_messages.index { |m| m['id'] == selected_id }
              max_idx = @filtered_messages.size - 1
              @index = new_idx || [@index, max_idx].min
            else
              @index = [@index, @filtered_messages.size - 1].min
            end
            @index = 0 if @index < 0
          end
          @needs_redraw = true
        end
        # Check if feedback expired
        if @feedback_expires_at && Time.now >= @feedback_expires_at
          @needs_redraw = true
        end
        if @needs_redraw && !@editing
          render_all
          @needs_redraw = false
        end
        # Check for mailto trigger (from wezterm or external script)
        check_mailto_trigger

        chr = getchr(2, flush: false)  # 2s timeout to check for new mail
        begin
          if chr
            # Clear sticky feedback (errors, "message sent") on any keypress
            if @feedback_sticky
              @feedback_sticky = false
              @feedback_expires_at = Time.now  # Expire now so render_bottom_bar clears it
            end
            @needs_redraw = false  # Handlers that need redraw call render_all directly
            handle_input_key(chr)
          else
            check_new_mail
          end
        rescue => e
          # Non-fatal: log and show feedback instead of crashing
          File.open('/tmp/heathrow-crash.log', 'a') do |f|
            loc = e.backtrace&.first&.sub(/^.*lib\/heathrow\//, '')
            f.puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ERROR: #{e.class}: #{e.message} at #{loc}"
            e.backtrace&.first(10)&.each { |l| f.puts "    #{l}" }
            f.puts
          end
          set_feedback("Error: #{e.message} (logged to /tmp/heathrow-crash.log)", 196, 5)
          @needs_redraw = true
        end
        break unless @running
      end
    ensure
      cleanup
    end
    
    def handle_input_key(chr)
      
      # Handle help mode: scroll keys stay in help, everything else exits
      if @in_help_mode
        case chr
        when 'S-DOWN', 'j', 'DOWN'
          @panes[:right].linedown
          return
        when 'S-UP', 'k', 'UP'
          @panes[:right].lineup
          return
        when 'S-RIGHT', 'TAB', 'PgDOWN', 'S-PgDOWN', ' ', 'SPACE'
          @panes[:right].pagedown
          return
        when 'S-LEFT', 'S-TAB', 'PgUP', 'S-PgUP'
          @panes[:right].pageup
          return
        when 'HOME'
          @panes[:right].top
          return
        when 'END'
          @panes[:right].bottom
          return
        when '?'
          if @showing_help
            show_extended_help
            @showing_help = false
          else
            show_help
          end
          return
        when '', nil
          # Ignore empty/partial escape sequences from held keys
          return
        else
          # Any other key exits help mode
          @in_help_mode = false
          @showing_help = false
          @panes[:right].content_update = true
          render_message_content
        end
      end
      
      # Debug log key presses and state
      
      # Special handling for source view
      if @current_view == 'S'
        case chr
        when 'a'
          if selected_source_has_items?
            add_source_item
          else
            add_new_source
          end
          return
        when 'e'
          edit_selected_source
          return
        when 'd'
          if selected_source_has_items?
            delete_source_item
          else
            delete_selected_source
          end
          return
        when 't'
          test_selected_source
          return
        when ' ', 'SPACE'
          toggle_selected_source
          return
        when 'j', 'DOWN'
          move_down
          render_sources_info  # Update right pane to show new selection
          return
        when 'k', 'UP'
          move_up
          render_sources_info  # Update right pane to show new selection
          return
        when 'ENTER', "\r", "\n"
          # Show messages from selected source
          if @filtered_messages[@index]
            source_id = @filtered_messages[@index]['id']
            show_source_messages(source_id)
          end
          return
        when 'ESC', "\e", 'q'
          @in_source_view = false
          @panes[:right].content_update = true
          switch_to_default_view
          return
        when 'A', 'N', '0'..'9',
             'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'
          @in_source_view = false
          @panes[:right].content_update = true
          # Let it fall through to regular handler to switch views
        when 'Y'
          copy_right_pane_to_clipboard
          return
        when 'c'
          pick_source_color
          return
        when 'p'
          set_source_poll_interval
          return
        when 'C-R'
          refresh_all
          show_sources  # Reload source list
          return
        when 'C-L'
          redraw_panes
          return
        when 'w', 'C-B', 'o', 'i', 'D', 'P'
          # Let these fall through to regular handler for UI controls and sorting
        else
          # Don't handle other keys in source view
          return
        end
      end
      
      # Context-sensitive feed/page management in views tied to RSS/web sources
      if (chr == 'a' || chr == 'd') && @current_view != 'S' && !@in_source_view
        source = current_view_item_source
        if source
          if chr == 'a'
            add_source_item_for(source)
          else
            delete_source_item_for(source)
          end
          return
        end
      end

      # Custom keybindings from heathrowrc (checked before built-in keys)
      if @config && (binding = @config.custom_bindings[chr])
        run_custom_binding(binding)
        return
      end

      case chr
      when 'q', 'Q'
        quit
      when '?'
        if @showing_help
          show_extended_help
        else
          show_help
        end
      when 'r'
        reply_to_message
      when 'e'
        reply_to_message(force_editor: true)
      when 'E'
        edit_message_content
      when 'R'
        toggle_read_status
      when 'M'
        mark_all_view_read(force_all: true)
      when 'g'
        reply_all_to_message
      when 'f'
        forward_message
      when 'y'
        copy_message_id
      when 'm'
        compose_new_message
      when 'C-R'  # Ctrl-R: refresh current view (sync its sources + reload)
        refresh_current_view
      when 'C-L'  # Ctrl-L: redraw panes only (no fetch)
        redraw_panes
      when 'j', 'DOWN'
        move_down
      when 'k', 'UP'
        move_up
      when 'h', 'LEFT'
        collapse_current_item
      when 'l', 'RIGHT'
        expand_current_item
      when 'ENTER'
        open_message
      when 'J'
        jump_to_date
      when 'x'
        open_message_external
      when 'HOME'
        go_first
      when 'END'
        go_last
      when 'PgDOWN'
        page_down
      when 'PgUP'
        page_up
      when 'L'
        load_more_messages
      when 'w'
        change_width
      when 'Y'
        copy_right_pane_to_clipboard
      when 'c'
        set_view_top_bg
      when 'C-B'
        cycle_border
      when 'o'
        cycle_sort_order
      when 'i'
        toggle_sort_invert
      when 'D'
        cycle_date_format
      when 'P'
        show_settings_popup
      when 'S-DOWN'
        @panes[:right].linedown
        @panes[:right].content_update = false
      when 'S-UP'
        @panes[:right].lineup
        @panes[:right].content_update = false
      when 'S-RIGHT', 'TAB'
        @panes[:right].pagedown
        @panes[:right].content_update = false
      when 'S-LEFT', 'S-TAB'
        @panes[:right].pageup
        @panes[:right].content_update = false
      when 'A'
        show_all_messages
      when 'N'
        show_new_messages
      when 'S'
        # Set flag BEFORE calling show_sources
        @in_source_view = true
        show_sources
      when 'C-F'
        edit_filter
      when 'K'
        kill_view
      when '0'..'9'
        switch_to_view(chr)
      when 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'
        switch_to_view(chr)
      when '}', 'C-DOWN'
        move_section(1)  # Move section down
      when '{', 'C-UP'
        move_section(-1)  # Move section up
      when ' ', 'SPACE'
        toggle_collapse_expand
      when 'G'
        # Cycle: flat → threaded → folder-grouped
        cycle_view_mode
      when 'u', 'U'
        # Unsee current message (remove from browsed set)
        unsee_current_message
      when 'S-SPACE'
        # Mark all browsed messages as permanently read
        mark_browsed_as_read
      when 't'
        toggle_tag
      when 'T'
        tag_all_toggle
      when 'C-T'
        tag_by_regex
      when 'n'
        jump_to_next_unread
      when 'p'
        jump_to_prev_unread
      when '*', '-'
        toggle_star
      when 'd'
        toggle_delete_mark
      when '<'
        purge_deleted
      when '/'
        notmuch_search
      when 'B'
        show_folder_browser
      when 'F'
        show_favorites_browser
      when '+'
        toggle_favorite_folder
      when 's'
        file_message
      when 'l'
        label_message
      when 'v'
        view_attachments
      when 'Z'
        open_in_timely
      when 'I'
        ai_assistant
      when 'V'
        toggle_inline_image
      when 'ESC', "\e"
        if @showing_image
          clear_inline_image
          @panes[:right].content_update = true
          render_message_content
        end
      end
    end
    
    # Run a custom keybinding defined in heathrowrc
    def run_custom_binding(binding)
      if binding[:action]
        # Call a Heathrow method by name
        method_name = binding[:action].to_sym
        if respond_to?(method_name, true)
          send(method_name)
        else
          set_feedback("Unknown action: #{method_name}", 196, 3)
        end
        return
      end

      return unless binding[:shell]

      cmd = binding[:shell].dup

      # Substitute placeholders (shell-escaped for safety)
      if cmd.include?('%q')
        prompt_text = binding[:prompt] || "Query: "
        query = bottom_ask(prompt_text, "")
        return if query.nil? || query.strip.empty?
        cmd.gsub!('%q', Shellwords.escape(query))
      end
      if cmd.include?('%f')
        msg = current_message
        if msg
          meta = msg['metadata']
          meta = JSON.parse(meta) if meta.is_a?(String) rescue {}
          file_path = meta['maildir_file'] || msg['external_id'] || ''
          cmd.gsub!('%f', Shellwords.escape(file_path))
        else
          cmd.gsub!('%f', '')
        end
      end
      if cmd.include?('%i')
        msg = current_message
        msg_id = msg ? (msg['message_id'] || msg['external_id'] || '') : ''
        cmd.gsub!('%i', Shellwords.escape(msg_id))
      end
      if cmd.include?('%s')
        msg = current_message
        subject = msg ? (msg['subject'] || '') : ''
        cmd.gsub!('%s', Shellwords.escape(subject))
      end

      # Run the command with terminal restored (same pattern as run_rtfm_picker)
      system("stty sane 2>/dev/null")
      Cursor.show
      system(cmd)

      # Restore raw mode and redraw UI
      $stdin.raw!
      $stdin.echo = false
      Cursor.hide
      Rcurses.clear_screen
      setup_display
      create_panes
      render_all
    end

    def add_new_source
      require_relative 'source_wizard'
      wizard = SourceWizard.new(@source_manager, @panes[:bottom], @panes[:right])
      source_id = wizard.run_wizard
      
      if source_id
        # Refresh the sources view
        show_sources
      else
        # Restore sources view
        render_sources_info
      end
    end
    
    def delete_selected_source
      return unless @filtered_messages[@index]
      source_id = @filtered_messages[@index]['id']
      
      confirm = bottom_ask("Delete source '#{@filtered_messages[@index]['subject']}'? (y/n): ", "")
      if confirm&.downcase == 'y'
        @source_manager.remove_source(source_id)
        show_sources
      end
    end

    # Check if the selected source has manageable sub-items (feeds, channels, etc.)
    def selected_source_has_items?
      return false unless @filtered_messages[@index]
      source_type = @filtered_messages[@index]['source_type']
      %w[rss web].include?(source_type)
    end

    # Add an item (feed/channel) to the selected source
    def add_source_item
      return unless @filtered_messages[@index]
      source_id = @filtered_messages[@index]['id']
      source = @db.get_source_by_id(source_id)
      return unless source

      config = source['config']
      config = JSON.parse(config) if config.is_a?(String)
      source_type = source['plugin_type'] || source['type']

      case source_type
      when 'rss'
        url = bottom_ask("Feed URL: ", "")
        return if url.nil? || url.strip.empty?
        title = bottom_ask("Title (optional): ", "")
        return if title.nil?

        feed = { 'url' => url.strip }
        feed['title'] = title.strip unless title.strip.empty?
        config['feeds'] ||= []
        config['feeds'] << feed
        @db.execute("UPDATE sources SET config = ? WHERE id = ?", [config.to_json, source_id])
        set_feedback("Added feed: #{feed['title'] || feed['url']}", 156, 3)
      when 'web'
        url = bottom_ask("Page URL: ", "")
        return if url.nil? || url.strip.empty?
        title = bottom_ask("Title (optional): ", "")
        return if title.nil?

        page = { 'url' => url.strip }
        page['title'] = title.strip unless title.strip.empty?
        config['pages'] ||= []
        config['pages'] << page
        @db.execute("UPDATE sources SET config = ? WHERE id = ?", [config.to_json, source_id])
        set_feedback("Added page: #{page['title'] || page['url']}", 156, 3)
      end

      show_sources
    end

    # Delete an item (feed/channel) from the selected source
    def delete_source_item
      return unless @filtered_messages[@index]
      source_id = @filtered_messages[@index]['id']
      source = @db.get_source_by_id(source_id)
      return unless source

      config = source['config']
      config = JSON.parse(config) if config.is_a?(String)
      source_type = source['plugin_type'] || source['type']

      items = case source_type
              when 'rss' then config['feeds'] || []
              when 'web' then config['pages'] || []
              else return
              end

      return if items.empty?

      item_name = source_type == 'rss' ? 'feed' : 'page'
      pick = pick_from_list(format_item_names(items),
                            title: "DELETE #{item_name.upcase}", prompt: "j/k to select, Enter to delete, ESC to cancel")
      return unless pick

      removed = items.delete_at(pick)
      name = removed['title'] || removed['url'] || 'item'

      confirm = bottom_ask("Delete '#{name}'? (y/n): ", "")
      return unless confirm&.downcase == 'y'

      case source_type
      when 'rss' then config['feeds'] = items
      when 'web' then config['pages'] = items
      end

      # Remove messages from this feed/page
      deleted_msgs = purge_item_messages(source_id, source_type, removed)

      @db.execute("UPDATE sources SET config = ? WHERE id = ?", [config.to_json, source_id])
      set_feedback("Deleted: #{name} (#{deleted_msgs} messages removed)", 156, 3)
      show_sources
    end

    # Generic picker: shows a list in the right pane with → cursor.
    # Returns selected index or nil on cancel.
    def pick_from_list(names, title: "SELECT", prompt: "j/k navigate, Enter select, ESC cancel")
      idx = 0

      render_pick = -> {
        lines = [title.b.fg(226), ""]
        names.each_with_index do |name, i|
          if i == idx
            lines << "→ #{name}".b.fg(226)
          else
            lines << "  #{name}".fg(252)
          end
        end
        lines << ""
        lines << prompt.fg(245)
        @panes[:right].text = lines.join("\n")
        @panes[:right].refresh
      }

      render_pick.call
      loop do
        chr = getchr
        case chr
        when 'j', 'DOWN', 'S-DOWN'
          idx = (idx + 1) % names.size
          render_pick.call
        when 'k', 'UP', 'S-UP'
          idx = (idx - 1) % names.size
          render_pick.call
        when 'ENTER', "\r", "\n"
          return idx
        when 'ESC', "\e", 'q'
          return nil
        end
      end
    end

    # Detect if current view is tied to an RSS/web source (for feed management)
    def current_view_item_source
      # Check if current view filters to a single source_id that is RSS or web
      view = @views && @views[@current_view]
      filters = view && view[:filters]
      return nil unless filters

      rules = filters['rules'] || filters[:rules]
      return nil unless rules

      source_rule = rules.find { |r| r['field'] == 'source_id' && r['op'] == '=' }
      return nil unless source_rule

      source = @db.get_source_by_id(source_rule['value'].to_i)
      return nil unless source

      stype = source['plugin_type'] || source['type']
      %w[rss web].include?(stype) ? source : nil
    end

    # Add item to a known source (called from non-Sources views)
    def add_source_item_for(source)
      config = source['config']
      config = JSON.parse(config) if config.is_a?(String)
      stype = source['plugin_type'] || source['type']

      case stype
      when 'rss'
        url = bottom_ask("Feed URL: ", "")
        return if url.nil? || url.strip.empty?
        title = bottom_ask("Title (optional): ", "")
        return if title.nil?

        feed = { 'url' => url.strip }
        feed['title'] = title.strip unless title.strip.empty?
        config['feeds'] ||= []
        config['feeds'] << feed
        @db.execute("UPDATE sources SET config = ? WHERE id = ?", [config.to_json, source['id']])
        set_feedback("Added feed: #{feed['title'] || feed['url']}", 156, 3)
      when 'web'
        url = bottom_ask("Page URL: ", "")
        return if url.nil? || url.strip.empty?
        title = bottom_ask("Title (optional): ", "")
        return if title.nil?

        page = { 'url' => url.strip }
        page['title'] = title.strip unless title.strip.empty?
        config['pages'] ||= []
        config['pages'] << page
        @db.execute("UPDATE sources SET config = ? WHERE id = ?", [config.to_json, source['id']])
        set_feedback("Added page: #{page['title'] || page['url']}", 156, 3)
      end
    end

    # Delete item from a known source (called from non-Sources views)
    def delete_source_item_for(source)
      config = source['config']
      config = JSON.parse(config) if config.is_a?(String)
      stype = source['plugin_type'] || source['type']

      items = case stype
              when 'rss' then config['feeds'] || []
              when 'web' then config['pages'] || []
              else return
              end
      return if items.empty?

      item_name = stype == 'rss' ? 'feed' : 'page'
      pick = pick_from_list(format_item_names(items),
                            title: "DELETE #{item_name.upcase}", prompt: "j/k to select, Enter to delete, ESC to cancel")
      return unless pick

      removed = items.delete_at(pick)
      name = removed['title'] || removed['url'] || 'item'

      confirm = bottom_ask("Delete '#{name}'? (y/n): ", "")
      return unless confirm&.downcase == 'y'

      case stype
      when 'rss' then config['feeds'] = items
      when 'web' then config['pages'] = items
      end

      deleted_msgs = purge_item_messages(source['id'], stype, removed)

      @db.execute("UPDATE sources SET config = ? WHERE id = ?", [config.to_json, source['id']])
      set_feedback("Deleted: #{name} (#{deleted_msgs} messages removed)", 156, 3)

      # Re-load the view to reflect removed messages
      reset_threading
      switch_to_view(@current_view) if @current_view
    end

    # Format item names with status indicators for picker
    # Does a quick HTTP check for feeds without a recent status
    def format_item_names(items)
      # Quick-check feeds that have no status or stale status (>1 hour)
      needs_check = items.select do |it|
        it.is_a?(Hash) && it['url'] && (it['last_status'].nil? || it['last_sync'].to_i < Time.now.to_i - 3600)
      end

      unless needs_check.empty?
        set_feedback("Checking #{needs_check.size} feeds...", 245, 0)
        needs_check.each do |it|
          ok = system("curl -sf --head --max-time 5 #{Shellwords.escape(it['url'])} >/dev/null 2>&1")
          it['last_status'] = ok ? (it['last_status'] || 'ok') : 'unreachable'
          it['last_sync'] = Time.now.to_i
        end
      end

      items.map do |it|
        name = it.is_a?(Hash) ? (it['title'] || it['url'] || it['name'] || '?') : it.to_s
        status = it.is_a?(Hash) ? it['last_status'] : nil
        if status == 'ok'
          "✓ #{name}"
        elsif status
          "✗ #{name}"
        else
          "  #{name}"
        end
      end
    end

    # Remove messages belonging to a deleted feed/page
    def purge_item_messages(source_id, source_type, item)
      name = item['title'] || item['url'] || item['name']
      case source_type
      when 'rss'
        # RSS messages have feed_title in metadata
        @db.execute("DELETE FROM messages WHERE source_id = ? AND json_extract(metadata, '$.feed_title') = ?",
                    [source_id, name])
      when 'web'
        @db.execute("DELETE FROM messages WHERE source_id = ? AND json_extract(metadata, '$.page_title') = ?",
                    [source_id, name])
      end
      @db.execute("SELECT changes() as cnt")[0]['cnt']
    end

    def toggle_selected_source
      return unless @filtered_messages[@index]
      source_id = @filtered_messages[@index]['id']
      @source_manager.toggle_source(source_id)
      show_sources
    end
    
    def test_selected_source
      return unless @filtered_messages[@index]
      
      source_data = @filtered_messages[@index]
      source_id = source_data['id']
      source_type = source_data['source_type'] || source_data['plugin_type'] || source_data['type']
      
      @panes[:bottom].text = " Testing #{source_data['subject'] || source_data['name']}...".fg(226)
      @panes[:bottom].refresh
      
      # Try to create source instance and test
      begin
        require 'ostruct'
        
        # Get the actual source from database
        source = @db.get_source_by_id(source_id)
        
        if source
          # Load the source module
          begin
            require_relative "../sources/#{source_type}"
          rescue LoadError
            @panes[:bottom].text = " Source module not found: #{source_type}".fg(196)
            @panes[:bottom].refresh
            sleep(2)
            return
          end
          
          # Create instance with proper structure
          source_wrapper = OpenStruct.new(
            id: source['id'],
            config: source['config'].is_a?(String) ? JSON.parse(source['config']) : source['config']
          )
          
          # Get the class
          class_name = case source_type
                       when 'rss' then 'RSS'
                       when 'webpage' then 'Webpage'
                       else source_type.capitalize
                       end
          source_class = Heathrow::Sources.const_get(class_name)
          
          # Create instance and test
          instance = begin
            source_class.new(source)
          rescue ArgumentError
            config = source['config']
            config = JSON.parse(config) if config.is_a?(String)
            source_class.new(source['name'], config || {}, @db)
          end
          
          if instance.respond_to?(:test_connection)
            progress = ->(msg) {
              @panes[:bottom].text = " #{msg}".fg(226)
              @panes[:bottom].refresh
            }
            result = instance.test_connection(&progress)

            if result[:success]
              set_feedback("✓ #{result[:message]}", 156, 0)
            else
              set_feedback("✗ #{result[:message]}", 196, 0)
              # Offer to remove failed feeds (RSS/web)
              if result[:failed_feeds] && !result[:failed_feeds].empty?
                result[:failed_feeds].each do |feed_name|
                  answer = bottom_ask("Remove failed feed '#{feed_name}'? [y/N] ")
                  if answer&.strip&.downcase == 'y'
                    feed_entry = instance.list_feeds.find { |f| (f[:title] || f[:url]) == feed_name }
                    if feed_entry
                      instance.remove_feed(feed_entry[:url])
                      set_feedback("Removed #{feed_name}", 156, 3)
                      render_sources_info
                    end
                  end
                end
              end
            end
          else
            set_feedback("Test not available for #{source_type} sources", 226, 0)
          end
        end
      rescue => e
        set_feedback("Error: #{e.message}", 196, 0)
      end
    end
    
    def update_window_title
      # Get view name - check for source filter first
      view_name = if @current_source_filter && @current_view == 'A'
        "Source: #{@current_source_filter}"
      elsif @views[@current_view]
        view = @views[@current_view]
        "[#{@current_view}] #{view[:name]}"
      elsif @in_source_view
        "Sources"
      else
        @view_names[@current_view] || @current_view
      end
      
      # Add message count with unread/total format if applicable (matching top bar)
      count_info = if @filtered_messages && !@filtered_messages.empty? && !@in_source_view
        total = @filtered_messages.size
        unread = @filtered_messages.count { |m| m['is_read'].to_i == 0 }
        " (#{unread}/#{total})"
      else
        ""
      end
      
      # Set window title using ANSI escape sequence (direct print, no subprocess)
      $stdout.print "\033]0;Heathrow: #{view_name}#{count_info}\007"
      $stdout.flush
    end
    
    def render_all
      # Organize messages if in threaded view
      if @show_threaded && !@in_source_view && @filtered_messages && !@filtered_messages.empty?
        organize_current_messages
      end

      update_window_title
      render_message_list
      render_top_bar
      # Only re-render right pane if it's not locked by another feature
      if @in_source_view
        render_sources_info
      elsif @panes[:right].content_update
        render_message_content
      end
      render_bottom_bar
    end
    
    def render_top_bar
      # Ensure we have messages loaded
      @filtered_messages ||= []
      
      # Get current view name and color
      view_name, view_color = case @current_view
      when 'A' 
        if @current_source_filter
          ["Source: #{@current_source_filter}", 39]  # Blue for source filter
        else
          ['All Messages', 226]  # Yellow for all messages
        end
      when 'N' 
        ['New Messages', 40]  # Green for new messages
      when 'S' 
        ['Sources', 201]  # Magenta for sources
      else
        view = @views[@current_view]
        if view
          ["[#{@current_view}] #{view[:name]}", 51]  # Cyan for custom views
        else
          ["View #{@current_view}", 51]
        end
      end
      
      # Get message counts
      if @current_view == 'S'
        # For sources view, show total source count
        total = @filtered_messages.size
        count_text = "#{total} sources"
      else
        # For message views, show unread/total plus starred
        if @cached_unread.nil?
          real_msgs = @filtered_messages.reject { |m| header_message?(m) }
          @cached_unread = real_msgs.count { |m| m['is_read'].to_i == 0 }
          @cached_starred = real_msgs.count { |m| m['is_starred'].to_i == 1 }
          @cached_total = real_msgs.size
        end
        unread = @cached_unread
        starred = @cached_starred
        total = @cached_total
        count_text = "#{unread} unread / #{total} msgs"
        count_text += " / #{starred}*" if starred > 0
      end
      
      # Build colored components
      title_part = " Heathrow - ".fg(248)
      view_part = view_name.b.fg(255)

      # Add sort order info (only for message views, not Sources)
      sort_part = ""
      if @current_view != 'S'
        sort_text = case @sort_order
                   when 'latest' then 'Latest'
                   when 'alphabetical' then 'A-Z'
                   when 'sender' then 'Sender'
                   when 'from' then 'From'
                   when 'unread' then 'Unread'
                   when 'source' then 'Source'
                   else @sort_order.capitalize
                   end
        # Add arrow - ↓ for normal order (o key), ↑ for inverted (i key)
        invert_indicator = @sort_inverted ? "↑" : "↓"
        sort_part = " [#{sort_text}#{invert_indicator}]".fg(252)
      end

      # Threading mode indicator
      mode_part = ""
      if @current_view != 'S'
        mode_part = " [#{thread_mode_label}]".fg(245)
      end

      # Position indicator
      pos_text = ""
      if @current_view != 'S' && !@filtered_messages.empty?
        display = @show_threaded ? (@display_messages || @filtered_messages) : @filtered_messages
        pos_text = " [#{@index + 1}/#{display.size}]"
      end

      count_part = " #{count_text}".fg(252)
      pos_part = pos_text.fg(252)

      # Calculate padding
      mode_plain = mode_part.gsub(/\e\[[0-9;]*m/, '')
      plain_length = " Heathrow - ".length + view_name.length + sort_part.gsub(/\e\[[0-9;]*m/, '').length + mode_plain.length + pos_text.length + " #{count_text}".length
      padding = @w - plain_length - 1
      padding = 1 if padding < 1
      spaces = " " * padding

      # Combine with colors - ensure message count is always visible
      full_text = title_part + view_part + sort_part + mode_part + pos_part + spaces + count_part
      
      # Apply per-view top bar background color if set
      view = @views[@current_view]
      custom_bg = view[:filters]['top_bg'] if view && view[:filters].is_a?(Hash)
      top_bg = custom_bg ? parse_color_value(custom_bg) || @topcolor : @topcolor
      if @panes[:top].bg != top_bg
        @panes[:top].bg = top_bg
        @panes[:top].full_refresh
      end

      # Set text and refresh only if changed
      @panes[:top].text = full_text
      @panes[:top].refresh
    end
    
    def render_message_list
      # Use threaded view if enabled (never for source view)
      if @show_threaded && @organizer && !@in_source_view
        return render_message_list_threaded
      end
      
      if @filtered_messages.empty?
        # Show empty message in center of pane
        empty_msg = case @current_view
        when 'N'
          "No new messages"
        when /\d/
          "No messages in this view"
        else
          "No messages"
        end

        empty_text = "\n" * (@panes[:left].h / 2 - 1) +
                     empty_msg.center(@panes[:left].w - 2).fg(245)
        @panes[:left].text = empty_text
        @panes[:left].refresh
        return
      end

      # Build ALL messages into one string - let rcurses handle scrolling
      lines = []
      @filtered_messages.each_with_index do |msg, i|
        lines << (@in_source_view ? format_source_line(msg, i == @index) : format_message_line(msg, i == @index))
      end

      # Calculate scroll position
      @panes[:left].scroll = true
      new_text = lines.join("\n")

      page_height = @panes[:left].h
      page_height -= 2 if @panes[:left].border

      old_ix = @panes[:left].ix
      if @filtered_messages.size > page_height
        scrolloff = 3
        max_scroll = @filtered_messages.size - page_height

        if @index - @panes[:left].ix < scrolloff
          @panes[:left].ix = [@index - scrolloff, 0].max
        elsif @panes[:left].ix + page_height - 1 - @index < scrolloff
          @panes[:left].ix = [@index + scrolloff - page_height + 1, max_scroll].min
        end
      else
        @panes[:left].ix = 0
      end

      @panes[:left].text = new_text
      @panes[:left].refresh
    end
    
    def format_message_line(msg, selected)
      # Extract message details
      timestamp = (parse_timestamp(msg['timestamp']) || "").ljust(6)
      sender = display_sender(msg)

      # Get subject, or use content preview, or "(no subject)"
      if msg['subject'] && !msg['subject'].empty?
        subject = msg['subject']
      elsif msg['content'] && !msg['content'].empty?
        # Use first line of content, cleaned up
        content_preview = msg['content'].lines.first || msg['content']
        content_preview = content_preview.strip.gsub(/\s+/, ' ')  # Normalize whitespace
        subject = content_preview[0..50] + (content_preview.length > 50 ? '…' : '')
      else
        subject = '(no subject)'
      end
      
      # Use source color (custom or default by source type)
      source_color = get_source_color(msg)
      
      # Calculate available width accounting for border, arrow, and potential star
      available_width = @panes[:left].w - 2  # Account for border
      available_width -= 2 if @panes[:left].border  # Extra space for border chars
      available_width -= 3  # Space for N flag + replied flag + indicator column (tag/star/attachment/D)
      
      # Truncate sender to fit (use display_width for CJK characters)
      sender_max = 15
      dw = Rcurses.display_width(sender)
      sender_display = if dw > sender_max
        truncate_to_width(sender, sender_max - 1) + '…'
      else
        sender + ' ' * [sender_max - dw, 0].max
      end

      # Build the line with timestamp, icon and sender
      icon = get_source_icon(msg['source_type'])
      line_prefix = "#{timestamp} #{icon} #{sender_display} "

      # Calculate remaining space for subject (use display_width for CJK)
      prefix_dw = Rcurses.display_width(line_prefix)
      subject_width = available_width - prefix_dw - 1  # -1 for safety
      subject_dw = Rcurses.display_width(subject)
      if subject_width > 0 && subject_dw > subject_width
        subject = truncate_to_width(subject, subject_width - 1) + '…'
        subject_dw = Rcurses.display_width(subject)
      end

      prefix_part = line_prefix
      subject_part = subject.strip
      total_dw = Rcurses.display_width(prefix_part) + Rcurses.display_width(subject_part)
      padding = " " * [available_width - total_dw, 0].max
      finalize_line(msg, selected, prefix_part, subject_part, source_color, padding)
    end
    
    def format_source_line(msg, selected)
      available_width = @panes[:left].w - 2
      available_width -= 2 if @panes[:left].border

      # Health indicator: ✓ or ✗
      health = msg['health_ok'] ? "✓".fg(40) : "✗".fg(196)

      # Source color
      src_color = get_source_color(msg)

      # Poll interval (short form)
      interval = (msg['poll_interval'] || 900).to_i
      poll_str = if interval <= 0 then "off"
                 elsif interval < 60 then "#{interval}s"
                 elsif interval < 3600 then "#{interval / 60}m"
                 else "#{interval / 3600}h"
                 end

      # Counts
      unread = msg['unread_count'].to_i
      total = msg['msg_count'].to_i
      count_str = "#{unread}/#{total}"

      # Fixed layout: [✓ ][name 20ch] [poll 3ch] [count right-aligned]
      name_max = 20
      name = msg['subject'].to_s
      name = name.length > name_max ? name[0..name_max - 2] + '…' : name.ljust(name_max)

      poll_col = poll_str.rjust(3)
      count_col = count_str.rjust(12)
      padding_len = [available_width - 2 - name_max - 1 - 3 - 1 - 12, 0].max
      padding = " " * padding_len

      line = "#{name} #{poll_col} #{count_col}#{padding}"

      if selected
        content = "#{name} #{poll_col} #{count_col}"
        health + " " + content.b.u.fg(src_color) + padding
      elsif msg['enabled'].to_i == 0
        health + " " + line.fg(240)
      else
        health + " " + name.fg(src_color) + " #{poll_col} #{count_col}#{padding}".fg(245)
      end
    end

    def source_health_check(source)
      stype = source['plugin_type'] || source['type']

      # Check last_error
      if source['last_error'] && !source['last_error'].to_s.empty?
        return { ok: false, msg: source['last_error'] }
      end

      # Check enabled
      unless source['enabled'] == 1
        return { ok: false, msg: "Source disabled" }
      end

      config = source['config']
      config = JSON.parse(config) if config.is_a?(String)
      config = {} unless config.is_a?(Hash)

      case stype
      when 'maildir'
        path = config['path'] || config['maildir_path']
        if path && !Dir.exist?(path.to_s)
          return { ok: false, msg: "Maildir path not found" }
        end
      when 'rss'
        feeds = config['feeds'] || []
        if feeds.empty?
          return { ok: false, msg: "No feeds configured" }
        end
        bad = feeds.select { |f| f['last_status'] && f['last_status'] != 'ok' }
        unless bad.empty?
          return { ok: false, msg: "#{bad.size} feed(s) failing" }
        end
      when 'web'
        pages = config['pages'] || []
        if pages.empty?
          return { ok: false, msg: "No pages configured" }
        end
      when 'messenger'
        cookie_file = File.join(Dir.home, '.heathrow', 'cookies', 'messenger.json')
        unless File.exist?(cookie_file)
          return { ok: false, msg: "No cookies (run setup)" }
        end
        begin
          cookies = JSON.parse(File.read(cookie_file))
          unless cookies['c_user'] && cookies['xs']
            return { ok: false, msg: "Missing auth cookies" }
          end
        rescue
          return { ok: false, msg: "Corrupt cookie file" }
        end
        error_file = File.join(Dir.home, '.heathrow', 'cookies', 'messenger_error.txt')
        if File.exist?(error_file)
          last_line = File.readlines(error_file).last.to_s.strip
          if last_line.include?('login_required')
            return { ok: false, msg: "Login expired" }
          end
        end
      when 'instagram'
        cookie_file = File.join(Dir.home, '.heathrow', 'cookies', 'instagram.json')
        unless File.exist?(cookie_file)
          return { ok: false, msg: "No cookies (run setup)" }
        end
        begin
          cookies = JSON.parse(File.read(cookie_file))
          unless cookies['sessionid']
            return { ok: false, msg: "Missing session cookie" }
          end
        rescue
          return { ok: false, msg: "Corrupt cookie file" }
        end
      when 'weechat'
        host = config['host'] || config['relay_host']
        unless host && !host.to_s.empty?
          return { ok: false, msg: "No relay host configured" }
        end
      when 'workspace'
        session_file = File.join(Dir.home, '.config', 'workspace-cli', 'sessions', 'session.json')
        unless File.exist?(session_file)
          return { ok: false, msg: "No session file. Run: workspace-cli auth login" }
        end
        refresh = `secret-tool lookup service workspace-cli account session 2>/dev/null`.strip
        if refresh.empty?
          return { ok: false, msg: "No refresh token in keyring. Run: workspace-cli auth login" }
        end
      end

      { ok: true, msg: "OK" }
    end

    def load_source_colors
      # Load all source colors into cache
      @source_colors = {}
      sources = @db.get_sources(false)
      
      sources.each do |source|
        @source_colors[source['id']] = source['color'] if source['color']
      end
    end
    
    def parse_color_value(val)
      return nil unless val
      val = val.to_s
      return val.to_i if val =~ /^\d+$/
      return val if val =~ /^[0-9a-fA-F]{6}$/
      nil
    end

    def get_source_color(msg)
      # For sources display, check if we have a custom color first
      if msg['source_color']
        c = parse_color_value(msg['source_color'])
        return c if c
      end

      # Try to get color from cache using source_id or id
      source_id = msg['source_id'] || msg['id']
      if source_id && @source_colors[source_id]
        c = parse_color_value(@source_colors[source_id])
        return c if c
      end
      
      # Fallback to theme-defined colors by source type
      source_type = (msg['source_type'] || msg['plugin_type']).to_s.downcase
      t = theme
      key = :"source_#{source_type == 'email' ? 'maildir' : source_type}"
      t[key] || t[:source_default] || 15
    end
    
    # Source management methods
    
    def edit_selected_source
      return unless @filtered_messages[@index]
      
      source_config = @filtered_messages[@index]
      source = @db.get_all_sources.find { |s| s['id'] == source_config['id'] }
      return unless source
      
      # Show edit options in right pane
      options = []
      options << "EDIT SOURCE: #{source['name']}".b.fg(226)
      options << "=" * 40
      options << ""
      options << "What would you like to edit?"
      options << ""
      options << "1. Change color"
      options << "2. Change name"
      options << "3. Change poll interval"
      options << "4. Toggle enabled/disabled"
      options << ""
      options << "Enter number (1-4) or ESC to cancel"
      
      @panes[:right].text = options.join("\n")
      @panes[:right].refresh
      
      # Get user choice
      choice = bottom_ask("Edit option (1-4): ", "")
      
      if choice && !choice.empty?
        case choice
        when '1'
          edit_source_color(source)
        when '2'
          edit_source_name(source)
        when '3'
          edit_source_interval(source)
        when '4'
          @source_manager.toggle_source(source['id'])
        end
        
        load_source_colors
      end
      
      show_sources
    end
    
    def edit_source_color(source)
      # Use the same color picker as the wizard
      begin
        wizard = Heathrow::SourceWizard.new(@source_manager, @panes[:bottom], @panes[:right])
        selected_color = wizard.select_color
        
        if selected_color
          # Update the source color in database
          @db.execute("UPDATE sources SET color = ? WHERE id = ?", selected_color, source['id'])
          # Reload sources to get updated values
          @source_manager.load_sources
          
          @panes[:bottom].text = " Color updated to #{selected_color}!".fg(selected_color)
          @panes[:bottom].refresh
          sleep(1)
        end
      rescue => e
        @panes[:bottom].text = " Error: #{e.message}".fg(196)
        @panes[:bottom].refresh
        sleep(4)  # Stay longer for error messages
      end
    end
    
    def edit_source_name(source)
      current_name = source['name']
      new_name = bottom_ask("New name (current: #{current_name}): ", current_name)
      
      if new_name && !new_name.empty? && new_name != current_name
        @db.execute("UPDATE sources SET name = ? WHERE id = ?", new_name, source['id'])
        # Reload sources to get updated values
        @source_manager.load_sources
        
        @panes[:bottom].text = " Name updated successfully!".fg(156)
        @panes[:bottom].refresh
        sleep(1)
      end
    end
    
    def edit_source_interval(source)
      current_interval = source['poll_interval']
      new_interval = bottom_ask("Poll interval in seconds (current: #{current_interval}): ", current_interval.to_s)
      
      if new_interval && !new_interval.empty? && new_interval.to_i > 0
        @db.execute("UPDATE sources SET poll_interval = ? WHERE id = ?", new_interval.to_i, source['id'])
        # Reload sources to get updated values
        @source_manager.load_sources
        
        @panes[:bottom].text = " Poll interval updated successfully!".fg(156)
        @panes[:bottom].refresh
        sleep(1)
      end
    end
    
    def show_source_messages(source_id)
      @current_view = 'A'  # Use All Messages view but filtered
      @in_source_view = false
      @panes[:right].content_update = true
      
      # Get source name for display
      source = @source_manager.sources[source_id]
      @current_source_filter = source ? source['name'] : source_id
      
      # Get messages from this source
      @filtered_messages = @db.get_messages({source_id: source_id}, nil, 0, light: true)
      sort_messages
      @index = 0
      render_all
    end
    
    def show_sources
      flush_pending_read
      @current_view = 'S'
      @in_source_view = true
      @panes[:right].content_update = true
      @current_source_filter = nil
      show_loading("Loading sources...")

      # Reset threading state when changing views
      reset_threading
      
      # Reload source colors to ensure they're fresh
      load_source_colors
      
      # Convert sources to pseudo-messages for display in left pane
      sources = @db.get_all_sources
      stats = @db.get_source_stats  # Single query for all source counts
      @filtered_messages = sources.map do |source|
          s = stats[source['id']] || { count: 0, unread: 0 }
          count = s[:count]
          unread_count = s[:unread]

          # Health check
          health = source_health_check(source)

          msg = {
            'id' => source['id'],
            'source_id' => source['id'],
            'sender' => (source['plugin_type'] || 'unknown').capitalize,
            'subject' => source['name'],
            'content' => format_poll_interval(source['poll_interval']),
            'timestamp' => source['last_poll'] || Time.now.to_s,
            'is_read' => source['enabled'] == 1 ? 1 : 0,
            'is_starred' => 0,
            'source_type' => source['plugin_type'],
            'source_color' => source['color'],
            'msg_count' => count,
            'unread_count' => unread_count,
            'poll_interval' => source['poll_interval'],
            'health_ok' => health[:ok],
            'health_msg' => health[:msg],
            'enabled' => source['enabled']
          }
          msg
        end
      
      # Apply current sort order to sources
      sort_messages
      @index = 0
      
      # Render everything
      render_all
      render_sources_info
    end
    
    def show_all_messages
      flush_pending_read
      invalidate_counts
      @current_view = 'A'
      @current_folder = nil
      @in_source_view = false
      @panes[:right].content_update = true
      @current_source_filter = nil
      @sort_order = @config.rc('sort_order', 'latest')
      @sort_inverted = false
      @last_rendered_index = nil  # Force right pane refresh

      # Restore per-view threading mode
      reset_threading
      restore_view_thread_mode

      # Show view name instantly
      render_top_bar

      @load_limit = 200
      @filtered_messages = @db.get_messages({}, @load_limit, 0, light: true)
      sort_messages
      @index = 0
      render_all
      track_browsed_message
    end

    def render_message_content
      current_msg = current_message

      # Reset scroll position when switching messages
      if @last_rendered_index != @index
        @panes[:right].ix = 0
        @last_rendered_index = @index
        clear_inline_image
      end

      unless current_msg
        @panes[:right].text = ""
        @panes[:right].refresh
        return
      end

      msg = current_msg

      # Lazily load full content if this was a light query result
      # Light query uses substr(content,1,200), so reload if content is short or missing
      # Skip for source view (pseudo-messages share IDs with real messages)
      if msg['id'] && !msg['is_header'] && !msg['_full_loaded'] && !@in_source_view
        full = @db.get_message(msg['id'])
        if full
          msg.merge!(full)
          msg['_full_loaded'] = true
        end
      end

      # Special handling for headers (channel headers, thread headers, etc.)
      if header_message?(msg)
        render_header_summary(msg)
        return
      end
      
      # Format message header
      header = []
      
      # Special handling for RSS/HN messages
      if msg['source_type'] == 'rss' || msg['source_type'] == 'hacker_news'
        header << "📰 #{msg['subject']}".b.fg(226) if msg['subject']
        
        # Extract metadata from raw_data if available
        if msg['raw_data']
          begin
            raw = JSON.parse(msg['raw_data'])
            
            # Add feed title and author
            if raw['feed_title']
              author_info = raw['author'] ? "#{raw['feed_title']} - #{raw['author']}" : raw['feed_title']
              header << "Source: #{author_info}".fg(39)
            elsif raw['author']
              header << "Author: #{raw['author']}".fg(39)
            end
            
            # Add categories/tags
            if raw['categories'] && raw['categories'].is_a?(Array) && !raw['categories'].empty?
              header << "Tags: #{raw['categories'].join(', ')}".fg(245)
            end
            
            # Add link
            if raw['link']
              header << "Link: #{raw['link']}".fg(33)
            end
          rescue => e
            # Fallback to regular display if JSON parsing fails
          end
        end
      else
        # Regular message display
        header << "From: #{msg['sender']}".fg(2) if msg['sender']
        # Show recipients (To field, already parsed by normalize_message_row)
        to = msg['recipients'] || msg['recipient']
        if to
          to_str = to.is_a?(Array) ? to.join(', ') : to.to_s
          header << "To: #{to_str}".fg(2) unless to_str.empty?
        end
        # Show CC recipients (already parsed by normalize_message_row)
        cc = msg['cc']
        if cc
          cc_str = cc.is_a?(Array) ? cc.join(', ') : cc.to_s
          header << "Cc: #{cc_str}".fg(2) unless cc_str.empty?
        end
        # For weechat, show channel name from metadata instead of content preview
        meta = msg['metadata']
        if meta.is_a?(Hash) && meta['channel_name']
          header << "Subject: #{meta['channel_name']}".b.fg(1)
        elsif msg['subject']
          header << "Subject: #{msg['subject']}".b.fg(1)
        end
      end
      
      # Parse timestamp using helper method
      date_str = parse_timestamp(msg['timestamp'], '%Y-%m-%d %H:%M:%S') || "Unknown date"

      header << "Date: #{date_str}".fg(240)
      if msg['source_type']
        source_label = case msg['source_type']
        when 'rss' then 'RSS Feed'
        when 'hacker_news' then 'Hacker News'
        else msg['source_type'].capitalize
        end
        header << "Type: #{source_label}".fg(get_source_color(msg))
      end

      # Show labels (if any beyond the folder name, already parsed by normalize_message_row)
      labels = msg['labels']
      labels = [] unless labels.is_a?(Array)
      if labels.size > 0
        # Skip folder name (first label) if it matches the folder
        display_labels = labels.reject { |l| l == msg['folder'] }
        unless display_labels.empty?
          header << "Labels: #{display_labels.join(', ')}".fg(51)
        end
      end
      
      header << ("─" * 60).fg(238)
      
      # Format message body — prefer HTML rendered via w3m
      pane_w = @panes[:right].w rescue 80
      render_width = [pane_w - 2, 40].max
      content = nil
      if msg['html_content'] && !msg['html_content'].to_s.strip.empty?
        content = html_to_text(msg['html_content'], render_width)
      end
      content ||= msg['content'] || '(No content)'
      # Detect raw HTML in content (e.g. HTML-only emails imported before html_content existed)
      if content =~ /\A\s*(<(!DOCTYPE|html|head|body)\b)/i
        content = html_to_text(content, render_width) || content
      end

      # For RSS/HN, add extra formatting and info
      if msg['source_type'] == 'rss' || msg['source_type'] == 'hacker_news'
        content_parts = []
        content_parts << "📄 Article Summary:".b.fg(226)
        content_parts << ""
        
        # Word wrap the content for better readability
        wrapped_lines = []
        content.split("\n").each do |line|
          if line.length > 80
            # Simple word wrapping at 80 characters
            words = line.split(' ')
            current_line = ""
            words.each do |word|
              if current_line.empty?
                current_line = word
              elsif (current_line + " " + word).length <= 80
                current_line += " " + word
              else
                wrapped_lines << current_line
                current_line = word
              end
            end
            wrapped_lines << current_line unless current_line.empty?
          else
            wrapped_lines << line
          end
        end
        
        content_parts.concat(wrapped_lines)
        
        # Add note about full content
        content_parts << ""
        content_parts << "─" * 40
        content_parts << ""
        content_parts << "📌 Note: This is a summary from the RSS feed.".fg(245)
        content_parts << "   Most RSS feeds only provide excerpts, not full articles.".fg(245)
        content_parts << "   Press 'x' to read the complete article in your browser.".fg(156)
        
        # Add helpful instructions
        content_parts << ""
        content_parts << "─" * 40
        content_parts << "💡 Keyboard Shortcuts:".b.fg(156)
        content_parts << ""
        content_parts << "  x     - Open full article in browser".fg(250)
        content_parts << "  SPACE - Toggle read/unread status".fg(250)
        content_parts << "  s     - Star/unstar this article".fg(250)
        content_parts << "  j/k   - Navigate between messages".fg(250)
        content_parts << "  ENTER - Expand/collapse in left pane".fg(250)
        
        content = content_parts.join("\n")
      end
      
      # Ensure content is UTF-8 compatible (handle emails with various encodings)
      # Create a mutable copy if frozen, then fix encoding
      content = content.dup if content.frozen?

      if content.encoding != Encoding::UTF_8
        content = content.force_encoding('UTF-8').scrub('?')
      elsif !content.valid_encoding?
        content = content.scrub('?')
      end

      # Colorize email content (quote levels + signature)
      content = colorize_email_content(content)

      # Store maildir file path for calendar parser (metadata already parsed by normalize_message_row)
      meta = msg['metadata']
      @_current_render_msg_file = meta['maildir_file'] if meta.is_a?(Hash)

      # Attachment list under header, before body
      att_text = format_attachments(msg['attachments'])

      # Check for images (HTML <img> tags + attachment URLs) and show hint
      image_hint = nil
      img_count = 0
      # Count from attachments
      img_count += image_urls_from_attachments(msg).size
      # Count from HTML
      html = msg['html_content']
      if (!html || html.to_s.strip.empty?) && msg['content'] =~ /\A\s*<(!DOCTYPE|html|head|body)\b/i
        html = msg['content']
      end
      if html && !html.to_s.strip.empty?
        img_count += extract_image_urls(html).select { |u| u.start_with?('http') }.size
      end
      if img_count > 0
        image_hint = "#{img_count} image#{img_count > 1 ? 's' : ''}, press V to view".fg(33)
      end
      html_hint = message_has_html?(msg) ? "HTML mail, press x to open in browser".fg(39) : nil

      # Parse calendar invites (ICS attachments)
      cal_text = format_calendar_event(msg['attachments'])

      full_text = header.join("\n")
      full_text += "\n" + att_text if att_text
      full_text += "\n" + image_hint if image_hint
      full_text += "\n" + html_hint if html_hint
      full_text += "\n\n" + cal_text if cal_text
      full_text += "\n\n" + content
      
      @panes[:right].text = full_text
      @panes[:right].refresh

    end

    def render_header_summary(header_msg)
      # Render a summary view for group headers (channels, threads, etc.)
      lines = []

      # Title
      title = header_msg['subject'] || header_msg['channel_name'] || 'Group'
      lines << title.b.fg(226)
      lines << ""

      # Message count
      count_text = header_msg['content'] || "0 messages"
      lines << count_text.fg(245)
      lines << ""

      # Unread count if available
      if header_msg['is_channel_header'] && @organizer && @organizer.respond_to?(:get_channel_info)
        begin
          channel_info = @organizer.get_channel_info(header_msg['channel_id'])
          if channel_info && channel_info[:unread_count] && channel_info[:unread_count] > 0
            lines << "#{channel_info[:unread_count]} unread".fg(208)
            lines << ""
          end
        rescue => e
          # Silently ignore if method doesn't work
        end
      elsif header_msg['is_thread_header'] && @organizer && @organizer.respond_to?(:get_thread_info)
        begin
          thread_info = @organizer.get_thread_info(header_msg['thread_id'])
          if thread_info && thread_info[:unread_count] && thread_info[:unread_count] > 0
            lines << "#{thread_info[:unread_count]} unread".fg(208)
            lines << ""
          end
        rescue => e
          # Silently ignore if method doesn't work
        end
      end

      # Hint
      lines << "Press Enter to expand/collapse".fg(240)
      lines << "Press j/k to navigate".fg(240)

      # Display at top of pane (no vertical centering)
      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh
    end

    # Run an external editor, restoring terminal state before/after
    def run_editor(path, cursor_line: nil, insert_mode: false)
      editor = ENV['EDITOR'] || 'vim'
      # Restore terminal to cooked mode for the editor
      system("stty sane 2>/dev/null")
      print "\e[?25h"  # show cursor
      vim_args = ""
      if editor =~ /vim?\b/
        vim_args += " +#{cursor_line}" if cursor_line
        vim_args += " -c 'startinsert!'" if insert_mode
      end
      system("#{editor}#{vim_args} #{Shellwords.escape(path)}")
      success = $?.success?
      # Restore raw mode for rcurses
      $stdin.raw!
      $stdin.echo = false
      print "\e[?25l"  # hide cursor
      Rcurses.clear_screen
      setup_display
      create_panes
      render_all
      success
    end

    def set_feedback(message, color = 156, duration = 3)
      @feedback_message = message
      @feedback_color = color
      # duration 0 or errors: persist until next user action (cleared by clear_sticky_feedback)
      @feedback_sticky = (duration == 0 || color == 196)
      @feedback_expires_at = if @feedback_sticky
        nil  # Never auto-expire; cleared on keypress
      else
        Time.now + duration
      end
      if @panes[:bottom]
        @panes[:bottom].text = " #{message}".fg(color)
        @panes[:bottom].refresh
      end
    end
    
    def render_bottom_bar
      # Check if there's an active feedback message
      if @feedback_expires_at && Time.now < @feedback_expires_at
        if @panes[:bottom]
          @panes[:bottom].text = " #{@feedback_message}".fg(@feedback_color || 156)
          @panes[:bottom].refresh
        end
        return
      elsif @feedback_expires_at && Time.now >= @feedback_expires_at
        @feedback_message = nil
        @feedback_expires_at = nil
      end

      # Check if we should show the filter config message
      if @current_view =~ /^([0-9]|F\d{1,2})$/ && (@views[@current_view].nil? || @views[@current_view][:filters].nil? || @views[@current_view][:filters].empty?)
        @panes[:bottom].text = " View #{@current_view} not configured. Press F to set up filters.".fg(226)
        @panes[:bottom].refresh
        return
      end

      # Show key hints with context
      keys = %w[q:Quit ?:Help A:All N:New 0-9:Views Space:Fold t:Tag T:All s:Save B:Browse F:Fav]
      @panes[:bottom].text = " " + keys.join(" | ").fg(245)
      @panes[:bottom].refresh
    end
    
    def refresh_panes
      @panes.each { |_, pane| pane.refresh }
    end
    
    def update_display
      # Only update panes that have changed
      # This is a placeholder for optimization
      refresh_panes
    end
    
    # Advance index to next item (no wrap, no re-render)
    def advance_index
      message_size = message_count
      @index = [@index + 1, message_size - 1].min if message_size > 0
    end

    # Shared navigation: update index, then re-render
    def navigate
      clear_inline_image if @showing_image
      @panes[:right].content_update = true
      msg_count = message_count
      return if msg_count == 0
      # Flush read mark for the message we're LEAVING before changing index
      flush_pending_read
      yield msg_count
      # Auto-load more when near the end (95% threshold)
      check_load_more
      # Track the message we just arrived at
      track_browsed_message
      render_message_list
      render_top_bar
      render_message_content
      render_bottom_bar
    end

    def check_load_more
      return unless @load_limit && @filtered_messages
      return if @filtered_messages.size < @load_limit  # Haven't hit the limit yet
      display_size = message_count
      return if display_size == 0
      return unless @index >= display_size - 10
      return if @last_autoload_index == @index
      @last_autoload_index = @index
      load_more_messages
    end

    def load_more_messages
      return unless @load_limit
      # Remember current message so we can restore position after reload
      cur = current_message
      cur_id = cur['id'] if cur
      old_count = @filtered_messages.size
      @load_limit += 200

      if @current_folder
        light_cols = "id, source_id, external_id, thread_id, parent_id, sender, sender_name, recipients, subject, substr(content, 1, 200) as content, timestamp, received_at, read AS is_read, starred AS is_starred, archived, labels, metadata, attachments, folder, replied"
        results = @db.execute(
          "SELECT #{light_cols} FROM messages WHERE folder = ? ORDER BY timestamp DESC LIMIT ?",
          @current_folder, @load_limit
        )
        @filtered_messages = results
      elsif @current_view == 'A'
        @filtered_messages = @db.get_messages({}, @load_limit, 0, light: true)
      elsif @current_view == 'N'
        @filtered_messages = @db.get_messages({ read: false }, @load_limit, 0, light: true)
      elsif @views[@current_view]
        view = @views[@current_view]
        apply_view_filters_with_limit(view, @load_limit)
      end

      sort_messages
      new_count = @filtered_messages.size
      return if new_count <= old_count

      # In threaded mode, set pending restore so the threaded rebuild finds our position
      if @show_threaded && cur_id
        @pending_restore_id = cur_id
      end

      # Force threaded view to rebuild organizer with new messages
      if @show_threaded
        organize_current_messages(true)
      end

      set_feedback("Loaded #{new_count} messages (+#{new_count - old_count})", 156, 2)
      render_message_list
      render_top_bar
    end

    # Ensure all feeds/channels from a source have at least some messages loaded
    def ensure_all_feeds_loaded(source_id)
      source = @db.get_source_by_id(source_id)
      return unless source
      config = source['config']
      config = JSON.parse(config) if config.is_a?(String)
      return unless config.is_a?(Hash)

      stype = source['plugin_type']
      return unless stype == 'rss'

      feeds = config['feeds'] || []
      return if feeds.empty?
      expected = feeds.map { |f| f['title'] || f['url'] }

      # Find which feeds are already in loaded messages
      loaded_ids = Set.new
      loaded_feeds = Set.new
      @filtered_messages.each do |msg|
        loaded_ids << msg['id']
        meta = msg['metadata']
        meta = JSON.parse(meta) if meta.is_a?(String) rescue nil
        next unless meta.is_a?(Hash)
        loaded_feeds << meta['feed_title'] if meta['feed_title']
      end

      missing = expected - loaded_feeds.to_a
      return if missing.empty?

      # Load latest 20 messages per missing feed using json_extract
      light_cols = "id, source_id, external_id, thread_id, parent_id, sender, sender_name, recipients, subject, substr(content, 1, 200) as content, timestamp, received_at, read AS is_read, starred AS is_starred, archived, labels, metadata, attachments, folder, replied"
      missing.each do |feed_name|
        rows = @db.execute(
          "SELECT #{light_cols} FROM messages WHERE source_id = ? AND json_extract(metadata, '$.feed_title') = ? ORDER BY timestamp DESC LIMIT 20",
          source_id, feed_name
        )
        rows = rows.reject { |r| loaded_ids.include?(r['id']) }
        rows = rows.map do |r|
          r = r.dup
          r['metadata'] = JSON.parse(r['metadata']) if r['metadata'].is_a?(String) rescue nil
          r['labels'] = JSON.parse(r['labels']) if r['labels'].is_a?(String) rescue nil
          r['attachments'] = JSON.parse(r['attachments']) if r['attachments'].is_a?(String) rescue nil
          r['recipients'] = JSON.parse(r['recipients']) if r['recipients'].is_a?(String) rescue nil
          r
        end
        @filtered_messages.concat(rows)
      end
    rescue => e
      File.open('/tmp/heathrow-crash.log', 'a') { |f|
        f.puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ensure_all_feeds_loaded: #{e.class}: #{e.message}"
        f.puts "  #{e.backtrace&.first(3)&.join("\n  ")}"
      }
    end

    def build_db_filters(view)
      filters = view[:filters] || {}
      db_filters = {}
      if filters['rules'].is_a?(Array)
        filters['rules'].each do |rule|
          field = rule['field']
          value = rule['value']
          case rule['op']
          when '='  then db_filters[field.to_sym] = value
          when 'like'
            case field
            when 'search'  then db_filters[:search] = value
            when 'sender'  then db_filters[:sender_pattern] = value
            when 'subject' then db_filters[:subject_pattern] = value
            when 'folder'  then db_filters[:maildir_folder] = value
            when 'label'   then db_filters[:label] = value
            when 'source'  then db_filters[:source_name] = value
            end
          end
        end
      end
      db_filters
    end

    def apply_view_filters_with_limit(view, limit)
      db_filters = build_db_filters(view)
      @filtered_messages = @db.get_messages(db_filters, limit, 0, light: true)
    end

    # Navigation methods
    def move_down
      navigate { |n| @index = (@index + 1) % n }
    end

    def move_up
      navigate { |n| @index = @index == 0 ? n - 1 : @index - 1 }
    end

    def page_down
      navigate { |n| @index = [@index + @panes[:left].h - 2, n - 1].min }
    end

    def page_up
      navigate { |n| @index = [@index - (@panes[:left].h - 2), 0].max }
    end

    def go_first
      navigate { |_| @index = 0 }
    end

    def go_last
      navigate { |n| @index = n - 1 }
    end

    def jump_to_date
      input = bottom_ask("Jump to date (yyyy-mm-dd): ", Time.now.strftime('%Y-%m-%d'))
      return unless input && input =~ /\d{4}-\d{2}-\d{2}/

      target_ts = Time.parse("#{input} 00:00:00").to_i rescue nil
      return set_feedback("Invalid date", 196, 2) unless target_ts

      # Load messages around this date if needed
      # Find how many messages are newer than this date
      count_newer = @db.db.get_first_value(
        "SELECT COUNT(*) FROM messages WHERE timestamp >= ? AND (archived = 0 OR archived IS NULL)",
        [target_ts]
      ) || 0

      if count_newer > @load_limit.to_i
        @load_limit = count_newer + 100
        # Reload with expanded limit
        if @current_folder
          light_cols = "id, source_id, external_id, thread_id, parent_id, sender, sender_name, recipients, subject, substr(content, 1, 200) as content, timestamp, received_at, read AS is_read, starred AS is_starred, archived, labels, metadata, attachments, folder, replied"
          @filtered_messages = @db.execute(
            "SELECT #{light_cols} FROM messages WHERE folder = ? ORDER BY timestamp DESC LIMIT ?",
            @current_folder, @load_limit
          )
        elsif @current_view == 'A'
          @filtered_messages = @db.get_messages({}, @load_limit, 0, light: true)
        elsif @current_view == 'N'
          @filtered_messages = @db.get_messages({is_read: false}, @load_limit, 0, light: true)
        elsif @views[@current_view]
          apply_view_filters_with_limit(@views[@current_view], @load_limit)
        end
        sort_messages
      end

      # Find the first message on or before this date
      idx = @filtered_messages.index { |m| m['timestamp'].to_i <= target_ts }
      if idx
        @index = idx
        set_feedback("Jumped to #{input} (#{@filtered_messages.size} messages loaded)", 156, 2)
      else
        @index = @filtered_messages.size - 1
        set_feedback("No messages found at #{input}, showing oldest", 226, 2)
      end
      render_all
    end
    
    # View switching
    def show_new_messages
      flush_pending_read
      invalidate_counts
      @current_view = 'N'
      @current_folder = nil
      @in_source_view = false
      @panes[:right].content_update = true
      @sort_order = @config.rc('sort_order', 'latest')
      @sort_inverted = false
      @last_rendered_index = nil  # Force right pane refresh

      # Restore per-view threading mode
      reset_threading
      restore_view_thread_mode

      render_top_bar

      @load_limit = 200
      @filtered_messages = @db.get_messages({is_read: false}, @load_limit, 0, light: true)
      sort_messages
      @index = 0
      render_all
      track_browsed_message
    end

    def switch_to_default_view
      dv = @default_view || 'A'
      case dv
      when 'A' then show_all_messages
      when 'N' then show_new_messages
      else switch_to_view(dv)
      end
    end

    def switch_to_view(key)
      flush_pending_read
      invalidate_counts
      @current_view = key
      @current_folder = nil
      @in_source_view = false
      @panes[:right].content_update = true
      @last_rendered_index = nil  # Force right pane refresh

      # Restore per-view threading mode
      reset_threading
      restore_view_thread_mode

      render_top_bar

      view = @views[key]

      # Restore per-view sort order, or use global default
      if view && view[:filters].is_a?(Hash) && view[:filters]['view_sort_order']
        @sort_order = view[:filters]['view_sort_order']
        @sort_inverted = view[:filters]['view_sort_inverted'] || false
      else
        @sort_order = @config.rc('sort_order', 'latest')
        @sort_inverted = false
      end

      # Restore saved section order for this view
      if view && view[:filters] && view[:filters]['section_order']
        @section_order = view[:filters]['section_order'].dup
      end

      @load_limit = 200
      if view && view[:filters] && !view[:filters].empty?
        apply_view_filters(view)
        sort_messages
        @index = 0
        render_all
        track_browsed_message
      else
        @filtered_messages = []
        @index = 0
        @panes[:right].text = ""
        @panes[:right].refresh
        render_all
      end
    end

    def apply_view_filters(view)
      filters = view[:filters] || {}

      # Check for special filter types
      if filters['special'] == 'uncategorized'
        # Get all messages first
        all_messages = @db.get_messages({}, 1000, 0, light: true)

        # Get messages from all other configured views
        categorized_ids = Set.new

        @views.each do |view_key, other_view|
          next if view_key == @current_view  # Skip self
          if other_view && other_view[:filters] && !other_view[:filters].empty? && other_view[:filters]['special'] != 'uncategorized'
            # Convert filters for database
            symbolized_filters = {}
            other_view[:filters].each do |key, value|
              symbolized_filters[key.to_sym] = value
            end

            view_messages = @db.get_messages(symbolized_filters, 1000, 0, light: true)
            view_messages.each { |msg| categorized_ids.add(msg['id']) }
          end
        end

        # Filter to only uncategorized messages
        @filtered_messages = all_messages.reject { |msg| categorized_ids.include?(msg['id']) }
      else
        db_filters = build_db_filters(view)

        # Legacy simple filters (no rules array)
        if !filters['rules'].is_a?(Array)
          filters.each do |key, value|
            next if key == 'rules'
            db_filters[key.to_sym] = value
          end
        end

        @filtered_messages = @db.get_messages(db_filters, 1000, 0, light: true)

        # For source_id-filtered views (e.g., RSS): ensure all feeds/channels are represented
        if db_filters[:source_id] && @show_threaded
          ensure_all_feeds_loaded(db_filters[:source_id].to_i)
        end
      end
    end
    
    # Message operations
    def collapse_current_item
      return unless @show_threaded && @organizer
      
      msg = current_message
      return unless msg
      
      # Save current position before collapsing
      @saved_positions ||= {}
      
      if msg['is_dm_header']
        dm_key = msg['channel_id']
        if @sort_order == 'conversation'
          return if @dm_collapsed.fetch(dm_key, true)
          @dm_collapsed[dm_key] = true
        else
          return if @dm_section_collapsed
          @dm_section_collapsed = true
        end
      elsif msg['is_channel_header']
        # Already collapsed? Do nothing
        return if @channel_collapsed[msg['channel_id']]

        # Save current position
        @saved_positions[msg['channel_id']] = @index

        # Collapse the channel
        @channel_collapsed[msg['channel_id']] = true
      elsif msg['is_thread_header']
        return if @thread_collapsed[msg['thread_id']]
        @saved_positions[msg['thread_id']] = @index
        @thread_collapsed[msg['thread_id']] = true
      elsif msg['channel_id']
        # Message inside a channel - collapse the parent channel
        return if @channel_collapsed[msg['channel_id']]
        @saved_positions[msg['channel_id']] = @index
        @channel_collapsed[msg['channel_id']] = true
        
        # Move selection to the channel header
        find_and_select_header(msg['channel_id'], 'channel')
      elsif msg['thread_id']
        # Message inside a thread - collapse the parent thread
        return if @thread_collapsed[msg['thread_id']]
        @saved_positions[msg['thread_id']] = @index
        @thread_collapsed[msg['thread_id']] = true
        
        # Move selection to the thread header
        find_and_select_header(msg['thread_id'], 'thread')
      end
      
      # Re-render
      render_message_list_threaded
      render_message_content
    end
    
    def expand_current_item
      return unless @show_threaded && @organizer
      
      msg = current_message
      return unless msg
      
      @saved_positions ||= {}
      restore_position = nil
      
      if msg['is_dm_header']
        dm_key = msg['channel_id']
        if @sort_order == 'conversation'
          @dm_collapsed[dm_key] = !@dm_collapsed.fetch(dm_key, true)
        else
          @dm_section_collapsed = !@dm_section_collapsed
        end
      elsif msg['is_channel_header']
        # Toggle the channel collapse state
        @channel_collapsed[msg['channel_id']] = !@channel_collapsed[msg['channel_id']]

        # If expanding, restore saved position if available
        if !@channel_collapsed[msg['channel_id']] && @saved_positions[msg['channel_id']]
          restore_position = @saved_positions[msg['channel_id']]
        end
      elsif msg['is_thread_header']
        # Toggle the thread collapse state
        @thread_collapsed[msg['thread_id']] = !@thread_collapsed[msg['thread_id']]

        if !@thread_collapsed[msg['thread_id']] && @saved_positions[msg['thread_id']]
          restore_position = @saved_positions[msg['thread_id']]
        end
      end
      
      # Re-render
      render_message_list_threaded
      
      # Restore position if we had one saved
      if restore_position
        # Make sure the position is still valid
        max_index = filtered_messages_size - 1
        @index = [restore_position, max_index].min
        render_message_list
      end
      
      render_message_content
    end

    # SPACE key: toggle collapse/expand in threaded view
    def toggle_collapse_expand
      return unless @show_threaded && @organizer

      msg = current_message
      return unless msg

      # For headers, toggle directly
      if msg['is_dm_header'] || msg['is_channel_header'] || msg['is_thread_header']
        expand_current_item  # This already toggles
      elsif msg['channel_id'] || msg['thread_id']
        # For messages inside a group, collapse the parent
        collapse_current_item
      end
      # Non-threaded mode: no-op
    end

    # Toggle tag on current message
    def toggle_tag
      msg = current_message
      return unless msg
      return if header_message?(msg)
      return unless msg['id']

      if @tagged_messages.include?(msg['id'])
        @tagged_messages.delete(msg['id'])
      else
        @tagged_messages.add(msg['id'])
      end
      advance_index
      render_message_list
      render_message_content
    end

    # Tag/untag messages matching a regex (Ctrl+t, like RTFM)
    def tag_by_regex
      pattern = bottom_ask("Tag regex (default=all): ", ".*")
      return if pattern.nil?

      begin
        regex = Regexp.new(pattern, Regexp::IGNORECASE)
      rescue RegexpError => e
        set_feedback("Invalid regex: #{e.message}", 196, 3)
        return
      end

      count = 0
      @filtered_messages.each do |msg|
        next if header_message?(msg)
        next unless msg['id']

        match = [msg['sender'], msg['subject'], msg['content']].compact.any? { |f| f.match?(regex) }
        if match
          if @tagged_messages.include?(msg['id'])
            @tagged_messages.delete(msg['id'])
          else
            @tagged_messages.add(msg['id'])
            count += 1
          end
        end
      end

      set_feedback("Toggled #{count} tags (#{@tagged_messages.size} total tagged)", 14, 3)
      render_message_list
    end

    # Tag/untag all messages in current view
    def tag_all_toggle
      msgs = @filtered_messages.reject { |m| header_message?(m) }
      ids = msgs.map { |m| m['id'] }.compact
      if ids.all? { |id| @tagged_messages.include?(id) }
        # All tagged, untag all
        ids.each { |id| @tagged_messages.delete(id) }
        set_feedback("Untagged all #{ids.size} messages", 14, 2)
      else
        # Tag all
        ids.each { |id| @tagged_messages.add(id) }
        set_feedback("Tagged all #{ids.size} messages", 14, 2)
      end
      render_message_list
    end

    # Jump to next unread message (wraps around)
    def jump_to_next_unread
      display = if @show_threaded && @display_messages && !@display_messages.empty?
                  @display_messages
                else
                  @filtered_messages
                end
      return set_feedback("No messages", 245, 2) if display.empty?

      # Search visible list for next unread after current position
      display.size.times do |i|
        idx = (@index + 1 + i) % display.size
        msg = display[idx]
        next unless msg
        next if header_message?(msg)
        if msg['is_read'].to_i == 0
          @index = idx
          track_browsed_message
          render_all
          return
        end
      end

      # In threaded view, try uncollapsing to find hidden unread
      if @show_threaded && @organizer
        # Find all unread messages in the raw list, try each one starting after current position
        unread_msgs = @filtered_messages.select { |m| m['is_read'].to_i == 0 && m['id'] }
        unread_msgs.each do |unread|
          uncollapse_for_message(unread)
        end
        if unread_msgs.any?
          # Re-render to rebuild display_messages with uncollapsed sections
          organize_current_messages(true)
          render_message_list_threaded
          new_display = @display_messages || @filtered_messages
          # Find the first visible unread after current position
          new_display.size.times do |i|
            idx = (@index + 1 + i) % new_display.size
            m = new_display[idx]
            next unless m && m['id'] && m['is_read'].to_i == 0
            next if header_message?(m)
            @index = idx
            track_browsed_message
            render_all
            return
          end
        end
      end

      set_feedback("No unread messages in this view", 208, 2)
    end

    # Jump to previous unread message (wraps around)
    def jump_to_prev_unread
      display = (@show_threaded && @display_messages && !@display_messages.empty?) ? @display_messages : @filtered_messages
      size = display.size
      return if size == 0

      size.times do |i|
        idx = (@index - 1 - i) % size
        msg = display[idx]
        next unless msg
        next if header_message?(msg)
        if msg['is_read'].to_i == 0
          @index = idx
          track_browsed_message
          render_all
          return
        end
      end

      # Try uncollapsing to find hidden unread (search backwards)
      if @show_threaded && @organizer
        unread_msgs = @filtered_messages.select { |m| m['is_read'].to_i == 0 && m['id'] }
        unread_msgs.each do |unread|
          uncollapse_for_message(unread)
        end
        if unread_msgs.any?
          organize_current_messages(true)
          render_message_list_threaded
          new_display = @display_messages || @filtered_messages
          new_size = new_display.size
          new_size.times do |i|
            idx = (@index - 1 - i) % new_size
            m = new_display[idx]
            next unless m && m['id'] && m['is_read'].to_i == 0
            next if header_message?(m)
            @index = idx
            track_browsed_message
            render_all
            return
          end
        end
      end

      set_feedback("No unread messages in this view", 208, 2)
    end

    def uncollapse_for_message(msg)
      return unless msg && @organizer
      msg_id = msg['id']

      # Find which channel contains this message (use section[:name] as collapse key)
      if @channel_collapsed
        @organizer.instance_variable_get(:@channels)&.each do |_channel_id, channel_data|
          if channel_data[:messages]&.any? { |m| m['id'] == msg_id }
            @channel_collapsed[channel_data[:name]] = false
            return
          end
        end
      end

      # Find which thread contains this message
      if @thread_collapsed
        @organizer.instance_variable_get(:@threads)&.each do |_thread_id, thread_data|
          if thread_data[:messages]&.any? { |m| m['id'] == msg_id }
            @thread_collapsed[thread_data[:subject].to_s] = false
            return
          end
        end
      end

      # Uncollapse DM section if it's a DM
      if msg['is_dm']
        if @sort_order == 'conversation'
          # Find which conversation this DM belongs to
          metadata = @organizer.send(:parse_metadata, msg['metadata']) rescue {}
          dm_key = msg['sender'] || msg['subject'] || 'Unknown'
          @dm_collapsed[dm_key] = false
        elsif @dm_section_collapsed
          @dm_section_collapsed = false
        end
      end
    end

    def find_and_select_header(id, type)
      # Find the header in the display messages
      @display_messages.each_with_index do |msg, idx|
        if type == 'channel' && msg['is_channel_header'] && msg['channel_id'] == id
          @index = idx
          return
        elsif type == 'thread' && msg['is_thread_header'] && msg['thread_id'] == id
          @index = idx
          return
        end
      end
    end
    
    def open_message
      msg = current_message
      return unless msg
      
      # Mark as read
      if msg['is_read'] == 0 || !msg['is_read']
        @db.mark_as_read(msg['id'])
        msg['is_read'] = 1
        render_message_list
      end
      
      # Show full content in right pane
      render_message_content
    end
    
    def message_has_html?(msg)
      return false unless msg
      (msg['html_content'] && !msg['html_content'].to_s.strip.empty?) ||
        (msg['content'] && msg['content'] =~ /\A\s*<(!DOCTYPE|html|head|body)\b/i)
    end

    def open_in_timely
      msg = current_message
      return unless msg
      msg = ensure_full_message(msg)

      # Try to find a date from calendar data or message timestamp
      timely_home = File.expand_path('~/.timely')
      return set_feedback("Timely not configured (~/.timely missing)", 196, 3) unless File.directory?(timely_home)

      # Check for ICS attachment or inline calendar data
      date_str = nil
      meta = msg['metadata']
      meta = JSON.parse(meta) if meta.is_a?(String) rescue nil
      file = meta['maildir_file'] if meta.is_a?(Hash)

      if file && File.exist?(file)
        begin
          require 'mail'
          mail = Mail.read(file)
          if mail.multipart?
            mail.parts.each do |part|
              ct = (part.content_type || '').downcase
              if ct.include?('calendar') || ct.include?('ics')
                ics = part.decoded
                vevent = ics[/BEGIN:VEVENT(.*?)END:VEVENT/m, 1]
                if vevent
                  vevent = vevent.gsub(/\r?\n[ \t]/, '')
                  if vevent =~ /^DTSTART;TZID=[^:]*:(\d{8})/i ||
                     vevent =~ /^DTSTART:(\d{8})/i ||
                     vevent =~ /^DTSTART;VALUE=DATE:(\d{8})/i
                    d = $1
                    date_str = "#{d[0,4]}-#{d[4,2]}-#{d[6,2]}"
                  end
                end
                break
              end
            end
          end
        rescue => e
          # Fall through to timestamp
        end
      end

      # Fallback: use message timestamp
      unless date_str
        ts = msg['timestamp'].to_i
        date_str = Time.at(ts).strftime('%Y-%m-%d') if ts > 0
      end

      return set_feedback("Could not determine date for Timely", 245, 2) unless date_str

      # Write goto file for Timely
      File.write(File.join(timely_home, 'goto'), date_str)

      # Also copy ICS to incoming if it has calendar data
      if file && File.exist?(file)
        begin
          incoming = File.join(timely_home, 'incoming')
          FileUtils.mkdir_p(incoming)
          require 'mail'
          mail = Mail.read(file)
          mail.parts.each do |part|
            ct = (part.content_type || '').downcase
            if ct.include?('calendar') || ct.include?('ics')
              ics_file = File.join(incoming, "heathrow_#{msg['id']}.ics")
              File.write(ics_file, part.decoded) unless File.exist?(ics_file)
              break
            end
          end
        rescue => e
          # Non-fatal
        end
      end

      set_feedback("Sent to Timely: #{date_str}", 156, 0)
    end

    def open_message_external
      msg = current_message
      return unless msg
      return if header_message?(msg)
      msg = ensure_full_message(msg)

      # Mark as read
      if msg['is_read'].to_i == 0
        @db.mark_as_read(msg['id'])
        msg['is_read'] = 1
        render_message_list
      end

      # For messages with HTML content, open directly in browser
      if message_has_html?(msg)
        html = msg['html_content']
        html = msg['content'] if !html || html.to_s.strip.empty?
        tmpfile = "/tmp/heathrow-view-#{msg['id']}.html"
        File.write(tmpfile, html)
        system("xdg-open '#{tmpfile}' 2>/dev/null &")
        set_feedback("Opened HTML in browser", 156, 3)
        return
      end

      url = nil

      # Determine URL based on source type
      case msg['source_type']
      when 'discord'
        if msg['external_id'] && msg['external_id'].start_with?('discord_')
          parts = msg['external_id'].split('_')
          if parts.length >= 3
            channel_id = parts[1]
            message_id = parts[2]
            guild_id = nil
            if msg['raw_data']
              begin
                raw = JSON.parse(msg['raw_data'])
                guild_id = raw['guild_id']
              rescue; end
            end
            if guild_id
              url = "https://discord.com/channels/#{guild_id}/#{channel_id}/#{message_id}"
            else
              url = "https://discord.com/channels/@me/#{channel_id}/#{message_id}"
            end
          end
        end
      when 'slack'
        if msg['workspace'] && msg['channel_id'] && msg['timestamp']
          url = "https://#{msg['workspace']}.slack.com/archives/#{msg['channel_id']}/p#{msg['timestamp'].gsub('.', '')}"
        end
      when 'reddit'
        if msg['permalink']
          url = "https://reddit.com#{msg['permalink']}"
        elsif msg['url'] && msg['url'].start_with?('http')
          url = msg['url']
        end
      when 'rss', 'hacker_news'
        # Check metadata (where RSS link is stored)
        meta = msg['metadata']
        if meta
          begin
            parsed = meta.is_a?(Hash) ? meta : JSON.parse(meta)
            url = parsed['link'] || parsed['url']
          rescue; end
        end
        # Fallback to raw_data, then external_id
        if !url && msg['raw_data']
          begin
            raw = JSON.parse(msg['raw_data'])
            url = raw['link'] || raw['url']
          rescue; end
        end
        url ||= msg['external_id'] if msg['external_id'] && msg['external_id'].start_with?('http')
      when 'telegram'
        url = msg['link'] if msg['link']
      when 'whatsapp'
        if msg['sender'] && msg['sender'].match?(/^\+?\d+$/)
          url = "https://wa.me/#{msg['sender'].gsub(/[^\d]/, '')}"
        end
      end

      # Fallback to any URL field in the message
      url ||= msg['url'] || msg['link'] || msg['permalink']

      if url
        system("xdg-open '#{url}' 2>/dev/null &")
        set_feedback("Opened in browser: #{url[0..50]}...", 156, 3)
      else
        set_feedback("No HTML or URL available for this message", 226, 3)
      end
    end
    
    def view_attachments
      msg = current_message
      return unless msg
      return set_feedback("Select a message first", 245, 2) if header_message?(msg)

      # Load full message if needed (use numeric id only)
      msg_id = msg['id']
      if msg_id && msg_id.is_a?(Integer) && !msg.key?('attachments')
        full = @db.get_message(msg_id)
        msg.merge!(full) if full
      end

      attachments = msg['attachments']
      unless attachments.is_a?(Array) && !attachments.empty?
        set_feedback("No attachments", 226, 2)
        return
      end

      maildir_file = msg.dig('metadata', 'maildir_file') || msg.dig('metadata', :maildir_file)
      unless maildir_file && File.exist?(maildir_file.to_s)
        set_feedback("Source mail file not found", 196, 2)
        return
      end

      # Interactive attachment browser in right pane
      att_index = 0
      att_tagged = Set.new

      render_attachment_list(attachments, att_index, att_tagged)
      @panes[:bottom].text = " j/k:Navigate  t:Tag  T:Tag all  o:Open  s:Save  ESC:Back".fg(245)
      @panes[:bottom].refresh

      loop do
        chr = getchr
        case chr
        when 'j', 'DOWN'
          att_index = (att_index + 1) % attachments.size
          render_attachment_list(attachments, att_index, att_tagged)
        when 'k', 'UP'
          att_index = (att_index - 1) % attachments.size
          render_attachment_list(attachments, att_index, att_tagged)
        when 't'
          if att_tagged.include?(att_index)
            att_tagged.delete(att_index)
          else
            att_tagged.add(att_index)
          end
          att_index = (att_index + 1) % attachments.size
          render_attachment_list(attachments, att_index, att_tagged)
        when 'T'
          # Toggle all
          if att_tagged.size == attachments.size
            att_tagged.clear
          else
            attachments.each_index { |i| att_tagged.add(i) }
          end
          render_attachment_list(attachments, att_index, att_tagged)
        when 'o', 'ENTER'
          targets = att_tagged.empty? ? [att_index] : att_tagged.to_a.sort
          open_attachments(maildir_file, attachments, targets)
          render_attachment_list(attachments, att_index, att_tagged)
          @panes[:bottom].text = " j/k:Navigate  t:Tag  T:Tag all  o:Open  s:Save  ESC:Back".fg(245)
          @panes[:bottom].refresh
        when 's'
          targets = att_tagged.empty? ? [att_index] : att_tagged.to_a.sort
          save_attachments(maildir_file, attachments, targets)
          render_attachment_list(attachments, att_index, att_tagged)
        when 'q', 'ESC', "\e", 'h', 'LEFT'
          break
        end
      end

      @panes[:right].content_update = true
      render_all
    end

    def render_attachment_list(attachments, idx, tagged)
      lines = ["Attachments:".b.fg(226), ""]
      attachments.each_with_index do |att, i|
        name = att['name'] || att['filename'] || 'unnamed'
        size = att['size'] ? " (#{human_size(att['size'])})" : ''
        ctype = att['content_type']&.split(';')&.first || ''
        tag = tagged.include?(i) ? "* ".fg(226) : "  "
        if i == idx
          lines << "→ ".fg(226) + tag + "#{name}#{size}  #{ctype}".b.fg(255)
        else
          lines << "  " + tag + "#{name}#{size}  #{ctype}".fg(250)
        end
      end
      tagged_hint = tagged.empty? ? "" : "  (#{tagged.size} tagged)"
      lines << ""
      lines << "t:Tag  T:All  o/Enter:Open  s:Save#{tagged_hint}".fg(245)
      @panes[:right].ix = 0
      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh
    end

    def open_attachments(maildir_file, attachments, indices)
      mail = load_mail_file(maildir_file)
      return unless mail
      tmpdir = File.join(Dir.tmpdir, 'heathrow-att')
      FileUtils.mkdir_p(tmpdir)
      opened = 0
      indices.each do |i|
        att = attachments[i]
        mail_att = find_mail_attachment(mail, att)
        next unless mail_att
        tmp_path = File.join(tmpdir, mail_att.filename)
        File.open(tmp_path, 'wb') { |f| f.write(mail_att.body.decoded) }
        mime = att['content_type'] || att['mime_type'] || 'application/octet-stream'
        mime = mime.split(';').first.strip
        cmd = mailcap_command(mime, tmp_path)
        pid = Process.spawn(cmd, [:out, :err] => '/dev/null')
        Process.detach(pid)
        opened += 1
      end
      set_feedback("Opened #{opened} attachment#{opened != 1 ? 's' : ''}", 156, 2)
    end

    def save_attachments(maildir_file, attachments, indices)
      download_dir = @download_folder || @config.get('download_folder') || '~/Downloads'
      download_dir = File.expand_path(download_dir)
      if indices.size == 1
        att = attachments[indices[0]]
        name = att['name'] || att['filename'] || 'unnamed'
        default_path = File.join(download_dir, name)
        save_path = bottom_ask("Save to: ", default_path)
        return if save_path.nil? || save_path.strip.empty?
        save_path = File.expand_path(save_path.strip)
      else
        save_path = bottom_ask("Save #{indices.size} files to folder: ", download_dir)
        return if save_path.nil? || save_path.strip.empty?
        save_path = File.expand_path(save_path.strip)
      end

      mail = load_mail_file(maildir_file)
      return unless mail
      saved = 0
      indices.each do |i|
        att = attachments[i]
        mail_att = find_mail_attachment(mail, att)
        next unless mail_att
        if indices.size == 1
          dest = save_path
        else
          dest = File.join(save_path, mail_att.filename)
        end
        FileUtils.mkdir_p(File.dirname(dest))
        File.open(dest, 'wb') { |f| f.write(mail_att.body.decoded) }
        saved += 1
      end
      set_feedback("Saved #{saved} attachment#{saved != 1 ? 's' : ''}", 156, 2)
    end

    def load_mail_file(maildir_file)
      require 'mail'
      old_stderr = $stderr.dup
      $stderr.reopen(File.open(File::NULL, 'w'))
      mail = Mail.read(maildir_file)
      $stderr.reopen(old_stderr)
      old_stderr.close
      mail
    rescue => e
      set_feedback("Error reading mail: #{e.message}", 196, 2)
      nil
    end

    def mailcap_command(mime_type, file_path)
      escaped = Shellwords.escape(file_path)
      mailcap_files = [File.expand_path('~/.mailcap'), '/etc/mailcap']
      mailcap_files.each do |mc|
        next unless File.exist?(mc)
        File.foreach(mc) do |line|
          line = line.strip
          next if line.empty? || line.start_with?('#')
          fields = line.split(';').map(&:strip)
          next if fields.size < 2
          next if fields.any? { |f| f.strip == 'copiousoutput' }
          if fields[0].casecmp?(mime_type)
            cmd = fields[1].gsub("'%s'", escaped).gsub('%s', escaped)
            return cmd
          end
        end
      end
      "xdg-open #{escaped}"
    end

    def find_mail_attachment(mail, att)
      name = att['name'] || att['filename']
      mail.attachments.find { |a| a.filename == name } ||
        mail.attachments.find { |a| a.filename&.include?(name.to_s.split("\n").first) }
    end

    def mark_current_message_as_read
      msg = current_message
      return unless msg
      return if msg['is_header']  # Don't mark headers
      return if msg['is_channel_header'] || msg['is_thread_header']  # Don't mark synthetic headers
      return unless msg['id'] && !msg['id'].to_s.start_with?('header_')
      
      # Only mark as read if currently unread
      if msg['is_read'].to_i == 0
        success = @db.mark_as_read(msg['id'])
        if success
          msg['is_read'] = 1
          
          # Re-sort if sorting by unread
          if @sort_order == 'unread'
            sort_messages
            # Reset threading to reorganize with new unread counts (preserve collapsed state)
            reset_threading(true)
          end
          
          # Update displays if UI is initialized
          if @panes && @w
            render_top_bar  # Update unread count
            render_message_list  # Update the list to remove background color
          end
        end
      end
    end
    
    def toggle_read_status
      # Batch mode: if messages are tagged, toggle read on all tagged
      if @tagged_messages && !@tagged_messages.empty?
        toggle_tagged_read_status
        return
      end

      msg = current_message
      return unless msg

      # Check if this is a source/channel header
      if msg['is_channel_header'] || msg['is_thread_header'] || msg['is_dm_header']
        # Toggle read status for all messages in this group
        toggle_group_read_status(msg)
      else
        # Regular message toggle
        toggle_single_message_read(msg)
      end
    end

    # Toggle read status on all tagged messages, then clear tags
    def toggle_tagged_read_status
      tagged_msgs = @filtered_messages.select { |m| m['id'] && @tagged_messages.include?(m['id']) }
      return if tagged_msgs.empty?

      # Determine direction: if any are unread, mark all as read; otherwise mark all unread
      any_unread = tagged_msgs.any? { |m| m['is_read'].to_i == 0 }
      count = 0

      tagged_msgs.each do |msg|
        if any_unread
          next if msg['is_read'].to_i == 1  # Already read
          success = @db.mark_as_read(msg['id'])
          if success
            msg['is_read'] = 1
            sync_maildir_flag(msg, 'S', true)
            count += 1
          end
        else
          next if msg['is_read'].to_i == 0  # Already unread
          success = @db.mark_as_unread(msg['id'])
          if success
            msg['is_read'] = 0
            sync_maildir_flag(msg, 'S', false)
            count += 1
          end
        end
      end

      action = any_unread ? "read" : "unread"
      set_feedback("Marked #{count} tagged messages as #{action}", 156, 3)
      @tagged_messages.clear

      # Update displays
      if @panes && @w
        render_top_bar
        render_message_list
      end
    end

    # Mark all messages in the current view as read
    def mark_all_view_read(force_all: false)
      # In threaded view on a section header: mark just that group (unless force_all)
      if !force_all && @show_threaded && !@display_messages.empty?
        msg = current_message
        group_msgs = find_current_group_messages(msg)
        if group_msgs
          count = mark_messages_read(group_msgs)
          group_name = msg['subject'] || msg['channel_name'] || 'group'
          set_feedback("Marked #{count} in #{group_name} as read", 156, 3)
          render_top_bar
          render_message_list
          return
        end
      end

      # Bulk DB update for All View or folder views (covers all messages, not just loaded subset)
      if @current_view == 'A' && !@current_folder
        rows = @db.mark_all_as_read
      elsif @current_folder
        rows = @db.mark_all_as_read(folder: @current_folder)
      else
        rows = nil
      end

      organized_sections = (@show_threaded && @organizer) ? @organizer.get_organized_view(@sort_order, @sort_inverted) : nil

      if rows
        # Sync maildir flags for all affected messages
        count = rows.size
        rows.each do |row|
          metadata = row['metadata']
          metadata = JSON.parse(metadata) if metadata.is_a?(String)
          next unless metadata.is_a?(Hash) && metadata['maildir_file']
          sync_maildir_flag({'metadata' => metadata, 'id' => row['id']}, 'S', true)
        end
        # Update in-memory message lists
        [@filtered_messages, @display_messages].each do |list|
          next unless list
          list.each { |m| m['is_read'] = 1 if m['id'] && m['is_read'].to_i == 0 }
        end
        if organized_sections
          organized_sections.each do |section|
            next unless section[:messages]
            section[:messages].each { |m| m['is_read'] = 1 if m['is_read'].to_i == 0 }
          end
        end
      else
        # Custom views: mark loaded messages (subset)
        msgs = if @show_threaded && !@display_messages.empty?
                 @display_messages
               else
                 @filtered_messages
               end
        return if msgs.nil? || msgs.empty?
        count = mark_messages_read(msgs)
        # Also mark messages inside collapsed sections
        if organized_sections
          organized_sections.each do |section|
            next unless section[:messages]
            count += mark_messages_read(section[:messages])
          end
        end
      end

      invalidate_counts
      set_feedback("Marked #{count} messages as read", 156, 3)
      render_top_bar
      render_message_list
    end


    # Mark a list of messages as read, skipping headers and already-read
    def mark_messages_read(msgs)
      count = 0
      msgs.each do |msg|
        next if header_message?(msg)
        next if msg['is_read'].to_i == 1
        next unless msg['id']
        @db.mark_as_read(msg['id'])
        msg['is_read'] = 1
        sync_maildir_flag(msg, 'S', true)
        count += 1
      end
      count
    end

    # Find messages in the same group as the current message/header
    # Returns nil if not in a group context
    def find_current_group_messages(msg)
      return nil unless msg && @show_threaded && @organizer

      # If standing on a header, use its section_messages directly
      if header_message?(msg)
        return msg['section_messages'] if msg['section_messages']
      end

      # Standing on a regular message: walk backward to find its section header
      idx = @index - 1
      while idx >= 0
        prev = @display_messages[idx]
        if prev && (header_message?(prev))
          return prev['section_messages'] if prev['section_messages']
          break
        end
        idx -= 1
      end

      nil
    end

    def toggle_group_read_status(header)
      # Use the section_messages stored in the header if available
      messages = header['section_messages']
      
      # Fallback to finding messages via organizer if not stored in header
      if !messages && @show_threaded && @organizer
        organized = @organizer.get_organized_view
        
        # Find the section this header belongs to
        section = organized.find do |s|
          if header['is_channel_header']
            s[:type] == 'channel' && s[:name] == header['channel_name']
          elsif header['is_thread_header']
            s[:type] == 'thread' && s[:subject] == header['subject']
          elsif header['is_dm_header']
            s[:type] == 'dm_section'
          else
            false
          end
        end
        
        messages = section[:messages] if section
      end
      
      return unless messages && !messages.empty?
      
      # Check if all messages are read
      all_read = messages.all? { |m| m['is_read'].to_i == 1 }
      
      # Toggle all messages in this section
      messages.each do |msg|
        next unless msg['id'] && !msg['id'].to_s.start_with?('header_')  # Skip synthetic headers

        if all_read
          @db.mark_as_unread(msg['id'])
          msg['is_read'] = 0
        else
          @db.mark_as_read(msg['id'])
          msg['is_read'] = 1
        end
      end
      invalidate_counts

      # Re-sort if sorting by unread
      if @sort_order == 'unread'
        sort_messages
        # Reset threading to reorganize with new unread counts (preserve collapsed state)
        reset_threading(true)
      end
      
      # Update displays if UI is initialized
      if @panes && @w
        render_top_bar
        render_message_list
      end
      
      # Show feedback
      action = all_read ? "unread" : "read"
      set_feedback("Marked #{messages.size} messages as #{action}", 156, 3)
    end
    
    def toggle_single_message_read(msg)
      # Don't try to toggle headers
      return if msg['is_header']
      return unless msg['id'] && !msg['id'].to_s.start_with?('header_')

      # Toggle the specific message
      current_read_status = msg['is_read'].to_i
      invalidate_counts

      if current_read_status == 1
        success = @db.mark_as_unread(msg['id'])
        if success
          msg['is_read'] = 0
          sync_maildir_flag(msg, 'S', false)
          set_feedback("Message marked as unread", 156, 3)
        end
      else
        success = @db.mark_as_read(msg['id'])
        if success
          msg['is_read'] = 1
          sync_maildir_flag(msg, 'S', true)
          set_feedback("Message marked as read", 156, 3)

          # Remove from Unread view if currently in it
          if is_unread_view?
            if @show_threaded
              # In threaded view, need to reload filtered messages to rebuild threads
              reset_threading
              @filtered_messages = @db.get_messages({is_read: false}, 1000, 0, light: true)
              sort_messages
              organize_current_messages(force_reinit: true)
              @index = [@index, filtered_messages_size - 1].min
              @index = 0 if @index < 0
            else
              # In flat view, just remove from list
              @filtered_messages.delete_at(@index)
              @index = [@index, @filtered_messages.size - 1].min if @index >= @filtered_messages.size
              @index = 0 if @index < 0 || @filtered_messages.empty?
            end
          end
        end
      end

      # Re-sort if sorting by unread
      if @sort_order == 'unread'
        sort_messages
        # Reset threading to reorganize with new unread counts (preserve collapsed state)
        reset_threading(true)
      end
      
      # Update displays immediately if UI is initialized
      if @panes && @w
        render_top_bar  # Update unread count
        render_message_list  # This will update the visual display including background colors
      end
    end
    
    def toggle_read
      # Write debug log
      
      msg = current_message
      return unless msg
      return if @in_source_view  # Don't toggle read in source view
      
      # Log the message details
      
      # HOUSE DIAGNOSTIC: Check if message has an ID!
      unless msg['id']
        # Show error in bottom bar
        @panes[:bottom].text = " ERROR: Message has no ID! Cannot toggle.".fg(196)
        @panes[:bottom].refresh
        return
      end
      
      # CRITICAL FIX: Convert is_read to integer for comparison
      current_read_status = msg['is_read'].to_i
      
      # Toggle based on current state
      if current_read_status == 1
        success = @db.mark_as_unread(msg['id'])
        if success
          msg['is_read'] = 0
        end
      else
        success = @db.mark_as_read(msg['id'])
        if success
          msg['is_read'] = 1
        end
      end
      
      # Update displays immediately if UI is initialized
      if @panes && @w
        render_top_bar  # Update unread count
        render_message_list
        render_message_content
      end
    end
    
    def toggle_star
      msg = current_message
      return unless msg
      @db.toggle_star(msg['id'])
      msg['is_starred'] = msg['is_starred'] == 1 ? 0 : 1
      invalidate_counts

      # Sync flagged status to Maildir file
      sync_maildir_flag(msg, 'F', msg['is_starred'] == 1)

      render_message_list
      render_bottom_bar
    end
    
    # ========== Folder Browser ==========

    # Build a tree structure from dot-separated folder names
    def build_folder_tree(folder_names)
      tree = {}
      folder_names.each do |name|
        parts = name.split('.')
        node = tree
        parts.each do |part|
          node[part] ||= {}
          node = node[part]
        end
      end
      tree
    end

    # Flatten folder tree into displayable lines with indent
    def flatten_folder_tree(tree, prefix = '', depth = 0, collapsed = {})
      lines = []
      tree.keys.sort.each do |key|
        full_name = prefix.empty? ? key : "#{prefix}.#{key}"
        has_children = !tree[key].empty?
        is_collapsed = collapsed[full_name]

        lines << {
          name: key,
          full_name: full_name,
          depth: depth,
          has_children: has_children,
          collapsed: is_collapsed
        }

        if has_children && !is_collapsed
          lines.concat(flatten_folder_tree(tree[key], full_name, depth + 1, collapsed))
        end
      end
      lines
    end

    # Get counts for a single folder (fast — one query)
    def folder_message_count(folder_name)
      # Use range query to leverage folder index (5x faster than OR + LIKE)
      row = @db.db.get_first_row(
        "SELECT COUNT(*) as total, SUM(CASE WHEN read = 0 THEN 1 ELSE 0 END) as unread FROM messages WHERE folder = ?",
        [folder_name]
      )
      { total: (row && row['total']) || 0, unread: (row && row['unread']) || 0 }
    rescue
      { total: 0, unread: 0 }
    end

    def show_folder_browser
      @in_folder_browser = true
      @in_favorites_browser = false
      @folder_browser_index = 0
      @panes[:top].bg = @topcolor
      @folder_collapsed ||= {}
      @folder_count_cache = {}  # Fresh counts each time
      @browser_favorites = nil  # Fresh favorites read

      # Discover folders from disk (instant — no DB queries)
      maildir_path = File.expand_path('~/Maildir')
      folder_names = ['INBOX']
      Dir.glob(File.join(maildir_path, '.*')).sort.each do |dir|
        bn = File.basename(dir)
        next if bn == '.' || bn == '..'
        next unless File.directory?(dir)
        next unless File.directory?(File.join(dir, 'cur')) || File.directory?(File.join(dir, 'new'))
        folder_names << bn.sub(/^\./, '')
      end

      @folder_list = folder_names
      @folder_tree = build_folder_tree(folder_names)
      # Start with top-level collapsed for speed
      @folder_collapsed = {} if @folder_collapsed.nil?
      @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)

      render_folder_browser
      folder_browser_loop
    end

    def render_folder_browser
      @browser_favorites ||= get_favorite_folders
      lines = []
      @folder_display.each_with_index do |folder, i|
        indent = "  " * folder[:depth]
        arrow = folder[:has_children] ? (folder[:collapsed] ? "▸ " : "▾ ") : "  "
        star = @browser_favorites.include?(folder[:full_name]) ? "* ".fg(226) : "  "

        if i == @folder_browser_index
          line = "→ ".fg(226) + indent + arrow.fg(226) + star + folder[:name].b.u.fg(255)
        else
          line = "  " + indent + arrow.fg(245) + star + folder[:name].fg(245)
        end
        lines << line
      end

      @panes[:left].text = lines.join("\n")

      # Scroll to keep selected item visible
      page_height = @panes[:left].h
      page_height -= 2 if @panes[:left].border
      if @folder_display.size > page_height
        scrolloff = 3
        max_scroll = @folder_display.size - page_height
        if @folder_browser_index - @panes[:left].ix < scrolloff
          @panes[:left].ix = [@folder_browser_index - scrolloff, 0].max
        elsif @panes[:left].ix + page_height - 1 - @folder_browser_index < scrolloff
          @panes[:left].ix = [@folder_browser_index + scrolloff - page_height + 1, max_scroll].min
        end
      else
        @panes[:left].ix = 0
      end

      @panes[:left].refresh

      # Show folder info in right pane (cache counts to avoid slow queries on every keystroke)
      if @folder_display[@folder_browser_index]
        folder = @folder_display[@folder_browser_index]
        @folder_count_cache ||= {}
        counts = @folder_count_cache[folder[:full_name]] ||= folder_message_count(folder[:full_name])
        info = []
        info << "FOLDER: #{folder[:full_name]}".b.fg(226)
        info << ""
        info << "Messages: #{counts[:total]}".fg(39)
        info << "Unread: #{counts[:unread]}".fg(counts[:unread] > 0 ? 208 : 245)
        info << ""
        info << "Press Enter to open folder".fg(245)
        info << "Press h/l to collapse/expand".fg(245)
        info << "Press ESC/q to return".fg(245)
        @panes[:right].text = info.join("\n")
        @panes[:right].refresh
      end

      # Update top bar (preserve Favorites title if in favorites mode)
      browser_title = @in_favorites_browser ? "Favorites" : "Folder Browser"
      browser_color = @in_favorites_browser ? 226 : 201
      @panes[:top].text = " Heathrow - ".b.fg(255) + browser_title.b.fg(browser_color) + " [#{@folder_display.size} folders]".fg(246)
      @panes[:top].refresh

      # Update bottom bar
      @panes[:bottom].text = " j/k:Navigate | Enter:Open | h/l:Collapse/Expand | F:Favorites | +:Add fav | ESC:Back".fg(245)
      @panes[:bottom].refresh
    end

    # Fast re-render of just the left pane folder list (no DB queries)
    def render_folder_browser_left_only
      @browser_favorites ||= get_favorite_folders
      lines = []
      @folder_display.each_with_index do |folder, i|
        indent = "  " * folder[:depth]
        arrow = folder[:has_children] ? (folder[:collapsed] ? "▸ " : "▾ ") : "  "
        star = @browser_favorites.include?(folder[:full_name]) ? "* ".fg(226) : "  "
        if i == @folder_browser_index
          line = "→ ".fg(226) + indent + arrow.fg(226) + star + folder[:name].b.u.fg(255)
        else
          line = "  " + indent + arrow.fg(245) + star + folder[:name].fg(245)
        end
        lines << line
      end
      @panes[:left].text = lines.join("\n")
      @panes[:left].refresh
    end

    def folder_browser_loop
      loop do
        chr = getchr
        case chr
        when 'j', 'DOWN'
          @folder_browser_index = (@folder_browser_index + 1) % @folder_display.size if @folder_display.size > 0
          render_folder_browser
        when 'k', 'UP'
          @folder_browser_index = (@folder_browser_index - 1) % @folder_display.size if @folder_display.size > 0
          render_folder_browser
        when 'l', 'RIGHT', 'ENTER'
          # RTFM-style: RIGHT/l/Enter = enter/expand
          folder = @folder_display[@folder_browser_index]
          next unless folder
          if folder[:has_children] && folder[:collapsed]
            # Expand collapsed folder
            @folder_collapsed.delete(folder[:full_name])
            @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)
            render_folder_browser
          elsif folder[:has_children] && !folder[:collapsed]
            # Already expanded — enter (open) the folder
            open_folder(folder[:full_name])
            break
          else
            # Leaf folder — open it
            open_folder(folder[:full_name])
            break
          end
        when 'h', 'LEFT'
          # RTFM-style: LEFT/h = collapse or go to parent
          folder = @folder_display[@folder_browser_index]
          next unless folder
          if folder[:has_children] && !folder[:collapsed]
            # Collapse this folder
            @folder_collapsed[folder[:full_name]] = true
            @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)
            render_folder_browser
          elsif folder[:depth] > 0
            # Go to parent folder
            parent_name = folder[:full_name].split('.')[0..-2].join('.')
            parent_idx = @folder_display.index { |f| f[:full_name] == parent_name }
            if parent_idx
              @folder_browser_index = parent_idx
              render_folder_browser
            end
          end
        when ' ', 'SPACE'
          # Toggle collapse/expand
          folder = @folder_display[@folder_browser_index]
          if folder && folder[:has_children]
            if folder[:collapsed]
              @folder_collapsed.delete(folder[:full_name])
            else
              @folder_collapsed[folder[:full_name]] = true
            end
            @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)
            render_folder_browser
          end
        when 'F'
          show_favorites_browser
          break
        when '+'
          # Add/remove selected folder from favorites
          folder = @folder_display[@folder_browser_index]
          if folder
            favorites = get_favorite_folders
            if favorites.include?(folder[:full_name])
              favorites.delete(folder[:full_name])
              @panes[:bottom].text = " Removed #{folder[:full_name]} from favorites".fg(226)
            else
              favorites << folder[:full_name]
              @panes[:bottom].text = " Added #{folder[:full_name]} to favorites".fg(156)
            end
            save_favorite_folders(favorites)
            @browser_favorites = favorites
            # Quick re-render left pane only (skip slow count query)
            render_folder_browser_left_only
            @panes[:bottom].refresh
          end
        when 'PgDOWN'
          @folder_browser_index = [@folder_browser_index + (@panes[:left].h - 2), @folder_display.size - 1].min
          render_folder_browser
        when 'PgUP'
          @folder_browser_index = [@folder_browser_index - (@panes[:left].h - 2), 0].max
          render_folder_browser
        when 'HOME'
          @folder_browser_index = 0
          render_folder_browser
        when 'END'
          @folder_browser_index = @folder_display.size - 1
          render_folder_browser
        when 'q', 'ESC', "\e"
          @in_folder_browser = false
          @in_favorites_browser = false
          render_all
          break
        else
          # Check folder shortcuts
          shortcuts = get_folder_shortcuts
          if shortcuts[chr]
            open_folder(shortcuts[chr])
            break
          end
        end
      end
    end

    # Open a specific folder and show its messages
    def open_folder(folder_name)
      @in_folder_browser = false
      @in_favorites_browser = false
      @current_folder = folder_name
      @current_view = 'A'
      @in_source_view = false
      @panes[:right].content_update = true
      @current_source_filter = "Folder: #{folder_name}"

      # Reset threading state so old @display_messages don't persist
      reset_threading

      # Show progress while loading
      @panes[:bottom].text = " Loading #{folder_name}...".fg(226)
      @panes[:bottom].refresh

      # Light query with limit (full content loaded lazily when viewing)
      @load_limit = 200
      light_cols = "id, source_id, external_id, thread_id, parent_id, sender, sender_name, recipients, subject, substr(content, 1, 200) as content, timestamp, received_at, read AS is_read, starred AS is_starred, archived, labels, metadata, attachments, folder, replied"
      results = @db.execute(
        "SELECT #{light_cols} FROM messages WHERE folder = ? ORDER BY timestamp DESC LIMIT ?",
        folder_name, @load_limit
      )

      @filtered_messages = results
      sort_messages
      @index = 0
      set_feedback("Folder: #{folder_name} (#{results.size} messages)", 156, 3)
      render_all
    end

    # ========== Favorite Folders ==========

    def get_favorite_folders
      stored = nil
      begin
        result = @db.execute("SELECT value FROM settings WHERE key = 'favorite_folders'")
        stored = JSON.parse(result[0]['value']) if result && result[0]
      rescue
      end
      stored || @config.rc('favorite_folders', []).dup
    end

    def save_favorite_folders(favorites)
      now = Time.now.to_i
      @db.execute(
        "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
        'favorite_folders', favorites.to_json, now
      )
    end

    def show_favorites_browser
      favorites = get_favorite_folders
      @in_folder_browser = true
      @in_favorites_browser = true
      @folder_browser_index = 0
      @panes[:top].bg = @topcolor
      @folder_count_cache = {}  # Fresh counts each time

      # Build display from favorites only (no DB queries — counts fetched on select)
      @folder_display = favorites.map do |name|
        {
          name: name,
          full_name: name,
          depth: 0,
          has_children: false,
          collapsed: false
        }
      end

      render_folder_browser
      @panes[:top].text = " Heathrow - ".b.fg(255) + "Favorites".b.fg(226) + " [#{favorites.size} folders]".fg(246)
      @panes[:top].refresh
      @panes[:bottom].text = " j/k:Navigate | Enter:Open | C-Up/C-Down:Reorder | B:All folders | +:Remove fav | ESC:Back".fg(245)
      @panes[:bottom].refresh

      loop do
        chr = getchr
        case chr
        when 'j', 'DOWN'
          @folder_browser_index = (@folder_browser_index + 1) % @folder_display.size if @folder_display.size > 0
          render_folder_browser
        when 'k', 'UP'
          @folder_browser_index = (@folder_browser_index - 1) % @folder_display.size if @folder_display.size > 0
          render_folder_browser
        when 'l', 'RIGHT', 'ENTER'
          folder = @folder_display[@folder_browser_index]
          if folder
            open_folder(folder[:full_name])
            break
          end
        when 'B'
          # Switch to full folder browser
          show_folder_browser
          break
        when '+'
          # Remove selected folder from favorites
          folder = @folder_display[@folder_browser_index]
          if folder
            favorites = get_favorite_folders
            if favorites.include?(folder[:full_name])
              favorites.delete(folder[:full_name])
              save_favorite_folders(favorites)
              @folder_display = favorites.map do |name|
                { name: name, full_name: name, depth: 0, has_children: false, collapsed: false }
              end
              @folder_browser_index = [@folder_browser_index, @folder_display.size - 1].min
              @folder_browser_index = 0 if @folder_browser_index < 0
              set_feedback("Removed #{folder[:full_name]} from favorites", 226, 2)
              render_folder_browser
              @panes[:top].text = " Heathrow - ".b.fg(255) + "Favorites".b.fg(226) + " [#{@folder_display.size} folders]".fg(246)
              @panes[:top].refresh
            end
          end
        when 'C-UP', '{'
          # Move favorite up
          if @folder_browser_index > 0 && @folder_display.size > 1
            favorites = get_favorite_folders
            i = @folder_browser_index
            favorites[i], favorites[i - 1] = favorites[i - 1], favorites[i]
            save_favorite_folders(favorites)
            @folder_display = favorites.map { |name| { name: name, full_name: name, depth: 0, has_children: false, collapsed: false } }
            @folder_browser_index -= 1
            render_folder_browser
          end
        when 'C-DOWN', '}'
          # Move favorite down
          if @folder_browser_index < @folder_display.size - 1 && @folder_display.size > 1
            favorites = get_favorite_folders
            i = @folder_browser_index
            favorites[i], favorites[i + 1] = favorites[i + 1], favorites[i]
            save_favorite_folders(favorites)
            @folder_display = favorites.map { |name| { name: name, full_name: name, depth: 0, has_children: false, collapsed: false } }
            @folder_browser_index += 1
            render_folder_browser
          end
        when 'q', 'ESC', "\e", 'h', 'LEFT'
          @in_folder_browser = false
          @in_favorites_browser = false
          render_all
          break
        end
      end
    end

    # ========== Quick Folder Shortcuts ==========

    def get_folder_shortcuts
      stored = nil
      begin
        result = @db.execute("SELECT value FROM settings WHERE key = 'folder_shortcuts'")
        stored = JSON.parse(result[0]['value']) if result && result[0]
      rescue
      end
      stored || @config.rc('folder_shortcuts', {}).dup
    end

    def save_folder_shortcuts(shortcuts)
      now = Time.now.to_i
      @db.execute(
        "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
        'folder_shortcuts', shortcuts.to_json, now
      )
    end

    # Go to folder via shortcut key (g key in main view)
    def go_to_folder
      shortcuts = get_folder_shortcuts
      # Show shortcuts in right pane
      info = []
      info << "FOLDER SHORTCUTS".b.fg(226)
      info << "Press a key to jump to folder:".fg(245)
      info << ""
      shortcuts.sort_by { |k, _| k }.each do |key, folder|
        info << "  #{key.ljust(4).fg(10)} → #{folder}".fg(255)
      end
      info << ""
      info << "ESC to cancel".fg(245)
      @panes[:right].text = info.join("\n")
      @panes[:right].refresh

      chr = getchr
      folder = shortcuts[chr]
      if folder
        open_folder(folder)
      else
        render_message_content  # Restore right pane
      end
    end

    def toggle_favorite_folder
      # Add/remove current folder from favorites
      msg = current_message
      return unless msg
      metadata = msg['metadata']
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      folder = metadata.is_a?(Hash) ? metadata['maildir_folder'] : nil
      folder ||= @current_folder
      return unless folder

      favorites = get_favorite_folders
      if favorites.include?(folder)
        favorites.delete(folder)
        set_feedback("Removed #{folder} from favorites", 226, 2)
      else
        favorites << folder
        set_feedback("Added #{folder} to favorites", 156, 2)
      end
      save_favorite_folders(favorites)
    end

    # ========== Message Filing/Moving ==========

    # Save folder shortcuts — configurable in ~/.heathrow/config.yml under save_folders:
    #   save_folders:
    #     "1": "Geir.Personal"
    #     "2": "AA.Archive"
    #     "3": "Projects.Archive"
    #     "4": "Work.Archive"
    def save_folder_shortcuts
      @save_folders ||= begin
        sf = @config.get('save_folders') rescue nil
        sf || {}
      end
    end

    # ── Save to folder (s key) ──
    # Moves email on disk, updates folder + labels in DB for all types.
    # Works on tagged messages if any are tagged; otherwise on current message.
    # Sub-keys: any key for shortcuts (except B/F/=), B=browse all, F=browse favorites, ==configure
    def file_message
      # Get target folder
      shortcuts = save_folder_shortcuts
      hint = shortcuts.map { |k, v| "s#{k}:#{v.split('.').last}" }.join(" ")
      hint = hint.empty? ? "" : " [#{hint}]"
      tagged_hint = @tagged_messages.size > 0 ? " (#{@tagged_messages.size} tagged)" : ""
      set_feedback("Save to folder:#{hint} B:Browse F:Fav =:Config#{tagged_hint}", 226, 5)
      chr = getchr(5)
      if chr.nil? || chr == 'ESC' || chr == "\e"
        @feedback_expires_at = nil
        render_bottom_bar
        return
      end

      if chr == '='
        configure_save_shortcuts
        return
      end

      if chr == 'B'
        dest = save_browse_folders
        return unless dest
      elsif chr == 'F'
        dest = save_browse_favorites
        return unless dest
      elsif shortcuts[chr]
        dest = shortcuts[chr]
      else
        initial = chr == 'ENTER' ? '' : chr.to_s
        dest = bottom_ask("Move to folder: ", initial)
        return if dest.nil? || dest.strip.empty? || dest.strip == initial.strip
        dest = dest.strip
      end

      # Validate folder exists on disk
      maildir_root = @config.get('sources.maildir.path') || File.join(Dir.home, 'Main', 'Maildir')
      folder_path = File.join(maildir_root, ".#{dest}")
      unless Dir.exist?(folder_path)
        confirm = bottom_ask("Folder '#{dest}' doesn't exist. Create it? [y/N] ")
        unless confirm&.strip&.downcase == 'y'
          set_feedback("Save cancelled", 245, 2)
          return
        end
      end

      # Collect messages to file
      msgs = if @tagged_messages.size > 0
               @filtered_messages.select { |m| m['id'] && @tagged_messages.include?(m['id']) }
             else
               msg = current_message
               return unless msg && !msg['is_header'] && !msg['is_channel_header'] && !msg['is_thread_header']
               [msg]
             end
      return if msgs.empty?

      count = 0
      msgs.each do |msg|
        file_single_message(msg, dest)
        count += 1
      end

      # Remove filed messages from current view (by id, works in both flat and threaded mode)
      filed_ids = msgs.map { |m| m['id'] }.compact.to_set
      @filtered_messages.reject! { |m| m['id'] && filed_ids.include?(m['id']) }
      if @show_threaded
        @display_messages&.reject! { |m| m['id'] && filed_ids.include?(m['id']) }
        # Force organizer to rebuild from updated @filtered_messages
        organize_current_messages(true)
      end
      @tagged_messages.clear if @tagged_messages.size > 0
      @index = [@index, (@filtered_messages.size - 1)].min
      @index = 0 if @index < 0 || @filtered_messages.empty?

      set_feedback("Moved #{count} message#{count > 1 ? 's' : ''} to #{dest}", 156, 2)
      render_all
    end

    # Move a single message to a folder (disk + DB)
    def file_single_message(msg, dest)
      metadata = msg['metadata']
      metadata = JSON.parse(metadata) if metadata.is_a?(String) rescue {}
      metadata = {} unless metadata.is_a?(Hash)

      # Move the Maildir file on disk if this is an email
      file_path = metadata['maildir_file']
      if file_path && File.exist?(file_path)
        require_relative '../sources/maildir'
        require 'fileutils'
        maildir_root = @config.get('sources.maildir.path') || File.join(Dir.home, 'Main', 'Maildir')
        new_path = Heathrow::Sources::Maildir.move_to_folder(file_path, maildir_root, dest)
        if new_path
          metadata['maildir_file'] = new_path
          metadata['maildir_folder'] = dest
        end
      end

      # Preserve existing labels, set folder as first label
      existing = msg['labels']
      existing = JSON.parse(existing) if existing.is_a?(String) rescue []
      existing = [] unless existing.is_a?(Array)
      labels = ([dest] + existing).uniq

      @db.execute(
        "UPDATE messages SET folder = ?, labels = ?, metadata = ? WHERE id = ?",
        dest, labels.to_json, metadata.to_json, msg['id']
      )
      msg['folder'] = dest
      msg['metadata'] = metadata
      msg['labels'] = labels

      # Mark as read (we've seen it if we're filing it)
      if msg['is_read'].to_i == 0
        @db.mark_as_read(msg['id'])
        msg['is_read'] = 1
        sync_maildir_flag(msg, 'S', true)
      end
    end

    # ── Save by browsing folders (sB) ──
    # Opens the folder browser in "save mode": Enter picks the destination folder.
    # Returns the chosen folder name, or nil if cancelled.
    def save_browse_folders
      @folder_collapsed ||= {}
      maildir_path = File.expand_path('~/Maildir')
      folder_names = ['INBOX']
      Dir.glob(File.join(maildir_path, '.*')).sort.each do |dir|
        bn = File.basename(dir)
        next if bn == '.' || bn == '..'
        next unless File.directory?(dir)
        next unless File.directory?(File.join(dir, 'cur')) || File.directory?(File.join(dir, 'new'))
        folder_names << bn.sub(/^\./, '')
      end

      @folder_tree = build_folder_tree(folder_names)
      @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)
      save_folder_picker_loop("Save to Folder")
    end

    # ── Save by browsing favorites (sF) ──
    def save_browse_favorites
      favorites = get_favorite_folders
      @folder_display = favorites.map do |name|
        { name: name, full_name: name, depth: 0, has_children: false, collapsed: false }
      end
      save_folder_picker_loop("Save to Favorite")
    end

    # Shared folder picker loop for save operations.
    # Renders the folder list in the left pane, user picks with Enter.
    # Returns chosen folder name or nil.
    def save_folder_picker_loop(title)
      return nil if @folder_display.empty?
      idx = 0

      render_save_folder_picker(idx, title)

      loop do
        chr = getchr
        case chr
        when 'j', 'DOWN'
          idx = (idx + 1) % @folder_display.size
          render_save_folder_picker(idx, title)
        when 'k', 'UP'
          idx = (idx - 1) % @folder_display.size
          render_save_folder_picker(idx, title)
        when 'l', 'RIGHT'
          folder = @folder_display[idx]
          if folder && folder[:has_children] && folder[:collapsed]
            @folder_collapsed.delete(folder[:full_name])
            @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)
            render_save_folder_picker(idx, title)
          elsif folder
            render_all
            return folder[:full_name]
          end
        when 'h', 'LEFT'
          folder = @folder_display[idx]
          if folder && folder[:has_children] && !folder[:collapsed]
            @folder_collapsed[folder[:full_name]] = true
            @folder_display = flatten_folder_tree(@folder_tree, '', 0, @folder_collapsed)
            render_save_folder_picker(idx, title)
          elsif folder && folder[:depth] > 0
            parent_name = folder[:full_name].split('.')[0..-2].join('.')
            parent_idx = @folder_display.index { |f| f[:full_name] == parent_name }
            idx = parent_idx if parent_idx
            render_save_folder_picker(idx, title)
          end
        when 'PgDOWN'
          idx = [idx + (@panes[:left].h - 2), @folder_display.size - 1].min
          render_save_folder_picker(idx, title)
        when 'PgUP'
          idx = [idx - (@panes[:left].h - 2), 0].max
          render_save_folder_picker(idx, title)
        when 'HOME'
          idx = 0
          render_save_folder_picker(idx, title)
        when 'END'
          idx = @folder_display.size - 1
          render_save_folder_picker(idx, title)
        when 'ENTER'
          folder = @folder_display[idx]
          render_all
          return folder[:full_name] if folder
          return nil
        when 'q', 'ESC', "\e"
          render_all
          return nil
        end
      end
    end

    def render_save_folder_picker(idx, title)
      lines = @folder_display.each_with_index.map do |folder, i|
        indent = "  " * folder[:depth]
        arrow = folder[:has_children] ? (folder[:collapsed] ? "▸ " : "▾ ") : "  "
        if i == idx
          "→ ".fg(226) + indent + arrow.fg(226) + folder[:name].b.u.fg(255)
        else
          "  " + indent + arrow.fg(245) + folder[:name].fg(245)
        end
      end

      @panes[:left].text = lines.join("\n")
      # Scroll to keep selected item visible
      page_height = @panes[:left].h
      page_height -= 2 if @panes[:left].border
      if @folder_display.size > page_height
        scrolloff = 3
        max_scroll = @folder_display.size - page_height
        if idx - @panes[:left].ix < scrolloff
          @panes[:left].ix = [idx - scrolloff, 0].max
        elsif @panes[:left].ix + page_height - 1 - idx < scrolloff
          @panes[:left].ix = [idx + scrolloff - page_height + 1, max_scroll].min
        end
      else
        @panes[:left].ix = 0
      end
      @panes[:left].refresh

      @panes[:top].text = " Heathrow - ".b.fg(255) + title.b.fg(226)
      @panes[:top].refresh
      @panes[:bottom].text = " j/k:Navigate | Enter:Save here | h/l:Collapse/Expand | ESC:Cancel".fg(245)
      @panes[:bottom].refresh
    end

    # ── Configure save shortcuts (s=) ──
    # Interactive editor for save folder shortcuts stored in config.yml.
    def configure_save_shortcuts
      shortcuts = save_folder_shortcuts.dup

      loop do
        # Display current shortcuts in right pane
        info = []
        info << "SAVE FOLDER SHORTCUTS".b.fg(226)
        info << ""
        if shortcuts.empty?
          info << "No shortcuts configured".fg(245)
        else
          shortcuts.sort_by { |k, _| k }.each do |key, folder|
            info << "  s#{key.to_s.ljust(4).fg(10)} → #{folder}".fg(255)
          end
        end
        info << ""
        info << "Commands:".fg(245)
        info << "  a = Add new shortcut".fg(245)
        info << "  d = Delete a shortcut".fg(245)
        info << "  ESC/q = Done".fg(245)
        @panes[:right].text = info.join("\n")
        @panes[:right].refresh

        chr = getchr
        case chr
        when 'a'
          key = bottom_ask("Shortcut key (any key except B/F/=): ")
          next if key.nil? || key.strip.empty?
          key = key.strip
          if %w[B F =].include?(key)
            set_feedback("'#{key}' is reserved", 196, 2)
            next
          end
          folder = bottom_ask("Folder name: ")
          next if folder.nil? || folder.strip.empty?
          shortcuts[key] = folder.strip
        when 'd'
          key = bottom_ask("Delete shortcut key: ")
          next if key.nil? || key.strip.empty?
          shortcuts.delete(key.strip)
        when 'q', 'ESC', "\e", 'h', 'LEFT'
          break
        end
      end

      # Save to config.yml
      @config.settings['save_folders'] = shortcuts
      @config.save
      @save_folders = shortcuts  # Update cached value
      set_feedback("Save shortcuts updated", 156, 2)
      render_all
    end

    # ── Label management (l key) ──
    # Add or remove labels on the current message or all tagged messages.
    # Labels are stored as a JSON array. A message can have many labels.
    # Views can filter on labels: { field: "label", op: "like", value: "MyLabel" }
    def label_message
      tagged_hint = @tagged_messages.size > 0 ? " (#{@tagged_messages.size} tagged)" : ""
      action = bottom_ask("Label#{tagged_hint} (+add / -remove / ? to list): ", '+')
      return if action.nil?

      if action.strip == '?'
        show_all_labels
        return
      end

      adding = !action.start_with?('-')
      label_name = action.sub(/^[+\-]\s*/, '').strip
      return if label_name.empty?

      # Collect messages to label
      msgs = if @tagged_messages.size > 0
               @filtered_messages.select { |m| m['id'] && @tagged_messages.include?(m['id']) }
             else
               msg = current_message
               return unless msg && !msg['is_header'] && !msg['is_channel_header'] && !msg['is_thread_header']
               [msg]
             end
      return if msgs.empty?

      count = 0
      msgs.each do |msg|
        labels = msg['labels']
        labels = JSON.parse(labels) if labels.is_a?(String) rescue []
        labels = [] unless labels.is_a?(Array)

        if adding
          next if labels.include?(label_name)
          labels << label_name
        else
          next unless labels.include?(label_name)
          labels.delete(label_name)
        end

        @db.execute("UPDATE messages SET labels = ? WHERE id = ?", labels.to_json, msg['id'])
        msg['labels'] = labels
        count += 1
      end

      @tagged_messages.clear if @tagged_messages.size > 0

      verb = adding ? "Added" : "Removed"
      set_feedback("#{verb} label '#{label_name}' on #{count} message#{count > 1 ? 's' : ''}", 156, 3)
      render_all
    end

    # Show all labels currently in use across all messages
    def show_all_labels
      rows = @db.execute("SELECT labels FROM messages WHERE labels IS NOT NULL AND labels != '[]'")
      label_counts = Hash.new(0)
      rows.each do |row|
        labels = JSON.parse(row['labels']) rescue next
        labels.each { |l| label_counts[l] += 1 } if labels.is_a?(Array)
      end

      if label_counts.empty?
        set_feedback("No labels in use", 245, 2)
        return
      end

      lines = ["LABELS IN USE".b.fg(226), ""]
      label_counts.sort_by { |_, c| -c }.each do |label, count|
        lines << "  #{label}".fg(51) + " (#{count})".fg(245)
      end
      lines << ""
      lines << "Use 'l' to add/remove labels.".fg(245)
      lines << "Filter views on labels with 'F' (label field).".fg(245)
      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh
    end

    # ========== AI Assistant (I key) ==========
    # Interactive Claude Code integration for message-related AI tasks.
    # Uses `claude -p` CLI for one-shot queries with full CLAUDE.md context.

    def ai_assistant
      msg = current_message
      return unless msg && !msg['is_header'] && !msg['is_channel_header'] && !msg['is_thread_header']
      msg = ensure_full_message(msg)

      # Build message context
      context = ai_message_context(msg)

      # Show menu
      set_feedback("AI: d=Draft reply  f=Fix grammar  s=Summarize  t=Translate  a=Ask...", 226, 10)
      chr = getchr(10)
      if chr.nil? || chr == 'ESC' || chr == "\e"
        @feedback_expires_at = nil
        render_bottom_bar
        return
      end

      case chr
      when 'd'
        ai_draft_reply(msg, context)
      when 'f'
        ai_fix_grammar(msg, context)
      when 's'
        ai_summarize(msg, context)
      when 't'
        ai_translate(msg, context)
      when 'a'
        ai_freeform(msg, context)
      else
        @feedback_expires_at = nil
        render_bottom_bar
      end
    end

    def ai_message_context(msg)
      lines = []
      lines << "Source: #{msg['source_type']}"
      lines << "From: #{msg['sender_name'] || msg['sender']}"
      lines << "To: #{msg['recipient'] || msg['recipients']}"
      lines << "Subject: #{msg['subject']}" if msg['subject']
      lines << "Date: #{msg['timestamp']}"
      folder = msg['folder']
      lines << "Folder: #{folder}" if folder
      lines << ""
      lines << msg['content'].to_s
      lines.join("\n")
    end

    def ai_call(prompt)
      require 'open3'
      @panes[:bottom].text = " AI thinking... (this may take a moment)".fg(226)
      @panes[:bottom].refresh

      env = ENV.to_h.reject { |k, _| k == 'CLAUDECODE' }

      # Log prompt for debugging
      File.open('/tmp/heathrow_ai.log', 'a') do |f|
        f.puts "=== AI CALL #{Time.now} ==="
        f.puts "Prompt length: #{prompt.length}"
      end

      result = nil
      stderr_out = nil
      status = nil
      begin
        result, stderr_out, status = Open3.capture3(env, 'claude', '-p',
          '--max-turns', '1', stdin_data: prompt)
      rescue => e
        File.open('/tmp/heathrow_ai.log', 'a') { |f| f.puts "Exception: #{e.message}" }
        set_feedback("AI error: #{e.message}", 196, 3)
        return nil
      end

      File.open('/tmp/heathrow_ai.log', 'a') do |f|
        f.puts "Exit status: #{status.exitstatus}"
        f.puts "Result length: #{result&.length}"
        f.puts "Stderr: #{stderr_out}" if stderr_out && !stderr_out.empty?
        f.puts "Result preview: #{result&.slice(0, 200)}"
      end

      render_bottom_bar

      unless status.success?
        set_feedback("AI error (exit #{status.exitstatus})", 196, 3)
        return nil
      end

      if result.nil? || result.strip.empty?
        set_feedback("AI returned empty response", 226, 3)
        return nil
      end

      result
    end

    def ai_show_response(title, response)
      lines = []
      lines << title.b.fg(226)
      lines << ""
      lines << response
      @panes[:right].ix = 0
      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh
      @panes[:right].content_update = false
    end

    def ai_draft_reply(msg, context)
      identity = current_identity
      from_info = identity ? "I am: #{identity[:from]}" : ""
      prompt = <<~PROMPT
        You are drafting an email reply. Write only the reply body text, no headers.
        Match the tone and language of the original message.
        Keep it concise and natural. #{from_info}

        Original message:
        #{context}

        Draft a reply:
      PROMPT

      response = ai_call(prompt)
      return unless response

      ai_show_response("DRAFT REPLY (press 'r' to open in editor)", response)

      # Wait for user action
      @panes[:bottom].text = " r=Open in editor with draft | y=Copy to clipboard | ESC=Dismiss".fg(245)
      @panes[:bottom].refresh
      chr = getchr
      case chr
      when 'r'
        # Start a reply with the draft pre-filled
        ai_reply_with_draft(msg, response.strip)
      when 'y'
        IO.popen('xclip -selection clipboard', 'w') { |io| io.write(response.strip) } rescue nil
        set_feedback("Draft copied to clipboard", 156, 2)
      end
      @panes[:right].content_update = true
      render_all
    end

    def ai_reply_with_draft(msg, draft)
      source_id = msg['source_id']
      source = @source_manager.sources[source_id]
      return unless source

      stype = source['plugin_type'] || source['type']
      return unless stype == 'maildir' || stype == 'imap' || stype == 'gmail'

      require_relative '../message_composer'
      identity = current_identity
      composer = MessageComposer.new(msg, identity: identity, address_book: @address_book, editor_args: @editor_args)

      # Build the reply template, then inject the draft
      template = composer.send(:build_reply_template, false)
      # Insert draft after the blank line following headers
      lines = template.lines
      header_end = nil
      lines.each_with_index do |line, i|
        if line.strip.empty? && header_end.nil?
          header_end = i
          break
        end
      end

      if header_end
        # Replace the empty body area with draft
        before = lines[0..header_end].map(&:chomp)
        # Find the attribution line and quoted text
        after_lines = lines[(header_end + 1)..]
        after = after_lines ? after_lines.map(&:chomp) : []
        new_template = (before + ["", draft, ""] + after).join("\n")
      else
        new_template = template
      end

      # Write to temp file and open editor
      tempfile = Tempfile.new(['heathrow-ai-draft', '.eml'])
      begin
        tempfile.write(new_template)
        tempfile.flush

        cursor_line = (header_end || 0) + 2
        run_editor(tempfile.path, cursor_line: cursor_line)

        tempfile.rewind
        content = tempfile.read
        return if content.rstrip == new_template.rstrip

        composed = composer.send(:parse_composed_message, content)
        finalize_compose(source, composed) if composed
      ensure
        tempfile.close
        tempfile.unlink
      end
      render_bottom_bar
    end

    def ai_fix_grammar(msg, context)
      prompt = <<~PROMPT
        Fix grammar and spelling in the following message content.
        Return ONLY the corrected text, preserving the original language and tone.
        If the text is already correct, return it unchanged.
        Do not add explanations.

        #{msg['content']}
      PROMPT

      response = ai_call(prompt)
      return unless response

      # Show diff-like view
      lines = []
      lines << "GRAMMAR/SPELLING FIX".b.fg(226)
      lines << ""
      lines << "Original:".fg(245)
      lines << msg['content'].to_s
      lines << ""
      lines << "Corrected:".fg(156)
      lines << response.strip
      @panes[:right].ix = 0
      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh
      @panes[:right].content_update = false

      @panes[:bottom].text = " y=Copy corrected text | ESC=Dismiss".fg(245)
      @panes[:bottom].refresh
      chr = getchr
      if chr == 'y'
        IO.popen('xclip -selection clipboard', 'w') { |io| io.write(response.strip) } rescue nil
        set_feedback("Corrected text copied to clipboard", 156, 2)
      end
      @panes[:right].content_update = true
      render_all
    end

    def ai_summarize(msg, context)
      prompt = <<~PROMPT
        Summarize this message concisely in bullet points.
        Keep the same language as the original.

        #{context}
      PROMPT

      response = ai_call(prompt)
      return unless response
      ai_show_response("SUMMARY", response)
    end

    def ai_translate(msg, context)
      lang = bottom_ask("Translate to language: ", "English")
      return if lang.nil? || lang.strip.empty?

      prompt = <<~PROMPT
        Translate the following message to #{lang.strip}.
        Return only the translated text, no explanations.

        #{msg['content']}
      PROMPT

      response = ai_call(prompt)
      return unless response
      ai_show_response("TRANSLATION (#{lang.strip})", response)
    end

    def ai_freeform(msg, context)
      question = bottom_ask("Ask about this message: ")
      return if question.nil? || question.strip.empty?

      prompt = <<~PROMPT
        The user is reading a message in their email/messaging client and has a question.

        Message context:
        #{context}

        User's question: #{question}
      PROMPT

      response = ai_call(prompt)
      return unless response
      ai_show_response("AI RESPONSE", response)
    end

    # Notmuch full-text search
    def notmuch_search
      require_relative '../notmuch'
      has_notmuch = Heathrow::Notmuch.available?

      # Source picker: let user scope the search
      sources = @db.get_sources(true)  # enabled only
      scope_hint = sources.each_with_index.map { |s, i| "#{i + 1}:#{s['name']}" }.join(' ')
      scope = bottom_ask("Search in (Enter=all, #{scope_hint}): ", "")
      return if scope == 'ESC'

      selected_source_ids = nil
      scope_label = "all"
      if scope && !scope.strip.empty?
        # Parse source selection (comma-separated numbers or name fragment)
        selected = []
        scope.split(',').each do |part|
          part = part.strip
          if part =~ /^\d+$/
            idx = part.to_i - 1
            selected << sources[idx] if idx >= 0 && idx < sources.size
          else
            # Name fragment match
            sources.each { |s| selected << s if s['name'].downcase.include?(part.downcase) }
          end
        end
        if selected.any?
          selected_source_ids = selected.map { |s| s['id'] }
          scope_label = selected.map { |s| s['name'] }.join(', ')
        end
      end

      query = bottom_ask("Search#{scope_label != 'all' ? " [#{scope_label}]" : ''}: ", "")
      return if query.nil? || query.strip.empty?

      @panes[:bottom].text = " Searching...".fg(226)
      @panes[:bottom].refresh

      results = []

      # Use notmuch for Maildir sources (fast indexed search)
      if has_notmuch && (selected_source_ids.nil? || sources.any? { |s| selected_source_ids&.include?(s['id']) && s['plugin_type'] == 'maildir' })
        files = Heathrow::Notmuch.search_files(query)
        unless files.empty?
          basenames = files.map { |f| File.basename(f) }
          basenames.each_slice(100) do |batch|
            ph = batch.map { '?' }.join(',')
            sql = "SELECT * FROM messages WHERE external_id IN (#{ph})"
            params = batch.dup
            if selected_source_ids
              sid_ph = selected_source_ids.map { '?' }.join(',')
              sql += " AND source_id IN (#{sid_ph})"
              params += selected_source_ids
            end
            rows = @db.execute(sql, *params)
            rows.each do |row|
              row['recipients'] = JSON.parse(row['recipients']) if row['recipients'].is_a?(String)
              row['metadata'] = JSON.parse(row['metadata']) if row['metadata'].is_a?(String)
              row['labels'] = JSON.parse(row['labels']) if row['labels'].is_a?(String)
              row['attachments'] = JSON.parse(row['attachments']) if row['attachments'].is_a?(String)
            end
            results.concat(rows)
          end
        end
      end

      # DB search for non-Maildir sources (or if notmuch unavailable)
      non_maildir_ids = if selected_source_ids
        selected_source_ids.select { |sid| sources.find { |s| s['id'] == sid && s['plugin_type'] != 'maildir' } }
      else
        sources.select { |s| s['plugin_type'] != 'maildir' }.map { |s| s['id'] }
      end
      if non_maildir_ids.any?
        db_filters = { search: query, source_ids: non_maildir_ids }
        db_results = @db.get_messages(db_filters, 500, 0, light: false)
        results.concat(db_results)
      end

      if results.empty?
        set_feedback("No results for: #{query}", 226, 3)
        return
      end

      # Show results as a temporary view
      @current_view = 'A'
      @in_source_view = false
      @panes[:right].content_update = true
      @current_source_filter = "Search: #{query}#{scope_label != 'all' ? " [#{scope_label}]" : ''}"
      @filtered_messages = results
      sort_messages
      @index = 0
      reset_threading
      set_feedback("#{results.size} results for: #{query}", 156, 0)
      render_all
    end

    # Toggle delete mark on current message (like mutt 'd')
    # Does NOT immediately delete — just marks visually with strikethrough
    def toggle_delete_mark
      @delete_marked ||= Set.new

      # If messages are tagged, operate on all tagged
      if @tagged_messages.size > 0
        already_marked = @tagged_messages.all? { |id| @delete_marked.include?(id) }
        if already_marked
          @tagged_messages.each { |id| @delete_marked.delete(id) }
          set_feedback("Unmarked #{@tagged_messages.size} from deletion", 156, 2)
        else
          @tagged_messages.each { |id| @delete_marked.add(id) }
          set_feedback("Marked #{@tagged_messages.size} for deletion ('<' to purge)", 196, 2)
        end
        @tagged_messages.clear
      else
        msg = current_message
        return unless msg
        return if header_message?(msg)

        if @delete_marked.include?(msg['id'])
          @delete_marked.delete(msg['id'])
          set_feedback("Undeleted", 156, 2)
        else
          @delete_marked.add(msg['id'])
          set_feedback("Marked for deletion (#{@delete_marked.size} total, '<' to purge)", 196, 2)
        end
        advance_index
      end
      render_message_list
      render_message_content
      render_bottom_bar
    end

    # Purge all delete-marked messages (like mutt '$' / sync-mailbox)
    def purge_deleted
      @delete_marked ||= Set.new
      count = @delete_marked.size
      if count == 0
        set_feedback("No messages marked for deletion", 226, 2)
        return
      end

      if @confirm_purge
        confirm = bottom_ask("Purge #{count} message#{count > 1 ? 's' : ''}? ENTER to confirm, ESC to cancel: ", '')
        if confirm.nil?
          set_feedback("Purge cancelled", 245, 2)
          return
        end
      end

      # Find messages in both filtered and display lists
      all_msgs = (@filtered_messages + (@display_messages || [])).uniq { |m| m['id'] }

      @delete_marked.each do |msg_id|
        msg = all_msgs.find { |m| m['id'] == msg_id }
        if msg
          # Delete the Maildir file (like mutt) so it doesn't reappear on sync
          delete_maildir_file(msg)
          @db.execute("DELETE FROM messages WHERE id = ?", msg_id)
        end
      end

      # Find the message just above the first deleted one (by ID, survives reindexing)
      display = @display_messages || @filtered_messages
      first_deleted_idx = display.each_with_index.find { |m, _| @delete_marked.include?(m['id']) }&.last
      target_msg_id = nil
      if first_deleted_idx && first_deleted_idx > 0
        # Walk backwards to find first non-deleted message above
        (first_deleted_idx - 1).downto(0) do |i|
          unless @delete_marked.include?(display[i]['id'])
            target_msg_id = display[i]['id']
            break
          end
        end
      end

      # Remove from current view
      @filtered_messages.reject! { |m| @delete_marked.include?(m['id']) }
      purged_ids = @delete_marked.dup
      @delete_marked.clear

      # Force threaded view to rebuild with purged messages gone
      reset_threading(true)

      # Position cursor on the message above the first deleted one
      new_display = @display_messages || @filtered_messages
      if target_msg_id
        found = new_display.index { |m| m['id'] == target_msg_id }
        @index = found || 0
      else
        @index = 0
      end
      @index = [new_display.size - 1, 0].max if @index >= new_display.size

      set_feedback("Purged #{count} messages", 156, 2)
      render_all
    end

    # Message reply/forward functions
    def show_loading(text = "Loading...")
      @panes[:bottom].text = " #{text}".fg(245)
      @panes[:bottom].refresh
    end

    def ensure_full_message(msg)
      if msg && msg['id'] && !msg['_full_loaded'] && !msg['is_header']
        full = @db.get_message(msg['id'])
        if full
          if msg.frozen?
            # Replace frozen hash in filtered_messages with mutable copy
            idx = @filtered_messages.index { |m| m.equal?(msg) }
            msg = full.merge('_full_loaded' => true)
            @filtered_messages[idx] = msg if idx
          else
            msg.merge!(full)
            msg['_full_loaded'] = true
          end
        end
      end
      msg
    end

    CHAT_SOURCE_TYPES = %w[weechat messenger instagram whatsapp discord telegram slack workspace].freeze

    def reply_to_message(force_editor: false)
      msg = current_message
      return unless msg
      msg = ensure_full_message(msg)

      # Don't allow replying to header messages
      if header_message?(msg)
        set_feedback("Cannot reply to section headers. Select a message.", 226, 3)
        render_bottom_bar
        return
      end

      source_id = msg['source_id']
      source = @db.get_source_by_id(source_id)
      return unless source

      source_type = source['plugin_type'] || source['type']

      if CHAT_SOURCE_TYPES.include?(source_type) && !force_editor
        chat_reply_inline(msg, source, source_type)
      elsif CHAT_SOURCE_TYPES.include?(source_type) && force_editor
        chat_reply_editor(msg, source, source_type)
      else
        # Email reply: full editor
        require_relative '../message_composer'
        identity = current_identity(msg)
        composer = MessageComposer.new(msg, identity: identity, address_book: @address_book, editor_args: @editor_args)

        @panes[:bottom].text = " Opening editor for reply...".fg(226)
        @panes[:bottom].refresh

        composed = composer.compose_reply(false)
        setup_display
        create_panes
        render_all
        if composed
          finalize_compose(source, composed, "Reply cancelled")
        else
          set_feedback("Reply cancelled", 245, 1)
        end
      end
    end

    def chat_reply_context(msg, source_type)
      meta = msg['metadata']
      meta = JSON.parse(meta) if meta.is_a?(String)
      meta = {} unless meta.is_a?(Hash)
      sender = msg['sender_name'] || msg['sender']

      # Extract target and display name based on source type
      case source_type
      when 'weechat'
        target = meta['buffer']
        display = meta['channel_name'] || meta['buffer_short'] || msg['subject']
      when 'messenger', 'instagram'
        target = meta['thread_id'] || meta['conversation_id'] || msg['thread_id']
        display = meta['conversation_name'] || msg['subject'] || sender
      when 'whatsapp'
        target = meta['chat_jid'] || msg['recipient']
        display = meta['chat_name'] || msg['subject'] || sender
      when 'discord'
        target = meta['channel_id'] || msg['recipient']
        display = meta['channel_name'] || msg['subject'] || sender
      when 'telegram'
        target = meta['chat_id'] || msg['recipient']
        display = meta['chat_name'] || msg['subject'] || sender
      when 'slack'
        target = meta['channel_id'] || msg['recipient']
        display = meta['channel_name'] || msg['subject'] || sender
      when 'workspace'
        target = meta['channel_id'] || msg['recipient']
        display = meta['channel_name'] || msg['subject'] || sender
      end

      { target: target, display: display, sender: sender }
    end

    def chat_reply_inline(msg, source, source_type)
      ctx = chat_reply_context(msg, source_type)
      reply = bottom_ask("Reply to #{ctx[:sender]} in #{ctx[:display]}: ", '')
      if reply && !reply.strip.empty?
        saved_index = @index
        composed = { to: ctx[:target], subject: nil, body: reply.strip, original_message: msg }
        send_composed_message(source, composed)
        @index = saved_index
        @pending_view_refresh = false  # Don't let background sync jump us
      else
        set_feedback("Reply cancelled", 245, 1)
      end
    end

    def chat_reply_editor(msg, source, source_type)
      ctx = chat_reply_context(msg, source_type)
      tempfile = Tempfile.new(['heathrow-chat', '.txt'])
      begin
        tempfile.write("# Reply to #{ctx[:sender]} in #{ctx[:display]}\n# Lines starting with # are ignored\n\n")
        tempfile.flush
        if run_editor(tempfile.path, cursor_line: 3, insert_mode: true)
          tempfile.rewind
          body = tempfile.read.lines.reject { |l| l.start_with?('#') }.join.strip
          if !body.empty?
            composed = { to: ctx[:target], subject: nil, body: body, original_message: msg }
            send_composed_message(source, composed)
          else
            set_feedback("Reply cancelled", 245, 1)
          end
        end
      ensure
        tempfile.close
        tempfile.unlink
      end
    end
    
    def reply_all_to_message
      msg = current_message
      return unless msg
      msg = ensure_full_message(msg)
      source_id = msg['source_id']
      
      # Check if source supports replying
      source = @db.get_source_by_id(source_id)
      return unless source
      
      require_relative '../message_composer'
      identity = current_identity(msg)
      composer = MessageComposer.new(msg, identity: identity, address_book: @address_book, editor_args: @editor_args)

      # Show composing status
      @panes[:bottom].text = " Opening editor for reply all...".fg(226)
      @panes[:bottom].refresh

      # Compose the reply
      composed = composer.compose_reply(true)

      setup_display
      create_panes
      render_all
      if composed
        finalize_compose(source, composed, "Reply-all cancelled")
      else
        set_feedback("Reply-all cancelled", 245, 1)
      end
    end

    def edit_message_content
      msg = current_message
      return unless msg
      return if header_message?(msg)
      msg = ensure_full_message(msg)

      source_id = msg['source_id']
      source = @db.get_source(source_id)
      return unless source

      require_relative '../message_composer'
      identity = current_identity(msg)
      composer = MessageComposer.new(nil, identity: identity, address_book: @address_book, editor_args: @editor_args)

      # Build draft from the message content
      draft = {
        'to' => '',
        'subject' => msg['subject'] || '',
        'body' => msg['content'] || ''
      }

      composed = composer.compose_draft(draft)
      if composed
        finalize_compose(source, composed, "Message cancelled")
      else
        set_feedback("Cancelled", 245, 1)
      end
    end

    def forward_message
      msg = current_message
      return unless msg
      msg = ensure_full_message(msg)
      source_id = msg['source_id']
      
      # Check if source supports sending
      source = @db.get_source_by_id(source_id)
      return unless source
      
      require_relative '../message_composer'
      identity = current_identity(msg)
      composer = MessageComposer.new(msg, identity: identity, address_book: @address_book, editor_args: @editor_args)

      # Show composing status
      @panes[:bottom].text = " Opening editor to forward message...".fg(226)
      @panes[:bottom].refresh

      # Extract attachments BEFORE editor
      orig_attachments = extract_original_attachments(msg)

      # Compose the forward
      composed = composer.compose_forward

      # Rebuild panes after editor (vim clears the screen)
      setup_display
      create_panes
      render_all

      if composed
        # Include original attachments
        composed[:attachments] = orig_attachments if orig_attachments && !orig_attachments.empty?
        finalize_compose(source, composed, "Forward cancelled")
      else
        set_feedback("Forward cancelled", 245, 1)
      end
    end
    
    # Extract original attachments from a message for forwarding
    def extract_original_attachments(msg)
      metadata = msg['metadata']
      metadata = JSON.parse(metadata) if metadata.is_a?(String) rescue nil
      return nil unless metadata.is_a?(Hash)

      file_path = metadata['maildir_file']
      return nil unless file_path && File.exist?(file_path)

      require 'mail'
      require 'tmpdir'
      mail = Mail.read(file_path)
      return nil if mail.attachments.empty?

      tmp_dir = File.join(Dir.tmpdir, "heathrow-fwd-#{Process.pid}")
      FileUtils.mkdir_p(tmp_dir)

      paths = []
      mail.attachments.each do |att|
        next unless att.filename
        out = File.join(tmp_dir, att.filename)
        File.write(out, att.decoded)
        paths << out
      end
      paths.empty? ? nil : paths
    rescue => e
      File.open('/tmp/heathrow-crash.log', 'a') { |f|
        f.puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} extract_attachments: #{e.class}: #{e.message}"
        f.puts "  #{e.backtrace&.first(3)&.join("\n  ")}"
      }
      nil
    end

    def compose_new_message
      # Build list of sendable channels from all DB sources
      channels = []

      @source_manager.sources.each_value do |s|
        stype = s['plugin_type'] || s['type']
        next unless s['enabled']
        case stype
        when 'maildir'
          channels.unshift({ name: 'Mail', source: s, type: 'mail' })
        when 'gmail', 'imap'
          channels << { name: s['name'] || 'Email', source: s, type: 'mail' }
        when 'weechat'
          config = s['config'].is_a?(String) ? (JSON.parse(s['config']) rescue {}) : (s['config'] || {})
          platform = config['platform'] || 'chat'
          channels << { name: s['name'] || platform.capitalize, source: s, type: 'weechat' }
        end
      end

      # Channel selector: TAB cycles, ENTER confirms, ESC cancels
      idx = 0
      loop do
        ch = channels[idx]
        @panes[:bottom].text = " New message via: #{ch[:name].b}  (TAB to cycle, ENTER to confirm, ESC to cancel)".fg(226)
        @panes[:bottom].refresh

        key = getchr
        case key
        when "\t", "TAB"
          idx = (idx + 1) % channels.size
        when "ENTER", "\r", "\n"
          break
        when "ESC", "\e"
          set_feedback("Cancelled", 245, 1)
          render_bottom_bar
          return
        end
      end

      selected = channels[idx]

      case selected[:type]
      when 'mail'
        compose_new_mail(selected[:source])
      when 'weechat'
        compose_weechat_message(selected[:source])
      end

      render_bottom_bar
    end

    # Check for mailto trigger file (written by wezterm or external scripts)
    def check_mailto_trigger
      mailto_file = File.join(HEATHROW_HOME, 'mailto')
      return unless File.exist?(mailto_file)
      addr = File.read(mailto_file).strip
      File.delete(mailto_file)
      return if addr.empty?

      # Find the first mail source
      mail_source = @source_manager.sources.values.find do |s|
        s['enabled'] && %w[maildir gmail imap].include?(s['plugin_type'] || s['type'])
      end
      return unless mail_source

      compose_new_mail(mail_source, mailto: addr)
    end

    def compose_new_mail(source, mailto: nil)
      require_relative '../message_composer'
      identity = current_identity

      # Check for postponed messages (mutt-style recall)
      pcount = @db.postponed_count
      if pcount > 0
        answer = bottom_ask("#{pcount} postponed message(s). Recall? [y/N] ")
        if answer&.strip&.downcase == 'y'
          draft = recall_postponed(source)
          if draft
            composer = MessageComposer.new(nil, identity: identity, address_book: @address_book, editor_args: @editor_args)
            composed = composer.compose_draft(draft)
          end
        end
      end

      unless composed
        composer = MessageComposer.new(nil, identity: identity, address_book: @address_book, editor_args: @editor_args)

        @panes[:bottom].text = " Opening editor for new message...".fg(226)
        @panes[:bottom].refresh

        composed = composer.compose_new(mailto)
      end
      setup_display
      create_panes
      render_all
      if composed
        finalize_compose(source, composed, "Message cancelled")
      else
        set_feedback("Message cancelled", 245, 1)
      end
    end

    def compose_weechat_message(source)
      config = source['config'].is_a?(String) ? (JSON.parse(source['config']) rescue {}) : (source['config'] || {})
      platform = config['platform'] || 'chat'

      prompt = "#{platform.capitalize} target (e.g. #general, username): "
      target = bottom_ask(prompt, '')
      return if target.nil? || target.strip.empty?
      target = target.strip

      # Offer inline or editor
      mode = bottom_ask("(i)nline or (e)ditor? ", 'i')
      return if mode.nil?

      body = if mode.strip.downcase.start_with?('e')
        edit_chat_in_editor(platform, target)
      else
        reply = bottom_ask("Message: ", '')
        reply&.strip
      end
      return if body.nil? || body.empty?

      require_relative '../sources/weechat'
      instance = Heathrow::Sources::Weechat.new(source)
      result = instance.send_message(target, nil, body)

      if result[:success]
        set_feedback(result[:message], 156, 3)
      else
        set_feedback(result[:message], 196, 3)
      end
    end

    def edit_chat_in_editor(platform, target)
      tempfile = Tempfile.new(['heathrow-chat', '.txt'])
      begin
        tempfile.write("# #{platform.capitalize} message to #{target}\n# Lines starting with # are ignored\n\n")
        tempfile.flush
        if run_editor(tempfile.path)
          tempfile.rewind
          tempfile.read.lines.reject { |l| l.start_with?('#') }.join.strip
        end
      ensure
        tempfile.close
        tempfile.unlink
      end
    end
    
    # Prompt user to attach files after composing an email.
    # Returns array of file paths, or nil if cancelled (ESC).
    def prompt_attachments(attachments = [], composed: nil)
      # Show who the message is going to
      to_info = ""
      if composed && composed[:to]
        to_info = " To: #{composed[:to]}"
        to_info += ", Cc: #{composed[:cc]}" if composed[:cc] && !composed[:cc].empty?
      end

      loop do
        # Show attachments and recipients in right pane
        right_lines = []
        if composed
          right_lines << "To: #{composed[:to]}".fg(theme[:accent]) if composed[:to]
          right_lines << "Cc: #{composed[:cc]}".fg(theme[:accent]) if composed[:cc] && !composed[:cc].to_s.empty?
          right_lines << "Subject: #{composed[:subject]}".fg(theme[:accent]) if composed[:subject]
          right_lines << ""
        end
        if attachments.empty?
          right_lines << "No attachments"
        else
          total_size = attachments.sum { |f| File.size(f) rescue 0 }
          size_str = total_size < 1_000_000 ? "#{(total_size / 1024.0).round(1)}KB" : "#{(total_size / 1_000_000.0).round(1)}MB"
          right_lines << "Attachments (#{attachments.size}, #{size_str}):".b
          attachments.each_with_index do |f, i|
            fsize = File.size(f) rescue 0
            fs = fsize < 1_000_000 ? "#{(fsize / 1024.0).round(1)}KB" : "#{(fsize / 1_000_000.0).round(1)}MB"
            right_lines << "  #{i + 1}. #{File.basename(f)} (#{fs})"
          end
        end
        @panes[:right].text = right_lines.join("\n")
        @panes[:right].refresh

        if attachments.empty?
          prompt = " Send (ENTER) | Edit (e) | Attach (a) | Postpone (p) | Cancel (ESC)"
        else
          prompt = " Send (ENTER) | Edit (e) | More (a) | Clear (x) | Postpone (p) | ESC"
        end

        @panes[:bottom].text = prompt.fg(226)
        @panes[:bottom].refresh

        chr = getchr
        case chr
        when 'ENTER'
          return attachments
        when 'ESC'
          return nil
        when 'p'
          return :postpone
        when 'e'
          return :edit
        when 'a', 'A'
          new_files = run_rtfm_picker
          attachments.concat(new_files) if new_files && !new_files.empty?
        when 'x', 'X'
          attachments.clear
        end
      end
    end

    # Launch RTFM in file picker mode, return array of selected file paths
    def run_rtfm_picker
      pick_file = "/tmp/rtfm_pick_#{Process.pid}.txt"
      File.delete(pick_file) if File.exist?(pick_file)

      # Restore terminal for RTFM
      system("stty sane 2>/dev/null")
      Cursor.show

      system("rtfm --pick=#{Shellwords.escape(pick_file)}")

      # Restore raw mode and redraw UI
      $stdin.raw!
      $stdin.echo = false
      Cursor.hide
      Rcurses.clear_screen
      setup_display
      create_panes
      render_all

      if File.exist?(pick_file)
        files = File.read(pick_file).lines.map(&:strip).reject(&:empty?)
        File.delete(pick_file) rescue nil
        files.select { |f| File.exist?(f) && File.file?(f) }
      else
        []
      end
    end

    # Unified send prompt loop: handles send, edit, postpone, cancel
    def finalize_compose(source, composed, cancel_label = "cancelled")
      require_relative '../message_composer'
      # Rebuild panes after editor (vim leaves terminal in unknown state)
      setup_display
      create_panes
      render_all
      pending_attachments = Array(composed[:attachments]).dup
      loop do
        attachments = prompt_attachments(pending_attachments, composed: composed)
        pending_attachments = []  # Only seed on first iteration
        case attachments
        when :postpone
          postpone_message(source, composed)
          return
        when :edit
          # Re-open editor with current composed data
          composer = MessageComposer.new(nil, identity: current_identity, address_book: @address_book, editor_args: @editor_args)
          re_composed = composer.compose_draft(composed.transform_keys(&:to_s))
          setup_display
          create_panes
          render_all
          if re_composed
            composed = re_composed
          else
            set_feedback("Edit cancelled", 245, 1)
            return
          end
        when nil
          set_feedback(cancel_label, 245, 1)
          return
        else
          composed[:attachments] = attachments unless attachments.empty?
          send_composed_message(source, composed)
          return
        end
      end
    end

    def postpone_message(source, composed)
      data = {
        from: composed[:from],
        to: composed[:to],
        cc: composed[:cc],
        bcc: composed[:bcc],
        reply_to: composed[:reply_to],
        subject: composed[:subject],
        body: composed[:body],
        extra_headers: composed[:extra_headers],
        attachments: composed[:attachments],
        original_message_id: composed[:original_message]&.[]('id')
      }
      @db.save_postponed(source['id'], data)
      set_feedback("Message postponed", 156, 3)
    end

    def recall_postponed(source)
      count = @db.postponed_count
      return nil if count == 0

      drafts = @db.list_postponed
      if count == 1
        draft = drafts.first
        data = JSON.parse(draft['data'])
        @db.delete_postponed(draft['id'])
        return data
      end

      # Multiple drafts: show picker
      rows, cols = IO.console.winsize
      pw = [cols - 20, 60].min
      ph = [count + 5, rows - 10].min
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false
      sel = 0

      build = -> {
        popup.full_refresh
        lines = ["", "  " + "Postponed Messages".b.fg(theme[:accent])]
        lines << "  " + "\u2500" * [pw - 6, 1].max
        drafts.each_with_index do |d, i|
          data = JSON.parse(d['data']) rescue {}
          date = Time.at(d['created_at']).strftime('%b %d %H:%M')
          subj = data['subject'] || '(no subject)'
          to = data['to'] || ''
          entry = "  #{date}  #{to.to_s[0..15].ljust(16)}  #{subj}"
          entry = entry[0..pw-6]
          lines << (i == sel ? entry.fg(theme[:accent]) : entry)
        end
        lines << ""
        lines << "  " + "ENTER:recall  d:delete  ESC:cancel".fg(245)
        popup.text = lines.join("\n")
        popup.refresh
      }

      build.call
      loop do
        k = getchr
        case k
        when 'ESC', 'q'
          render_all
          return nil
        when 'k', 'UP'
          sel = (sel - 1) % count
          build.call
        when 'j', 'DOWN'
          sel = (sel + 1) % count
          build.call
        when 'd'
          @db.delete_postponed(drafts[sel]['id'])
          drafts.delete_at(sel)
          count -= 1
          if count == 0
            render_all
            set_feedback("All postponed messages deleted", 245, 2)
            return nil
          end
          sel = [sel, count - 1].min
          build.call
        when 'ENTER'
          draft = drafts[sel]
          data = JSON.parse(draft['data'])
          @db.delete_postponed(draft['id'])
          render_all
          return data
        end
      end
    end

    def send_composed_message(source, composed)
      # Warn about empty subject (like mutt) - this part stays synchronous
      if composed[:subject] == '(no subject)'
        confirm = bottom_ask("No subject, send anyway? [y/N] ")
        unless confirm&.strip&.downcase == 'y'
          set_feedback("Send cancelled", 245, 2)
          return
        end
      end

      source_type = source['plugin_type'] || source['type']

      # Load source module and create instance (fast, keep synchronous)
      module_name = source_type == 'web' ? 'webpage' : source_type
      require_relative "../sources/#{module_name}"

      class_name = case module_name
                   when 'rss' then 'RSS'
                   when 'webpage' then 'Webpage'
                   else module_name.capitalize
                   end
      source_class = Heathrow::Sources.const_get(class_name)

      instance = begin
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        source_class.new(source['name'], config || {}, @db)
      rescue ArgumentError
        source_class.new(source)
      end

      unless instance.respond_to?(:send_message)
        set_feedback("This source doesn't support sending messages", 196, 4)
        return
      end

      # Show sending indicator and return control to UI immediately
      label = CHAT_SOURCE_TYPES.include?(source_type) ? "Sending #{source_type} message" : "Sending"
      set_feedback("#{label}...", 226, 0)
      render_bottom_bar

      # Capture values needed by the thread
      orig_msg = composed[:original_message]
      orig_id = orig_msg['id'] if orig_msg

      Thread.new do
        begin
          result = if CHAT_SOURCE_TYPES.include?(source_type)
            target = composed[:to]
            if target.nil? || target.empty?
              if orig_msg && orig_msg['metadata']
                meta = orig_msg['metadata']
                meta = JSON.parse(meta) if meta.is_a?(String)
                target = meta['buffer'] || meta['thread_id'] || meta['conversation_id'] ||
                         meta['chat_jid'] || meta['channel_id'] || meta['chat_id'] if meta.is_a?(Hash)
              end
            end
            instance.send_message(target, composed[:subject], composed[:body])
          else
            in_reply_to = nil
            if orig_msg && orig_msg['metadata']
              metadata = JSON.parse(orig_msg['metadata']) rescue {}
              in_reply_to = metadata['message_id']
            end

            identity = current_identity(orig_msg)
            smtp_cmd = identity ? identity[:smtp] : nil
            from = composed[:from]
            from = identity[:from] if (from.nil? || from.empty?) && identity

            instance.send_message(
              composed[:to],
              composed[:subject],
              composed[:body],
              in_reply_to,
              from: from,
              cc: composed[:cc],
              bcc: composed[:bcc],
              reply_to: composed[:reply_to],
              extra_headers: composed[:extra_headers],
              smtp_command: smtp_cmd,
              attachments: composed[:attachments]
            )
          end

          if result[:success]
            if orig_id
              # Re-read metadata from DB to get current maildir_file path
              # (poller may have renamed the file since we captured orig_msg)
              fresh = @db.get_message(orig_id)
              if fresh
                orig_msg = fresh
              end
              # Sync disk flag first, then DB, to avoid poller race condition
              sync_maildir_flag(orig_msg, 'R', true) if orig_msg
              @db.execute("UPDATE messages SET replied = 1 WHERE id = ?", [orig_id])
              orig_msg['replied'] = 1 if orig_msg
            end
            msg = result[:message]
            if composed[:attachments] && !composed[:attachments].empty?
              msg += " (#{composed[:attachments].size} attachment(s))"
            end
            set_feedback(msg, 156, 0)
            render_message_list if orig_id
          else
            set_feedback(result[:message], 196, 4)
          end
        rescue => e
          set_feedback("Send error: #{e.message}", 196, 4)
          File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "#{Time.now} send_composed_message error: #{e.message}\n#{e.backtrace.first(5).join("\n")}" }

        end
      end
    end

    def show_settings_popup
      rows, cols = IO.console.winsize
      pw = [cols - 20, 60].min
      pw = [pw, 46].max
      ph = 17
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false

      settings_rows = [:default_view, :color_theme, :date_format, :sort_order, :sort_inverted, :pane_width, :border_style, :confirm_purge, :download_folder, :editor_args, :default_email, :smtp_command]
      labels = {
        default_view: "Default View",
        color_theme: "Color Theme",
        date_format: "Date Format",
        sort_order: "Sort Order",
        sort_inverted: "Sort Inverted",
        pane_width: "Pane Width",
        border_style: "Border Style",
        confirm_purge: "Confirm Purge",
        download_folder: "Download Folder",
        editor_args: "Editor Args",
        default_email: "Default Email",
        smtp_command: "SMTP Command"
      }
      @download_folder ||= @config.get('download_folder') || '~/Downloads'

      theme_names = all_themes.keys
      date_formats = [
        ['%b %e', 'Mon  D'],
        ['%d/%m %H:%M', 'DD/MM HH:MM'],
        ['%m/%d %H:%M', 'MM/DD HH:MM'],
        ['%Y-%m-%d %H:%M', 'ISO'],
        ['%d.%m %H:%M', 'DD.MM HH:MM'],
        ['%d %b %H:%M', 'DD Mon HH:MM'],
        ['%b %d %H:%M', 'Mon DD HH:MM']
      ]
      sort_orders = ['latest', 'alphabetical', 'sender', 'from', 'conversation', 'unread', 'source']
      border_labels = ['none', 'right', 'both', 'left']
      # Build view choices: A, N, plus any user-defined views
      view_choices = [['A', 'All'], ['N', 'New/Unread']]
      @views.each do |key, v|
        view_choices << [key, "#{key}: #{v[:name]}"]
      end

      sel = 0

      build_popup = -> {
        popup.full_refresh  # Clear diff cache (theme editor/bottom_ask may have overlaid)
        inner_w = pw - 4
        lines = []
        lines << ""
        lines << "  " + "Settings".b.fg(theme[:accent])
        lines << "  " + "\u2500" * [inner_w - 3, 1].max

        settings_rows.each_with_index do |key, i|
          label = labels[key]
          val = case key
                when :default_view
                  vc = view_choices.find { |v| v[0] == @default_view }
                  vc ? vc[1] : @default_view
                when :color_theme  then @color_theme
                when :date_format
                  df = date_formats.find { |f| f[0] == @date_format }
                  df ? df[1] : @date_format
                when :sort_order   then @sort_order
                when :sort_inverted then @sort_inverted ? "Yes" : "No"
                when :pane_width   then "#{@width * 10}%"
                when :border_style then border_labels[@border] || 'none'
                when :confirm_purge then @confirm_purge ? "Yes" : "No"
                when :download_folder then @download_folder
                when :editor_args then @editor_args.to_s.empty? ? "(none)" : @editor_args
                when :default_email then @default_email.to_s.empty? ? "(not set)" : @default_email
                when :smtp_command then @smtp_command.to_s.empty? ? "(not set)" : @smtp_command
                end
          display = "  %-18s \u25C0 %-12s \u25B6" % [label, val]
          if i == sel
            lines << display.fg(theme[:accent])
          else
            lines << display
          end
        end

        lines << ""
        lines << "  " + "\u2191\u2193:navigate  \u2190\u2192:change  ESC:close".fg(245)

        popup.text = lines.join("\n")
        popup.ix = 0
        popup.refresh
      }

      cycle_setting = ->(dir, enter: false) {
        key = settings_rows[sel]
        case key
        when :default_view
          idx = view_choices.find_index { |v| v[0] == @default_view } || 0
          idx = (idx + dir) % view_choices.length
          @default_view = view_choices[idx][0]
        when :color_theme
          if enter
            show_theme_editor
          else
            idx = theme_names.index(@color_theme) || 0
            idx = (idx + dir) % theme_names.length
            @color_theme = theme_names[idx]
          end
          @topcolor = theme[:top_bg] || 235
          @bottomcolor = theme[:bottom_bg] || 235
          @cmdcolor = theme[:cmd_bg] || 17
        when :date_format
          idx = date_formats.find_index { |f| f[0] == @date_format } || 0
          idx = (idx + dir) % date_formats.length
          @date_format = date_formats[idx][0]
        when :sort_order
          idx = sort_orders.index(@sort_order) || 0
          idx = (idx + dir) % sort_orders.length
          @sort_order = sort_orders[idx]
        when :sort_inverted
          @sort_inverted = !@sort_inverted
        when :pane_width
          @width = ((@width - 1 + dir) % 6) + 1  # Cycle 1-6
        when :border_style
          @border = (@border + dir) % 4
        when :confirm_purge
          @confirm_purge = !@confirm_purge
        when :download_folder
          # Text input, handled separately on Enter
        end
      }

      build_popup.call

      loop do
        k = getchr
        case k
        when 'ESC', 'q'
          break
        when 'k', 'UP'
          sel = (sel - 1) % settings_rows.length
          build_popup.call
        when 'j', 'DOWN'
          sel = (sel + 1) % settings_rows.length
          build_popup.call
        when 'ENTER'
          case settings_rows[sel]
          when :download_folder
            result = bottom_ask("Download folder: ", @download_folder)
            @download_folder = result.strip if result && !result.strip.empty?
          when :editor_args
            result = bottom_ask("Editor args: ", @editor_args || '')
            @editor_args = result if result
          when :default_email
            result = bottom_ask("Default email: ", @default_email || '')
            @default_email = result.strip if result && !result.strip.empty?
          when :smtp_command
            result = bottom_ask("SMTP command: ", @smtp_command || '')
            @smtp_command = result.strip if result && !result.strip.empty?
          else
            cycle_setting.call(1, enter: true)
          end
          build_popup.call
        when 'l', 'RIGHT'
          case settings_rows[sel]
          when :download_folder
            result = bottom_ask("Download folder: ", @download_folder)
            @download_folder = result.strip if result && !result.strip.empty?
          when :editor_args
            result = bottom_ask("Editor args: ", @editor_args || '')
            @editor_args = result if result
          when :default_email
            result = bottom_ask("Default email: ", @default_email || '')
            @default_email = result.strip if result && !result.strip.empty?
          when :smtp_command
            result = bottom_ask("SMTP command: ", @smtp_command || '')
            @smtp_command = result.strip if result && !result.strip.empty?
          else
            cycle_setting.call(1)
          end
          build_popup.call
        when 'h', 'LEFT'
          case settings_rows[sel]
          when :download_folder
            result = bottom_ask("Download folder: ", @download_folder)
            @download_folder = result.strip if result && !result.strip.empty?
          when :editor_args
            result = bottom_ask("Editor args: ", @editor_args || '')
            @editor_args = result if result
          when :default_email
            result = bottom_ask("Default email: ", @default_email || '')
            @default_email = result.strip if result && !result.strip.empty?
          when :smtp_command
            result = bottom_ask("SMTP command: ", @smtp_command || '')
            @smtp_command = result.strip if result && !result.strip.empty?
          else
            cycle_setting.call(-1)
          end
          build_popup.call
        end
      end

      # Save all settings
      @config.set('ui.default_view', @default_view)
      @config.set('ui.color_theme', @color_theme)
      @config.set('ui.date_format', @date_format)
      @config.set('ui.sort_order', @sort_order)
      @config.set('ui.width', @width)
      @config.set('ui.border', @border)
      @config.set('ui.confirm_purge', @confirm_purge)
      @config.set('download_folder', @download_folder)
      @config.set('ui.editor_args', @editor_args)
      @config.set('default_email', @default_email)
      @config.set('smtp_command', @smtp_command)
      @config.save

      # Apply changes
      set_borders
      left_width = (@w - 4) * @width / 10
      @panes[:left].w = left_width
      @panes[:right].x = @panes[:left].w + 4
      @panes[:right].w = @w - @panes[:left].w - 4

      # Reset threading for sort changes
      reset_threading(true)
      sort_messages
      organize_current_messages(true)

      Rcurses.clear_screen
      @panes.each_value { |p| p.cleanup if p.respond_to?(:cleanup) }
      render_all
    rescue => e
      Rcurses.clear_screen
      render_all
    end

    def show_theme_editor
      rows, cols = IO.console.winsize
      # Core display keys only (source colors are set per-source via 'c' in Sources view)
      core_keys = [:unread, :read, :accent, :thread, :dm, :tag, :star,
                   :quote1, :quote2, :quote3, :quote4, :sig,
                   :top_bg, :bottom_bg, :cmd_bg]
      all_keys = core_keys

      # Work on a copy of current theme values
      editing = theme.dup

      # Determine if we're editing a custom theme or need a new name
      is_custom = @config.custom_themes.key?(@color_theme)
      theme_name = is_custom ? @color_theme : nil

      pw = [cols - 20, 52].min
      ph = [rows - 6, all_keys.size + 7].min
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = false

      sel = 0
      scroll_offset = 0
      visible_rows = ph - 6  # header + footer lines

      key_labels = {
        unread: "Unread", read: "Read", accent: "Accent", thread: "Thread",
        dm: "DM", tag: "Tag", quote1: "Quote 1", quote2: "Quote 2",
        quote3: "Quote 3", quote4: "Quote 4", sig: "Signature",
        top_bg: "Top Bar BG", bottom_bg: "Bottom Bar BG", cmd_bg: "Command BG"
      }

      build_editor = -> {
        inner_w = pw - 4
        lines = []
        title = theme_name ? "Edit: #{theme_name}" : "Theme Editor (#{@color_theme})"
        lines << ""
        lines << "  " + title.b.fg(editing[:accent] || 10)
        lines << "  " + "\u2500" * [inner_w - 3, 1].max

        # Ensure scroll follows selection
        scroll_offset = sel if sel < scroll_offset
        scroll_offset = sel - visible_rows + 1 if sel >= scroll_offset + visible_rows

        visible_keys = all_keys[scroll_offset, visible_rows] || []
        visible_keys.each_with_index do |key, vi|
          actual_idx = scroll_offset + vi
          val = editing[key] || 0
          label = key_labels[key] || key.to_s.sub('source_', 'Src: ').gsub('_', ' ').capitalize
          # Color swatch: two block chars in the color
          swatch = "\u2588\u2588".fg(val)
          line = "  %-16s %s %3d" % [label, swatch, val]
          lines << (actual_idx == sel ? line.fg(editing[:accent] || 10) : line)
        end

        # Scroll indicators
        lines << "  " + (scroll_offset + visible_rows < all_keys.size ? "\u2193 more".fg(245) : "")
        lines << "  " + "j/k:\u2195 h/l:\u00b11 H/L:\u00b110 #:set s:save ESC:back".fg(245)

        popup.text = lines.join("\n")
        popup.ix = 0
        popup.refresh
      }

      build_editor.call

      loop do
        k = getchr
        case k
        when 'ESC', 'q'
          break
        when 'k', 'UP'
          sel = (sel - 1) % all_keys.size
          build_editor.call
        when 'j', 'DOWN'
          sel = (sel + 1) % all_keys.size
          build_editor.call
        when 'PgUP'
          sel = [sel - visible_rows, 0].max
          build_editor.call
        when 'PgDOWN'
          sel = [sel + visible_rows, all_keys.size - 1].min
          build_editor.call
        when 'l', 'RIGHT'
          editing[all_keys[sel]] = [(editing[all_keys[sel]] || 0) + 1, 255].min
          build_editor.call
        when 'h', 'LEFT'
          editing[all_keys[sel]] = [(editing[all_keys[sel]] || 0) - 1, 0].max
          build_editor.call
        when 'L'
          editing[all_keys[sel]] = [(editing[all_keys[sel]] || 0) + 10, 255].min
          build_editor.call
        when 'H'
          editing[all_keys[sel]] = [(editing[all_keys[sel]] || 0) - 10, 0].max
          build_editor.call
        when /^[0-9]$/
          # Type a number directly
          result = bottom_ask("Color value (0-255): ", k)
          if result && result =~ /^\d+$/
            editing[all_keys[sel]] = result.to_i.clamp(0, 255)
          end
          build_editor.call
        when 's'
          # Save as custom theme
          unless theme_name
            result = bottom_ask("Theme name: ", "My Theme")
            next unless result && !result.strip.empty?
            theme_name = result.strip
          end
          # Write to heathrowrc
          save_custom_theme(theme_name, editing)
          @color_theme = theme_name
          @topcolor = editing[:top_bg] || 235
          @bottomcolor = editing[:bottom_bg] || 235
          @cmdcolor = editing[:cmd_bg] || 17
          set_feedback("Theme '#{theme_name}' saved", 46, 3)
          break
        end
      end
    end

    def save_custom_theme(name, colors)
      rc_path = Config::HEATHROWRC
      return unless File.exist?(rc_path)

      content = File.read(rc_path)

      # Build the theme line
      # Only include keys that differ from Default
      default = COLOR_THEMES['Default']
      diff = colors.select { |k, v| v != default[k] }
      return if diff.empty?

      pairs = diff.map { |k, v| "#{k}: #{v}" }.join(", ")
      theme_line = "theme '#{name}', #{pairs}"

      # Replace existing theme definition or append
      pattern = /^theme\s+'#{Regexp.escape(name)}'.*/
      if content.match?(pattern)
        content.sub!(pattern, theme_line)
      else
        # Insert before the first blank line after the last theme line, or at end
        if content.include?("# \u2500\u2500 Views")
          content.sub!(/^(# \u2500\u2500 Views)/, "#{theme_line}\n\n\\1")
        else
          content << "\n#{theme_line}\n"
        end
      end

      File.write(rc_path, content)

      # Reload config to pick up the new theme
      @config.reload_rc
    end

    # UI controls
    def change_width
      @width = (@width % 6) + 1  # Cycle through 1-6 (10%-60%)
      
      # Save to config
      @config.set('ui.width', @width)
      @config.save
      
      # Update pane dimensions without recreating them
      left_width = (@w - 4) * @width / 10
      
      # Update left pane width
      @panes[:left].w = left_width

      # Update right pane position and width
      @panes[:right].x = @panes[:left].w + 4
      @panes[:right].w = @w - @panes[:left].w - 4

      # Clear entire screen to remove old border residues, then re-render
      Rcurses.clear_screen
      render_all
      
      # Show width setting in bottom bar temporarily
      width_percent = @width * 10
      @panes[:bottom].text = " Width: #{@width} (Left: #{width_percent}%, Right: #{100-width_percent}%)".fg(245)
      @panes[:bottom].refresh
    end
    
    def cycle_border
      @border = (@border + 1) % 4

      # Save to config
      @config.set('ui.border', @border)
      @config.save

      # Recreate panes (which also sets borders) and re-render
      Rcurses.clear_screen
      create_panes
      render_all
    end
    
    
    def cycle_date_format
      # Define available date formats
      formats = [
        ['%b %e', 'Mutt (Mon  D)'],
        ['%d/%m %H:%M', 'European (DD/MM HH:MM)'],
        ['%m/%d %H:%M', 'US (MM/DD HH:MM)'],
        ['%Y-%m-%d %H:%M', 'ISO (YYYY-MM-DD HH:MM)'],
        ['%d.%m %H:%M', 'European dot (DD.MM HH:MM)'],
        ['%d %b %H:%M', 'Short month (DD Mon HH:MM)'],
        ['%b %d %H:%M', 'US short (Mon DD HH:MM)']
      ]
      
      # Find current format index
      current_index = formats.find_index { |f| f[0] == @date_format } || 0
      
      # Cycle to next format
      next_index = (current_index + 1) % formats.length
      @date_format = formats[next_index][0]
      format_name = formats[next_index][1]
      
      # Save to config
      @config.set('ui.date_format', @date_format)
      @config.save
      
      # Show current format in bottom bar
      @panes[:bottom].text = " Date format: #{format_name}".fg(156)
      @panes[:bottom].refresh
      
      # Refresh message list to show new format
      render_message_list
    end
    
    def cycle_sort_order
      # Cycle through: latest -> alphabetical -> sender -> from -> conversation -> unread -> source -> latest
      @sort_order = case @sort_order
      when 'latest' then 'alphabetical'
      when 'alphabetical' then 'sender'
      when 'sender' then 'from'
      when 'from' then 'conversation'
      when 'conversation' then 'unread'
      when 'unread' then 'source'
      else 'latest'  # This handles 'source' and any other value
      end
      
      # Save per-view sort for custom views, global for built-in views
      save_view_sort_order
      
      # For threaded views, we need to reload the full message list before re-sorting
      if @show_threaded && @current_view == 'A'
        # Reload all messages to ensure we have the complete list
        @filtered_messages = @db.get_messages({}, 1000, 0, light: true)
      elsif @show_threaded && @current_view == 'N'
        # Reload unread messages
        @filtered_messages = @db.get_messages({is_read: false}, 1000, 0, light: true)
      elsif @show_threaded && @current_source_filter
        # Reload messages for current source
        @filtered_messages = @db.get_messages({source_id: @current_source_filter}, nil, 0, light: true)
      end
      
      # Reset threading state to force reorganization with new sort (preserve collapsed state)
      reset_threading(true)
      
      # Re-sort and redisplay messages
      sort_messages
      
      # Force reinit the organizer with the newly sorted messages
      organize_current_messages(true)
      
      @index = 0  # Reset to top
      render_all  # Re-render everything to show the new sort
    end
    
    def toggle_sort_invert
      # Toggle the invert flag
      @sort_inverted = !@sort_inverted

      # Save per-view sort
      save_view_sort_order
      
      # For threaded views, we need to reload the full message list before re-sorting
      if @show_threaded && @current_view == 'A'
        # Reload all messages to ensure we have the complete list
        @filtered_messages = @db.get_messages({}, 1000, 0, light: true)
      elsif @show_threaded && @current_view == 'N'
        # Reload unread messages
        @filtered_messages = @db.get_messages({is_read: false}, 1000, 0, light: true)
      elsif @show_threaded && @current_source_filter
        # Reload messages for current source
        @filtered_messages = @db.get_messages({source_id: @current_source_filter}, nil, 0, light: true)
      end
      
      # Reset threading state to force reorganization with new sort (preserve collapsed state)
      reset_threading(true)
      
      # Re-sort and redisplay messages
      sort_messages
      
      # Force reinit the organizer with the newly sorted messages
      organize_current_messages(true)
      
      @index = 0  # Reset to top
      render_all  # Re-render everything
    end
    
    def save_view_sort_order
      view = @views[@current_view]
      if view && view[:filters].is_a?(Hash)
        # Save per-view
        view[:filters]['view_sort_order'] = @sort_order
        view[:filters]['view_sort_inverted'] = @sort_inverted
        @db.execute("UPDATE views SET filters = ?, updated_at = ? WHERE id = ?",
                    [JSON.generate(view[:filters]), Time.now.to_i, view[:id]])
      else
        # Global fallback for built-in views (A, N)
        @config.set('ui.sort_order', @sort_order)
        @config.save
      end
    end

    def sort_messages
      return if @filtered_messages.empty?

      # Make sure we have a mutable array
      @filtered_messages = @filtered_messages.dup if @filtered_messages.frozen?

      # Pre-compute timestamp cache to avoid repeated parsing in sort comparisons
      ts_cache = {}
      @filtered_messages.each { |m| ts_cache[m.object_id] = timestamp_to_time(m['timestamp']) }

      begin
        case @sort_order
        when 'alphabetical'
          # Sort alphabetically by subject/title (ignoring special chars)
          @filtered_messages.sort! do |a, b|
            # Get subjects and clean them for comparison
            subject_a_raw = (a['subject'] || a['content'] || '').to_s
            subject_b_raw = (b['subject'] || b['content'] || '').to_s
            
            # Remove special characters at the beginning for sorting
            subject_a = subject_a_raw.gsub(/^[#\[\]@\s]+/, '').downcase
            subject_b = subject_b_raw.gsub(/^[#\[\]@\s]+/, '').downcase
            
            subject_cmp = subject_a <=> subject_b
            
            if subject_cmp != 0
              subject_cmp
            elsif subject_a_raw.downcase != subject_b_raw.downcase
              # If cleaned names are same but originals differ, compare originals
              subject_a_raw.downcase <=> subject_b_raw.downcase
            else
              # If subjects are the same, sort by timestamp
              begin
                ts_cache[b.object_id] <=> ts_cache[a.object_id]
              rescue
                0
              end
            end
          end
        when 'sender'
          # Sort by sender name, then by timestamp
          @filtered_messages.sort! do |a, b|
            sender_a = (a['sender'] || '').to_s.downcase
            sender_b = (b['sender'] || '').to_s.downcase
            sender_cmp = sender_a <=> sender_b
            
            if sender_cmp != 0
              sender_cmp
            else
              # Safe timestamp comparison
              begin
                ts_cache[b.object_id] <=> ts_cache[a.object_id]
              rescue
                0
              end
            end
          end
        when 'from'
          # Group by sender, most recently active sender first
          # Within each sender group, newest message first
          latest_per_sender = {}
          @filtered_messages.each do |m|
            s = display_sender(m).downcase
            t = ts_cache[m.object_id] || Time.at(0)
            latest_per_sender[s] = t if !latest_per_sender[s] || t > latest_per_sender[s]
          end
          @filtered_messages.sort! do |a, b|
            sa = display_sender(a).downcase
            sb = display_sender(b).downcase
            if sa == sb
              (ts_cache[b.object_id] || Time.at(0)) <=> (ts_cache[a.object_id] || Time.at(0))
            else
              (latest_per_sender[sb] || Time.at(0)) <=> (latest_per_sender[sa] || Time.at(0))
            end
          end
        when 'unread'
          # Sort by unread first, then by timestamp
          @filtered_messages.sort! do |a, b|
            read_cmp = a['is_read'].to_i <=> b['is_read'].to_i
            if read_cmp != 0
              read_cmp  # Unread (0) first
            else
              # Safe timestamp comparison
              begin
                ts_cache[b.object_id] <=> ts_cache[a.object_id]
              rescue
                0  # If timestamp parsing fails, consider them equal
              end
            end
          end
        when 'conversation'
          # Group by conversation: thread_id, or sender (the other party)
          @filtered_messages.sort! do |a, b|
            conv_a = a['thread_id'] || a['sender'] || ''
            conv_b = b['thread_id'] || b['sender'] || ''
            conv_cmp = conv_a.to_s.downcase <=> conv_b.to_s.downcase

            if conv_cmp != 0
              conv_cmp
            else
              begin
                ts_cache[b.object_id] <=> ts_cache[a.object_id]
              rescue
                0
              end
            end
          end
        when 'source'
          # Sort by source type, then by timestamp
          @filtered_messages.sort! do |a, b|
            source_a = (a['source_type'] || '').to_s
            source_b = (b['source_type'] || '').to_s
            source_cmp = source_a <=> source_b

            if source_cmp != 0
              source_cmp
            else
              # Safe timestamp comparison
              begin
                ts_cache[b.object_id] <=> ts_cache[a.object_id]
              rescue
                0  # If timestamp parsing fails, consider them equal
              end
            end
          end
        else  # 'latest'
          # Sort by timestamp descending (newest first)
          @filtered_messages.sort! do |a, b|
            begin
              ts_cache[b.object_id] <=> ts_cache[a.object_id]
            rescue
              0  # If timestamp parsing fails, consider them equal
            end
          end
        end
        
        # Apply invert if flag is set
        @filtered_messages.reverse! if @sort_inverted
        
      rescue => e
        # If any error occurs during sorting, just leave the list as is
        # and show an error message
        @panes[:bottom].text = " Sort error: #{e.message}".fg(196)
        @panes[:bottom].refresh
      end
    end
    
    def show_help
      @in_help_mode = true
      @panes[:right].content_update = false
      @panes[:right].ix = 0  # Reset scroll position
      help_text = get_help_text  # Use the colored version directly



      # Just set the text and let rcurses handle everything
      @panes[:right].text = help_text
      @panes[:right].refresh

      @showing_help = true
    end

    def show_extended_help
      @in_help_mode = true
      @panes[:right].content_update = false
      @panes[:right].ix = 0  # Reset scroll position
      
      # Try to read README.md for comprehensive help
      readme_path = File.join(File.dirname(__FILE__), '..', '..', '..', 'README.md')
      
      if File.exist?(readme_path)
        readme_text = File.read(readme_path)
        colored_text = colorize_markdown(readme_text)
        @panes[:right].text = colored_text
        @panes[:right].refresh
      else
        # Show extended help text
        @panes[:right].text = get_extended_help_text
        @panes[:right].refresh
      end
      
      @showing_help = false  # Reset for next time
    end
    
    def colorize_markdown(text)
      colored = ""
      text.lines.each do |line|
        case line
        when /^(#+)\s+(.+)$/  # Headers
          level = $1.length
          content = $2.chomp
          case level
          when 1
            colored += content.b.fg(226) + "\n"  # Bright yellow bold for H1
          when 2
            colored += content.b.fg(14) + "\n"   # Cyan bold for H2
          when 3
            colored += content.b.fg(10) + "\n"   # Green bold for H3
          else
            colored += content.b.fg(11) + "\n"   # Yellow bold for H4-H6
          end
        when /^\s*[-*+]\s+(.+)$/  # Bullet points
          indent = line[/^\s*/]
          content = line.sub(/^\s*[-*+]\s+/, '').chomp
          colored += indent + "• ".fg(14) + content + "\n"
        when /^\s*\d+\.\s+(.+)$/  # Numbered lists
          indent = line[/^\s*/]
          number = line[/\d+/]
          content = line.sub(/^\s*\d+\.\s+/, '').chomp
          colored += indent + "#{number}.".fg(14) + " " + content + "\n"
        when /^\s*\|/  # Table rows
          # Color pipe characters and header cells
          colored_line = line.gsub(/\|/, "|".fg(240))
          if line =~ /^\s*\|.*\|.*\|/  # Has multiple columns
            colored += colored_line
          else
            colored += line
          end
        when /^```/  # Code blocks
          colored += line.fg(245)  # Gray for code block markers
        when /^---+$/, /^===+$/  # Horizontal rules
          colored += line.chomp.fg(240) + "\n"
        when /^\s*$/  # Empty lines
          colored += line
        else
          # Process inline markdown
          processed = line.dup
          
          # Bold text **text** or __text__
          processed.gsub!(/\*\*(.+?)\*\*/, '\1'.b)
          processed.gsub!(/__(.+?)__/, '\1'.b)
          
          # Italic text *text* or _text_
          processed.gsub!(/\*([^*]+)\*/, '\1'.fg(252))
          processed.gsub!(/_([^_]+)_/, '\1'.fg(252))
          
          # Inline code `code`
          processed.gsub!(/`([^`]+)`/, '\1'.fg(245))
          
          # Links [text](url)
          processed.gsub!(/\[([^\]]+)\]\([^)]+\)/, '\1'.fg(14))
          
          # Key bindings or commands in backticks
          processed.gsub!(/`([A-Z]+)`/, '\1'.fg(10))
          
          colored += processed
        end
      end
      colored
    end
    
    def get_extended_help_text
      <<~HELP
#{"HEATHROW - COMPREHENSIVE DOCUMENTATION".b.fg(226)}
#{"=" * 60}

Heathrow is a unified terminal interface for all your communication sources.
It aggregates messages from email, WhatsApp, Telegram, Discord, Reddit, 
RSS feeds, and more into a single, keyboard-driven interface.

#{"KEYBOARD SHORTCUTS".b.fg(theme[:accent])}

#{"Navigation".fg(11)}
      j/↓        Move down in message list
      k/↑        Move up in message list  
      h/←        Go back / parent view
      l/→/Enter  Open message / enter
      PgDn       Page down (10 messages)
      PgUp       Page up (10 messages)
      Home       Go to first message
      End        Go to last message
      
#{"Views & Filters".fg(11)}
      A          Show all messages
      N          Show new (unread) messages
      S          Sources configuration
      0-9        Custom filtered views
      Ctrl-f     Edit/create filter for current view
      K          Kill/delete a numbered view
      
#{"Message Actions".fg(11)}
      R          Toggle read/unread status
      Space      Collapse/expand thread (threaded view)
      G          Cycle view mode (flat / threaded / folder-grouped)
      { / }      Move section up/down (reorder feeds/channels)
      t          Tag message and move to next
      T          Tag/untag all messages in view
      Ctrl+t     Tag by regex (default=all, for batch ops)
      n          Jump to next unread message
      p          Jump to previous unread message
      */-        Toggle star/favorite
      d          Toggle delete mark
      r          Reply to message (if supported)
      g          Reply all / group reply
      
#{"Source Management".fg(11)} (in Sources view)
      a          Add new source
      e          Edit selected source
      d          Delete selected source
      t          Test selected source
      Space      Enable/disable source
      Enter      Show messages from source
      
#{"UI Controls".fg(11)}
      w          Cycle left pane width (1-5)
      Ctrl-b     Cycle border style (none/single/double)
      D          Cycle date format
      o          Cycle sort order (newest/oldest/unread)
      P          Settings popup (theme, format, etc.)
      r          Refresh all panes
      ?          Show help (press again for extended help)
      q          Quit Heathrow

#{"AI Assistant".fg(11)}
      I          AI assistant (Claude Code integration)
                   d = Draft a reply
                   f = Fix grammar/spelling
                   s = Summarize message
                   t = Translate message
                   a = Ask anything about the message

#{"FILTER SYNTAX".b.fg(theme[:accent])}
      
      Filters support powerful pattern matching:
      - Comma (,) = AND condition - all must match
      - Pipe (|) = OR condition - any can match
      - Combine both for complex filters
      
      Examples:
      - "error|warning" = matches error OR warning
      - "critical,production" = matches critical AND production
      - "error|warning,production" = (error OR warning) AND production
      
#{"SOURCE TYPES".b.fg(theme[:accent])}
      
#{"Email (IMAP)".fg(39)}
Connect to any IMAP email server. Supports Gmail, Outlook, Yahoo, etc.
Required: server, username, password

#{"RSS/Atom Feeds".fg(226)}
Subscribe to RSS and Atom feeds. Supports multiple feeds per source.
Required: feed URLs

#{"WhatsApp".fg(40)}
Connect via WhatsApp Web API (requires separate service).
Required: API URL

#{"Telegram".fg(51)}
Connect using Telegram API credentials.
Required: API ID, API Hash, phone number

#{"Discord".fg(99)}
Connect to Discord servers and DMs.
Required: Bot or user token

#{"Reddit".fg(202)}
Monitor subreddits and messages.
Required: Client ID, client secret

#{"Web Monitor".fg(208)}
Monitor web pages for changes.
Required: URL, optional CSS selector
      
#{"CONFIGURATION".b.fg(theme[:accent])}
      
      Config file: ~/.heathrow/config.yml
      Database: ~/.heathrow/heathrow.db
      
      Settings include:
      - UI preferences (width, borders, theme)
      - Polling intervals
      - Notification settings
      - Custom key bindings
      
#{"TIPS & TRICKS".b.fg(theme[:accent])}
      
      1. Use numbered views (0-9) to organize messages by topic
      2. Combine source filters with content patterns for precision
      3. Star important messages for quick access
      4. Use 'o' to change sort order based on your workflow
      5. Press 'w' to adjust pane width for your screen size
      
      For more information, visit: https://github.com/yourusername/heathrow
      HELP
    end
    
    def get_help_text
      <<~HELP
 #{"HEATHROW - Communication Hub In The Terminal".b.fg(226)}
 
 #{"BASIC KEYS".b.fg(theme[:accent])}
   #{"?".fg(10)}       = Show this help text (press again for extended help)
   #{"q".fg(10)}       = Quit Heathrow
   #{"Q".fg(10)}       = QUIT (force quit without saving state)
   #{"Ctrl-r".fg(10)}   = Refresh current view (sync + reload)
   #{"Ctrl-l".fg(10)}   = Redraw panes (no fetch)
   
 #{"NAVIGATION".b.fg(theme[:accent])}
   #{"j/↓".fg(10)}     = Move down in message list (rounds to top)
   #{"k/↑".fg(10)}     = Move up in message list (rounds to bottom)
   #{"h/←".fg(10)}     = Go back / parent view
   #{"l/→/⏎".fg(10)}   = Open message / enter
   #{"PgDn".fg(10)}    = Go one page down in message list
   #{"PgUp".fg(10)}    = Go one page up in message list
   #{"Home".fg(10)}    = Go to first message
   #{"End".fg(10)}     = Go to last message
   #{"J".fg(10)}       = Jump to date (yyyy-mm-dd)
   
 #{"RIGHT PANE SCROLLING".b.fg(theme[:accent])}
   #{"S-↓".fg(10)}     = Scroll content down one line
   #{"S-↑".fg(10)}     = Scroll content up one line
   #{"S-PgDn".fg(10)}  = Scroll content down one page
   #{"S-PgUp".fg(10)}  = Scroll content up one page
   #{"S-RIGHT".fg(10)} = Scroll content down one page
   #{"S-LEFT".fg(10)}  = Scroll content up one page
   #{"TAB".fg(10)}     = Scroll content down one page
 
 #{"VIEWS & FILTERS".b.fg(theme[:accent])}
   #{"A".fg(10)}       = Show all messages
   #{"N".fg(10)}       = Show new (unread) messages only
   #{"S".fg(10)}       = Sources configuration and management
   #{"0-9".fg(10)}     = Custom filtered views (configurable)
   #{"F1-F12".fg(10)}  = Additional custom views (configurable)
   #{"Ctrl-f".fg(10)}  = Edit/create filter for current view (0-9, F1-F12)
   #{"K".fg(10)}       = Kill/delete a view (with confirmation)
 
 #{"MESSAGE ACTIONS".b.fg(theme[:accent])}
   #{"R".fg(10)}       = Toggle read/unread status
   #{"M".fg(10)}       = Mark all messages in view as read
   #{"Space".fg(10)}   = Collapse/expand thread (threaded view)
   #{"G".fg(10)}       = Cycle view mode (flat / threaded / folder-grouped)
   #{"{ }".fg(10)}     = Move section up/down (reorder feeds/channels)
   #{"t".fg(10)}       = Tag message and move to next
   #{"T".fg(10)}       = Tag/untag all messages in view
   #{"Ctrl-t".fg(10)}  = Tag by regex (default=all, for batch ops)
   #{"n".fg(10)}       = Jump to next unread message
   #{"p".fg(10)}       = Jump to previous unread message
   #{"x".fg(10)}       = Open in browser (HTML emails rendered, others open URL)
   #{"*/−".fg(10)}     = Toggle star/favorite
   #{"d".fg(10)}       = Toggle delete mark
   #{"<".fg(10)}       = Purge delete-marked messages
   #{"r".fg(10)}       = Reply to message
   #{"g".fg(10)}       = Reply all / group reply
   #{"f".fg(10)}       = Forward message
   #{"e".fg(10)}       = Reply with editor (full headers)
   #{"E".fg(10)}       = Edit message as new (compose from content)
   #{"m".fg(10)}       = Mail/compose new message
   #{"y".fg(10)}       = Copy message ID to clipboard (for CC sessions)
   
 #{"SOURCE MANAGEMENT".b.fg(theme[:accent])} (in Sources view with 'S')
   #{"a".fg(10)}       = Add new source
   #{"e".fg(10)}       = Edit selected source
   #{"d".fg(10)}       = Delete selected source
   #{"Enter".fg(10)}   = Show all messages from selected source
   #{"Space".fg(10)}   = Enable/disable source
 
 #{"FOLDER NAVIGATION".b.fg(theme[:accent])}
   #{"B".fg(10)}       = Browse all folders (folder tree)
   #{"F".fg(10)}       = Browse favorite folders
   #{"+".fg(10)}       = Add/remove current folder from favorites
   #{"s".fg(10)}       = Save/file message to folder (s1-s9 for shortcuts)
   #{"sB".fg(10)}      = Save by browsing all folders
   #{"sF".fg(10)}      = Save by browsing favorite folders
   #{"s=".fg(10)}      = Configure save folder shortcuts
   #{"v".fg(10)}       = View/save/open attachments
   #{"V".fg(10)}       = Toggle inline image display
   #{"l".fg(10)}       = Add/remove labels (+label / -label / ? to list)
   #{"/".fg(10)}       = Full-text search (notmuch)

 #{"AI ASSISTANT".b.fg(theme[:accent])}
   #{"I".fg(10)}       = AI assistant (Claude Code integration)
   #{"  d".fg(10)}     = Draft a reply
   #{"  f".fg(10)}     = Fix grammar/spelling
   #{"  s".fg(10)}     = Summarize message
   #{"  t".fg(10)}     = Translate message
   #{"  a".fg(10)}     = Ask anything about the message

 #{"UI CONTROLS".b.fg(theme[:accent])}
   #{"w".fg(10)}       = Change left pane width (20% → 60%)
   #{"Ctrl-b".fg(10)}  = Cycle border style (none/single/double)
   #{"D".fg(10)}       = Cycle date/time format
   #{"o".fg(10)}       = Cycle sort order (newest/oldest/unread first)
   #{"i".fg(10)}       = Invert sort order (toggle reverse)
   #{"Y".fg(10)}       = Copy right pane content to clipboard
   #{"P".fg(10)}       = Settings popup (theme, format, etc.)
#{custom_bindings_help}
 Press #{"?".fg(10)} again for extended help • Any other key to continue
      HELP
    end
    
    def custom_bindings_help
      return "" unless @config
      bindings = @config.custom_bindings
      return "" if bindings.empty?

      lines = ["\n #{" CUSTOM BINDINGS".b.fg(theme[:accent])}"]
      bindings.each do |key, b|
        desc = b[:description] || b[:shell] || b[:action].to_s
        lines << "   #{key.fg(10).ljust(16)}= #{desc}"
      end
      lines.join("\n")
    end

    def render_sources_info
      source_text = []
      source_text << "SOURCE MANAGEMENT".b.fg(226)
      source_text << "=" * 40
      source_text << ""
      
      if @filtered_messages.empty?
        source_text << "No sources configured".fg(245)
        source_text << ""
        source_text << "Press 'a' to add a new source"
        source_text << ""
        source_text << "Available source types:".b.fg(39)
        types = @source_manager.get_source_types
        types.each do |key, info|
          source_text << "• #{info[:icon]} #{info[:name]}".fg(226)
          source_text << "  #{info[:description]}".fg(245)
        end
      else
        selected = @filtered_messages[@index]
        if selected
          source = @source_manager.sources[selected['id']]
          if source
            source_text << "Selected: #{source['name']}".b.fg(39)
            source_text << "Type: #{source['plugin_type'] || source['type']}".fg(245)
            source_text << "Status: #{source['enabled'] ? 'Enabled' : 'Disabled'}".fg(source['enabled'] ? 40 : 196)
            interval = (source['poll_interval'] || 900).to_i
            interval_str = if interval <= 0
              "Disabled"
            elsif interval < 60
              "#{interval}s"
            elsif interval < 3600
              "#{interval / 60}m"
            else
              "#{interval / 3600}h#{interval % 3600 > 0 ? " #{(interval % 3600) / 60}m" : ""}"
            end
            source_text << "Poll interval: #{interval_str}".fg(245)
            color_val = source['color']
            if color_val && !color_val.to_s.empty?
              color_num = color_val.to_s =~ /^\d+$/ ? color_val.to_i : color_val.to_s
              source_text << "Color: #{color_val}" + "  ██".fg(color_num)
            else
              auto_color = get_source_color(source)
              source_text << "Color: auto (#{auto_color})" + "  ██".fg(auto_color.to_i)
            end
            # Health status
            health = selected['health_ok'] ? "✓ OK".fg(40) : "✗ #{selected['health_msg']}".fg(196)
            source_text << "Health: #{health}"
            source_text << ""

            config = source['config']
            config = JSON.parse(config) if config.is_a?(String)
            config = {} unless config.is_a?(Hash)
            stype = source['type'] || source['plugin_type']

            if %w[rss web].include?(stype)
              item_name = stype == 'rss' ? 'feed' : 'page'
              items = config[stype == 'rss' ? 'feeds' : 'pages'] || []
              unless items.empty?
                source_text << "#{items.size} #{item_name}s:".b.fg(245)
                items.each_with_index do |item, i|
                  name = item['title'] || item['url'] || item['name'] || "Item #{i}"
                  status = item['last_status']
                  if status.nil?
                    indicator = "  "
                  elsif status == 'ok'
                    indicator = "✓ ".fg(40)
                  else
                    indicator = "✗ ".fg(196)
                  end
                  source_text << "  #{indicator}#{(i+1).to_s.rjust(2)}. #{name}".fg(status == 'ok' ? 252 : (status ? 196 : 245))
                  if status && status != 'ok'
                    source_text << "      #{status}".fg(88)
                  end
                end
                source_text << ""
              end

              # Context-sensitive actions
              source_text << "ACTIONS".b.fg(226)
              source_text << "-" * 40
              source_text << "a - Add #{item_name}"
              source_text << "d - Remove #{item_name}"
              source_text << "e - Edit source settings"
            else
              # Show config (hide secrets)
              source_text << "Configuration:".b.fg(39)
              config.each do |key, value|
                next if key.to_s =~ /password|secret|token/
                source_text << "  #{key}: #{value}".fg(245)
              end
              source_text << ""

              # Context-sensitive actions
              source_text << "ACTIONS".b.fg(226)
              source_text << "-" * 40
              source_text << "a - Add new source"
              source_text << "e - Edit this source"
              source_text << "d - Delete this source"
            end
            source_text << "c - Set color"
            source_text << "p - Set poll interval"
            source_text << "t - Test this source"
            source_text << "SPACE - Enable/disable"
            source_text << "ESC - Back to messages"
          end
        end
      end
      
      @panes[:right].text = source_text.join("\n")
      @panes[:right].refresh
    end
    
    def pick_source_color
      return unless @in_source_view && @filtered_messages[@index]
      source_id = @filtered_messages[@index]['id']
      source = @source_manager.sources[source_id]
      return unless source

      # Build a 256-color grid in the right pane
      lines = []
      lines << "COLOR PICKER for #{source['name']}".b.fg(226)
      lines << "=" * 40
      lines << ""
      lines << "Enter color number (0-255) or RGB hex (e.g. ff8800):"
      lines << ""

      # Show standard colors 0-15
      row = ""
      (0..15).each do |c|
        row += " #{c.to_s.rjust(3)}".fg(c > 6 && c < 10 || c == 0 ? 255 : 0).bg(c)
      end
      lines << row

      lines << ""

      # Show 216-color cube (16-231) in 6 rows of 36
      (0..5).each do |g|
        row = ""
        (0..35).each do |i|
          c = 16 + g * 36 + i
          fg = (g < 3 && i < 18) ? 255 : 0
          row += "#{c.to_s.rjust(4)}".fg(fg).bg(c)
        end
        lines << row
      end

      lines << ""

      # Grayscale 232-255
      row = ""
      (232..255).each do |c|
        fg = c < 244 ? 255 : 0
        row += "#{c.to_s.rjust(4)}".fg(fg).bg(c)
      end
      lines << row
      lines << ""

      current = source['color']
      lines << "Current: #{current || 'auto'}".fg(245)

      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh

      # Get input
      @panes[:bottom].prompt = "Color: "
      @panes[:bottom].text = current.to_s
      @editing = true
      @panes[:bottom].editline
      @editing = false
      input = @panes[:bottom].text.strip

      if input.empty?
        # Clear custom color
        @db.execute("UPDATE sources SET color = NULL WHERE id = ?", source_id)
        @source_colors.delete(source_id)
        set_feedback("Color reset to auto", 40, 2)
      elsif input =~ /^\d+$/ && input.to_i >= 0 && input.to_i <= 255
        @db.execute("UPDATE sources SET color = ? WHERE id = ?", input, source_id)
        @source_colors[source_id] = input.to_i
        set_feedback("Color set to #{input}", input.to_i, 2)
      elsif input =~ /^[0-9a-fA-F]{6}$/
        @db.execute("UPDATE sources SET color = ? WHERE id = ?", input, source_id)
        @source_colors[source_id] = input
        set_feedback("Color set to ##{input}", 40, 2)
      else
        set_feedback("Invalid color. Use 0-255 or 6-digit hex.", 196, 2)
      end

      # Update the pseudo-message in @filtered_messages so left pane reflects new color
      if @filtered_messages
        src_msg = @filtered_messages.find { |m| m['id'] == source_id }
        src_msg['source_color'] = @source_colors[source_id] if src_msg
      end

      # Refresh source manager cache and redraw
      @source_manager.reload
      render_all
    end

    def copy_message_id
      msg = current_message
      return unless msg && msg['id']
      id_str = "heathrow:#{msg['id']}"
      IO.popen('xclip -selection clipboard', 'w') { |io| io.write(id_str) }
      set_feedback("Message ID #{msg['id']} copied", 156, 2)
    rescue => e
      set_feedback("Copy failed: #{e.message}", 196, 2)
    end

    def copy_right_pane_to_clipboard
      text = @panes[:right].text
      if text && !text.strip.empty?
        # Strip ANSI codes for clean clipboard content
        clean = text.gsub(/\e\[[0-9;]*m/, '')
        IO.popen('xclip -selection clipboard', 'w') { |io| io.write(clean) }
        set_feedback("Copied to clipboard", 156, 2)
      else
        set_feedback("Nothing to copy", 196, 2)
      end
    rescue => e
      set_feedback("Copy failed: #{e.message}", 196, 2)
    end

    def set_view_top_bg
      view = @views[@current_view]
      unless view
        set_feedback("No custom view selected", 196, 2)
        return
      end

      current_bg = (view[:filters].is_a?(Hash) && view[:filters]['top_bg']) || @topcolor
      input = bottom_ask("Top bar bg (0-255/hex/empty=default): ", current_bg.to_s)
      return render_all if input.nil?

      view[:filters] ||= {}
      if input.strip.empty?
        view[:filters].delete('top_bg')
      else
        color = parse_color_value(input.strip)
        unless color
          set_feedback("Invalid color", 196, 2)
          return
        end
        view[:filters]['top_bg'] = input.strip
      end

      # Save to DB
      if view[:id]
        @db.save_view({
          id: view[:id],
          name: view[:name],
          key_binding: @current_view,
          filters: view[:filters],
          sort_order: view[:sort_order] || 'timestamp DESC'
        })
      end
      render_all
    end

    def set_source_poll_interval
      return unless @in_source_view && @filtered_messages[@index]
      source_id = @filtered_messages[@index]['id']
      source = @source_manager.sources[source_id]
      return unless source

      current = (source['poll_interval'] || 900).to_i
      current_str = if current <= 0
        "0 (disabled)"
      elsif current < 60
        "#{current}s"
      elsif current < 3600
        "#{current / 60}m"
      else
        "#{current / 3600}h"
      end

      lines = []
      lines << "POLL INTERVAL for #{source['name']}".b.fg(226)
      lines << "=" * 40
      lines << ""
      lines << "Current: #{current_str}".fg(245)
      lines << ""
      lines << "Enter interval (examples):".fg(39)
      lines << "  30s   = 30 seconds"
      lines << "  5m    = 5 minutes"
      lines << "  1h    = 1 hour"
      lines << "  0     = disabled"
      lines << ""
      lines << "Recommended:".fg(245)
      lines << "  Maildir: 30s (fast local scan)"
      lines << "  RSS/Web: 15m"
      lines << "  Messenger/Instagram: 5m"
      lines << "  Weechat: 2m"

      @panes[:right].text = lines.join("\n")
      @panes[:right].refresh

      @panes[:bottom].prompt = "Interval: "
      @panes[:bottom].text = ""
      @editing = true
      @panes[:bottom].editline
      @editing = false
      input = @panes[:bottom].text.strip

      seconds = parse_interval(input)
      if seconds.nil?
        set_feedback("Invalid interval format", 196, 2)
      else
        @db.execute("UPDATE sources SET poll_interval = ? WHERE id = ?", seconds, source_id)
        @source_last_sync&.delete("#{source['plugin_type']}_#{source_id}")
        label = seconds == 0 ? "disabled" : "#{seconds}s"
        set_feedback("Poll interval set to #{label}", 40, 2)
        @source_manager.reload
        saved_index = @index
        show_sources
        @index = saved_index
        render_message_list
        render_sources_info
        return
      end

      render_sources_info
    end

    def parse_interval(str)
      return nil if str.nil? || str.empty?
      case str.strip
      when /^(\d+)s$/i then $1.to_i
      when /^(\d+)m$/i then $1.to_i * 60
      when /^(\d+)h$/i then $1.to_i * 3600
      when /^(\d+)$/   then $1.to_i  # Raw seconds
      else nil
      end
    end

    def format_poll_interval(seconds)
      seconds = (seconds || 900).to_i
      return "Polling disabled" if seconds <= 0
      if seconds < 60
        "Poll every #{seconds}s"
      elsif seconds < 3600
        "Poll every #{seconds / 60}m"
      else
        "Poll every #{seconds / 3600}h"
      end
    end

    def show_filter_details(view_num, view_config)
      filter_text = []
      filter_text << "VIEW #{view_num} CONFIGURATION".b.fg(226)
      filter_text << "=" * 40
      filter_text << ""
      
      if view_config[:filters] && !view_config[:filters].empty?
        filter_text << "Name:".b.fg(39) + " #{view_config[:name] || 'View ' + view_num.to_s}"
        filter_text << ""
        filter_text << "Active Filters:".b.fg(39)
        filter_text << "-" * 20
        
        filters = view_config[:filters]
        
        if filters['source_types'] || filters[:source_types]
          types = filters['source_types'] || filters[:source_types]
          filter_text << "Source Types:".fg(226) + " #{types.join(', ')}"
        end
        
        if filters['sender_pattern'] || filters[:sender_pattern]
          pattern = filters['sender_pattern'] || filters[:sender_pattern]
          filter_text << "Sender Pattern:".fg(226) + " #{pattern}"
        end
        
        if filters['subject_pattern'] || filters[:subject_pattern]
          pattern = filters['subject_pattern'] || filters[:subject_pattern]
          filter_text << "Subject Pattern:".fg(226) + " #{pattern}"
        end
        
        if filters['content_patterns'] || filters[:content_patterns]
          patterns = filters['content_patterns'] || filters[:content_patterns]
          filter_text << "Content Patterns:".fg(226) + " #{patterns.join(', ')}"
          filter_text << "  (comma=AND, pipe=OR within each)".fg(245)
        end
        
        # Legacy filter display
        if filters['content_keywords'] || filters[:content_keywords]
          keywords = filters['content_keywords'] || filters[:content_keywords]
          filter_text << "Content Keywords:".fg(226) + " #{keywords.join(', ')}"
        end
        
        if filters['content_regex'] || filters[:content_regex]
          regex = filters['content_regex'] || filters[:content_regex]
          filter_text << "Content Regex:".fg(226) + " #{regex}"
        end
        
        if filters['search'] || filters[:search]
          search = filters['search'] || filters[:search]
          filter_text << "Legacy Search:".fg(226) + " #{search}"
        end
        
        if filters.key?('is_read') || filters.key?(:is_read)
          is_read = filters['is_read'] || filters[:is_read]
          status = is_read == false ? "Unread only" : (is_read == true ? "Read only" : "All")
          filter_text << "Read Status:".fg(226) + " #{status}"
        end
        
        filter_text << ""
        filter_text << "-" * 40
        filter_text << ""
        filter_text << "Matching Messages:".b.fg(39) + " #{@filtered_messages.size}"
      else
        filter_text << "No filters configured".fg(245)
        filter_text << ""
        filter_text << "This view will show an empty list until"
        filter_text << "you configure filters."
        filter_text << ""
        filter_text << "Available filter options:".b.fg(39)
        filter_text << "• Source types (email, whatsapp, etc.)"
        filter_text << "• Sender pattern (pipe | for OR)"
        filter_text << "• Subject pattern (pipe | for OR)"
        filter_text << "• Content patterns (comma AND, pipe OR)"
        filter_text << "• Label (use 'l' to add labels, filter here)"
        filter_text << "• Read/unread status"
        filter_text << ""
        filter_text << "Pattern Examples:".b.fg(39)
        filter_text << "Sender: Mom|Dad|Sister (any of them)"
        filter_text << "Content: error|warning,critical"
        filter_text << "  → (error OR warning) AND critical"
        filter_text << "Content: budget,2024|2025,report"
        filter_text << "  → budget AND (2024 OR 2025) AND report"
      end
      
      @panes[:right].text = filter_text.join("\n")
      @panes[:right].refresh
    end
    
    def kill_view
      # Ask which view to kill
      @panes[:bottom].clear
      view_key = bottom_ask("Kill which view (1-9, F1-F12)? ", "")

      return if view_key.nil? || view_key.empty?
      # Accept 1-9 or F1-F12
      return unless view_key.match?(/^[1-9]$/) || view_key.match?(/^F\d{1,2}$/i)
      view_key = view_key.upcase if view_key =~ /^f/i  # Normalize F-keys

      view = @views[view_key]

      if view.nil?
        @panes[:bottom].text = " View #{view_key} doesn't exist".fg(196)
        @panes[:bottom].refresh
        sleep(1)
        render_bottom_bar
        return
      end

      # Confirm deletion
      @panes[:bottom].clear
      confirm = bottom_ask("Kill view '#{view[:name]}'? (y/n) ", "")

      if confirm && confirm.downcase == 'y'
        @db.delete_view(view[:id]) if view[:id]
        @views.delete(view_key)

        @panes[:bottom].text = " View #{view_key} killed".fg(40)
        @panes[:bottom].refresh
        sleep(1)

        if @current_view == view_key
          show_all_messages
        else
          render_bottom_bar
        end
      else
        render_bottom_bar
      end
    end
    
    def edit_filter
      # Only allow filter editing for configurable views (0-9, F1-F12)
      view_key = @current_view
      unless view_key =~ /^[0-9]$/ || view_key =~ /^F\d{1,2}$/
        @panes[:bottom].text = " Can only configure filters for views 0-9 and F1-F12".fg(196)
        @panes[:bottom].refresh
        sleep 2
        render_all
        return
      end

      existing_view = @views[view_key] || {}
      existing_filters = existing_view[:filters] || {}

      # Extract current rule values for defaults
      rules = existing_filters.is_a?(Hash) ? (existing_filters['rules'] || []) : []
      current_vals = {}
      rules.each do |r|
        key = "#{r['field']}_#{r['op']}"
        current_vals[key] = r['value']
      end

      # If view exists, ask if they want to edit or clear
      if existing_view[:filters] && !existing_view[:filters].empty?
        choice = bottom_ask("View #{view_key} exists. (E)dit, (C)lear, or ESC to cancel: ", '')
        return render_all if choice.nil?

        case choice.downcase
        when 'c', 'clear'
          @db.delete_view(existing_view[:id]) if existing_view[:id]
          @views.delete(view_key)
          @filtered_messages = []
          @index = 0
          render_all
          return
        when 'e', 'edit'
          # Continue to edit
        else
          render_all
          return
        end
      end

      # Filter configuration wizard
      new_rules = []

      # 1. View name
      current_name = existing_view[:name] || "View #{view_key}"
      view_name = bottom_ask("View name (ESC to cancel): ", current_name)
      return render_all if view_name.nil?
      view_name = "View #{view_key}" if view_name.empty?

      # 2. Any field (search across sender, subject, content)
      current_search = current_vals['search_like'] || ''
      search_input = bottom_ask("Any field match (searches sender/subject/content - ESC cancel): ", current_search)
      return render_all if search_input.nil?
      unless search_input.empty?
        new_rules << { 'field' => 'search', 'op' => 'like', 'value' => search_input }
      end

      # 3. Folder filter (maildir_folder)
      current_folder = current_vals['folder_like'] || current_vals['folder_='] || ''
      folder_input = bottom_ask("Folder (e.g. Personal, Work.Archive - ESC cancel): ", current_folder)
      return render_all if folder_input.nil?
      unless folder_input.empty?
        new_rules << { 'field' => 'folder', 'op' => 'like', 'value' => folder_input }
      end

      # 4. Label filter
      current_label = current_vals['label_like'] || ''
      label_input = bottom_ask("Label (e.g. Niklas, Work, Important - ESC cancel): ", current_label)
      return render_all if label_input.nil?
      unless label_input.empty?
        new_rules << { 'field' => 'label', 'op' => 'like', 'value' => label_input }
      end

      # 5. Sender pattern
      current_sender = current_vals['sender_like'] || ''
      sender_input = bottom_ask("Sender pattern (e.g. Mom|Dad|Boss - ESC cancel): ", current_sender)
      return render_all if sender_input.nil?
      unless sender_input.empty?
        new_rules << { 'field' => 'sender', 'op' => 'like', 'value' => sender_input }
      end

      # 5. Subject pattern
      current_subject = current_vals['subject_like'] || ''
      subject_input = bottom_ask("Subject pattern (ESC cancel): ", current_subject)
      return render_all if subject_input.nil?
      unless subject_input.empty?
        new_rules << { 'field' => 'subject', 'op' => 'like', 'value' => subject_input }
      end

      # 6. Source filter
      current_source = current_vals['source_like'] || ''
      source_names = @db.get_sources(true).map { |s| s['name'] }.join(', ')
      source_input = bottom_ask("Source (#{source_names} - ESC cancel): ", current_source)
      return render_all if source_input.nil?
      unless source_input.empty?
        new_rules << { 'field' => 'source', 'op' => 'like', 'value' => source_input }
      end

      # 7. Read status
      current_read = current_vals['read_=']
      default_read = current_read == false ? 'y' : (current_read == true ? 'n' : '')
      read_input = bottom_ask("Unread only? (y/n/Enter for all, ESC cancel): ", default_read)
      return render_all if read_input.nil?
      if read_input.downcase == 'y'
        new_rules << { 'field' => 'read', 'op' => '=', 'value' => false }
      elsif read_input.downcase == 'n'
        new_rules << { 'field' => 'read', 'op' => '=', 'value' => true }
      end

      # Build filters hash with rules
      filters = { 'rules' => new_rules }

      # Save the view
      view_config = {
        name: view_name,
        key_binding: view_key,
        filters: filters,
        sort_order: 'timestamp DESC'
      }
      # If updating existing view, include its id
      view_config[:id] = existing_view[:id] if existing_view[:id]

      @db.save_view(view_config)

      # Update local cache
      @views[view_key] = {
        id: view_config[:id] || @db.db.last_insert_row_id,
        name: view_name,
        filters: filters,
        sort_order: 'timestamp DESC',
        key_binding: view_key
      }

      # Apply the new filters immediately
      @current_view = view_key
      apply_view_filters(@views[view_key])
      @index = 0

      @panes[:bottom].text = " View #{view_key} configured!".fg(156)
      @panes[:bottom].refresh
      sleep(1)

      render_all
    end
    
    # Check for new mail — called on getchr timeout (every 2s idle)
    # Syncs each source based on its poll_interval setting
    # ========== First-time Onboarding Wizard ==========

    def run_onboarding_wizard
      rows, cols = IO.console.winsize
      pw = [cols - 10, 70].min
      ph = [rows - 6, 30].min
      px = (cols - pw) / 2
      py = (rows - ph) / 2

      popup = Rcurses::Pane.new(px, py, pw, ph, 252, 0)
      popup.border = true
      popup.scroll = true

      welcome = []
      welcome << ""
      welcome << "  " + "Welcome to Heathrow!".b.fg(226)
      welcome << "  " + "Where all your messages connect.".fg(245)
      welcome << ""
      welcome << "  " + "\u2500" * [pw - 6, 1].max
      welcome << ""
      welcome << "  No message sources configured yet."
      welcome << "  Let's get you started with your first source."
      welcome << ""
      welcome << "  Available source types:".b.fg(39)
      welcome << ""
      welcome << "  " + "1".fg(226) + " - Maildir (local email, works with offlineimap/mbsync/fetchmail)"
      welcome << "  " + "2".fg(226) + " - RSS/Atom feeds"
      welcome << "  " + "3".fg(226) + " - WeeChat relay (IRC, Slack via WeeChat)"
      welcome << "  " + "4".fg(226) + " - Discord"
      welcome << "  " + "5".fg(226) + " - Telegram"
      welcome << "  " + "6".fg(226) + " - Instagram DMs"
      welcome << "  " + "7".fg(226) + " - Messenger"
      welcome << ""
      welcome << "  " + "s".fg(226) + " - Skip (configure later via 'S' for Sources)"
      welcome << ""
      welcome << "  " + "Pick a number to add your first source.".fg(245)

      popup.text = welcome.join("\n")
      popup.refresh

      loop do
        chr = getchr
        case chr
        when '1'
          popup_add_maildir
          break
        when '2'
          popup_add_rss
          break
        when '3'
          popup_add_weechat
          break
        when '4'..'7'
          set_feedback("Configure this source via 'S' (Sources) after startup", 226, 5)
          break
        when 's', 'S', 'ESC', 'q'
          break
        end
      end

      Rcurses.clear_screen
      setup_display
      create_panes
      render_all
    end

    def popup_add_maildir
      path = bottom_ask("Maildir path: ", File.join(Dir.home, 'Maildir'))
      return unless path && !path.strip.empty?
      path = File.expand_path(path.strip)

      unless Dir.exist?(path)
        set_feedback("Directory not found: #{path}", 196, 4)
        return
      end

      config = { 'maildir_path' => path }
      @db.add_source('Local Maildir', 'maildir', config, ['read', 'send'], true)
      @db.execute("UPDATE sources SET poll_interval = 30 WHERE name = 'Local Maildir'")

      set_feedback("Maildir source added! Syncing...", 156, 3)

      # Do initial sync
      require_relative '../sources/maildir'
      source = @db.get_source_by_name('Local Maildir')
      if source
        instance = Heathrow::Sources::Maildir.new(source)
        @panes[:bottom].text = " Syncing Maildir (this may take a moment for large collections)...".fg(226)
        @panes[:bottom].refresh
        instance.sync_all(@db, source['id'])
        count = @db.db.get_first_value("SELECT COUNT(*) FROM messages WHERE source_id = ?", [source['id']]) rescue 0
        set_feedback("Synced #{count} messages from Maildir", 156, 5)
      end
    end

    def popup_add_rss
      url = bottom_ask("RSS/Atom feed URL: ", '')
      return unless url && !url.strip.empty?
      url = url.strip

      title = bottom_ask("Feed name (Enter for auto): ", '')
      title = nil if title && title.strip.empty?

      config = { 'feeds' => [{ 'url' => url, 'title' => title }] }
      @db.add_source('RSS Feeds', 'rss', config, ['read'], true)
      set_feedback("RSS source added! Add more feeds via 'S' > RSS > 'a'", 156, 5)
    end

    def popup_add_weechat
      host = bottom_ask("WeeChat relay host: ", 'localhost')
      return unless host && !host.strip.empty?
      port = bottom_ask("Relay port: ", '8001')
      password = bottom_ask("Relay password: ", '')

      config = {
        'host' => host.strip,
        'port' => port.strip.to_i,
        'password' => password
      }
      @db.add_source('WeeChat', 'weechat', config, ['read', 'send'], true)
      set_feedback("WeeChat source added!", 156, 5)
    end

    def check_new_mail
      now = Time.now
      @last_sync_check ||= Time.at(0)
      return if (now - @last_sync_check) < 5
      @last_sync_check = now

      @source_last_sync ||= {}

      Thread.new do
        thread_db = Heathrow::Database.new
        changed = false

        # Maildir sync: current folder every 5s (skip if no folder context)
        maildir_interval = 5
        if !@source_last_sync['maildir'] || (now - @source_last_sync['maildir']) >= maildir_interval
          folder = current_view_folder
          if folder
            changed = sync_maildir(folder: folder, db: thread_db)
          end
          @source_last_sync['maildir'] = now
        end

        # Other sources based on their poll_interval
        sources = thread_db.get_sources
        sources.each do |source|
          stype = source['plugin_type']
          next if stype == 'maildir'
          interval = (source['poll_interval'] || 900).to_i
          next if interval <= 0

          key = "#{stype}_#{source['id']}"
          next if @source_last_sync[key] && (now - @source_last_sync[key]) < interval

          src_changed = case stype
          when 'rss'       then sync_rss(db: thread_db)
          when 'web'       then sync_webwatch(db: thread_db)
          when 'messenger' then sync_messenger(db: thread_db)
          when 'instagram' then sync_instagram(db: thread_db)
          when 'weechat'   then sync_weechat(db: thread_db)
          end
          @source_last_sync[key] = now
          changed = true if src_changed
        end

        thread_db.close rescue nil
        @pending_view_refresh = true if changed
      rescue => e
        File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "check_new_mail error: #{e.message}" }
      end
    rescue => e
      # Silent fail
    end

    # Extract the folder name for the current view (for targeted sync)
    def current_view_folder
      # If browsing a specific folder, sync that
      return @current_folder if @current_folder

      # For custom views with a folder filter, sync that folder
      view = @views[@current_view]
      if view && view[:filters].is_a?(Hash) && view[:filters]['rules'].is_a?(Array)
        folder_rule = view[:filters]['rules'].find { |r| r['field'] == 'folder' && r['op'] == 'like' }
        return folder_rule['value'] if folder_rule
      end

      # For All/New/mixed views: sync the few most recent folders
      if @filtered_messages && !@filtered_messages.empty?
        folders = @filtered_messages.first(50).map { |m| m['folder'] }.compact.uniq.first(5)
        return folders unless folders.empty?
      end

      nil  # No specific folder known
    end

    def refresh_messages
      case @current_view
      when 'A'
        show_all_messages
      when 'N'
        show_new_messages
      when 'S'
        # Don't refresh sources - they're static
        return
      else
        switch_to_view(@current_view)
      end
    end
    
    def refresh_current_view
      view = @views[@current_view]
      source_type = nil
      if view && view[:filters] && view[:filters]['rules'].is_a?(Array)
        rule = view[:filters]['rules'].find { |r| r['field'] == 'source_type' && r['op'] == '=' }
        source_type = rule['value'] if rule
      end
      folder = current_view_folder

      set_feedback("Syncing #{source_type || 'view'}...", 226, 30)
      @needs_redraw = true

      Thread.new do
        thread_db = Heathrow::Database.new
        case source_type
        when 'maildir'   then sync_maildir(folder: folder, db: thread_db)
        when 'rss'       then sync_rss(db: thread_db)
        when 'web'       then sync_webwatch(db: thread_db)
        when 'messenger' then sync_messenger(db: thread_db)
        when 'instagram' then sync_instagram(db: thread_db)
        when 'weechat'   then sync_weechat(db: thread_db)
        else
          sync_maildir(folder: folder, db: thread_db)
          sync_rss(db: thread_db)
          sync_webwatch(db: thread_db)
          sync_messenger(db: thread_db)
          sync_instagram(db: thread_db)
          sync_weechat(db: thread_db)
        end
        thread_db.close rescue nil
        @pending_view_refresh = true
        set_feedback("Synced", 46, 2)
      rescue => e
        set_feedback("Refresh error: #{e.message}", 196, 3)
      end
    end

    def refresh_all
      set_feedback("Syncing all sources...", 226, 30)
      @needs_redraw = true

      Thread.new do
        thread_db = Heathrow::Database.new
        sync_maildir(folder: current_view_folder, db: thread_db)
        sync_rss(db: thread_db)
        sync_webwatch(db: thread_db)
        sync_messenger(db: thread_db)
        sync_instagram(db: thread_db)
        sync_weechat(db: thread_db)
        thread_db.close rescue nil
        @pending_view_refresh = true
        set_feedback("Synced all", 46, 2)
      rescue => e
        set_feedback("Refresh error: #{e.message}", 196, 3)
      end
    end

    def redraw_panes
      require 'io/console'
      @h, @w = IO.console.winsize
      Rcurses.clear_screen
      create_panes
      render_all
    end
    
    def load_views
      # Seed views from heathrowrc (INSERT OR IGNORE, won't overwrite user edits)
      @config.custom_views.each do |cv|
        now = Time.now.to_i
        filters_json = cv[:filters].is_a?(String) ? cv[:filters] : cv[:filters].to_json
        @db.execute(
          "INSERT OR IGNORE INTO views (name, key_binding, filters, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
          [cv[:name], cv[:key], filters_json, cv[:sort_order], now, now]
        )
      end

      # Load all views from database, keyed by key_binding string
      db_views = @db.get_all_views
      db_views.each do |view|
        key = view['key_binding'] || view['id'].to_s
        @views[key] = {
          id: view['id'],
          name: view['name'],
          filters: view['filters'],
          sort_order: view['sort_order'],
          key_binding: key
        }
      end
    end
    
    def quit
      @config.save
      @running = false
    end
    
    # Get identity for the current message based on its Maildir folder
    def current_identity(msg = nil)
      msg ||= current_message
      return nil unless msg
      metadata = msg['metadata']
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      folder = metadata.is_a?(Hash) ? metadata['maildir_folder'] : nil
      folder ||= @current_folder  # Use browsing folder as fallback
      Config.identity_for_folder(folder)
    end

    # Colorize email content with mutt-style quote levels and signature dimming.
    # Detects both ">" prefix quoting and indentation-based quoting (from HTML
    # emails rendered via w3m, where blockquotes become indented text).
    def colorize_email_content(content)
      quote_colors = [theme[:quote1] || 114, theme[:quote2] || 180,
                      theme[:quote3] || 139, theme[:quote4] || 109]
      sig_color = theme[:sig] || 5       # magenta (vim PreProc)
      link_color = theme[:link] || 4     # blue (vim String)
      email_color = theme[:email] || 5   # magenta (vim Special)
      in_signature = false
      indent_quote_level = 0  # tracks nesting from "wrote:" attribution lines

      lines = content.lines
      result = []
      lines.each_with_index do |line, i|
        stripped = line.rstrip
        # Detect signature delimiter (RFC 3676: "-- " on its own line)
        if stripped == '-- ' || stripped == '--'
          in_signature = true
          indent_quote_level = 0
          result << colorize_links(stripped, sig_color, link_color)
        elsif in_signature
          result << colorize_links(stripped, sig_color, link_color)
        elsif stripped =~ /^(>{1,})\s?/
          level = $1.length
          color = quote_colors[[level - 1, quote_colors.length - 1].min]
          result << colorize_links(stripped, color, link_color)
        else
          # Detect attribution lines (start of indented quote block)
          # Matches: "wrote:", "skrev ...:", "schrieb ...:", "a écrit :", or "date ... <email>:"
          if stripped =~ /\b(wrote|skrev|schrieb|geschreven|scrisse|escribi[oó]|a\s+[eé]crit)\b.*:\s*$/ ||
             stripped =~ /\d\d[:\.]\d\d\s.*<[^>]+>:\s*$/
            indent_quote_level += 1
            color = quote_colors[[indent_quote_level - 1, quote_colors.length - 1].min]
            result << colorize_links(stripped, color, link_color)
          elsif indent_quote_level > 0 && stripped =~ /^\s{2,}/
            # Indented line inside a quote block
            color = quote_colors[[indent_quote_level - 1, quote_colors.length - 1].min]
            result << colorize_links(stripped, color, link_color)
          else
            # Non-indented line resets indent quoting
            indent_quote_level = 0 if indent_quote_level > 0 && !stripped.empty?
            result << colorize_links(stripped, nil, link_color)
          end
        end
      end
      result.join("\n")
    end

    # Convert HTML to readable text via w3m
    # Initialize Termpix for inline image display
    def init_termpix
      return @termpix if defined?(@termpix)
      begin
        require 'termpix'
        @termpix = Termpix::Display.new
        @termpix = nil unless @termpix.supported?
      rescue LoadError
        @termpix = nil
      end
      @termpix
    end

    # Extract image URLs from HTML content
    # Extract image URLs from message attachments (chat sources)
    def image_urls_from_attachments(msg)
      raw = msg['attachments']
      return [] unless raw
      atts = raw.is_a?(String) ? (JSON.parse(raw) rescue []) : raw
      return [] unless atts.is_a?(Array)

      atts.filter_map do |att|
        url = att['url'] || att['proxy_url']
        next unless url && url.start_with?('http')
        ctype = (att['content_type'] || '').downcase
        # Include if content_type is image, or filename looks like an image
        fname = (att['filename'] || att['name'] || '').downcase
        if ctype.start_with?('image') || fname =~ /\.(jpe?g|png|gif|webp|bmp|svg)$/i
          url
        end
      end
    end

    def extract_image_urls(html)
      return [] unless html
      # Extract full img tags, then filter by attributes
      tags = html.scan(/<img[^>]*>/i)
      urls = []
      tags.each do |tag|
        src = tag[/src=["']([^"']+)["']/i, 1]
        next unless src
        # Skip by URL patterns (tracking, icons, social media badges)
        next if src =~ /track|pixel|spacer|beacon|\.gif$|icon|logo|badge|button|social|facebook|linkedin|twitter|instagram/i
        # Skip by HTML dimensions (tracking pixels and small icons)
        w = tag[/width=["']?(\d+)/i, 1]&.to_i
        h = tag[/height=["']?(\d+)/i, 1]&.to_i
        next if w && w <= 40
        next if h && h <= 40
        urls << src
      end
      urls
    end

    # Download image to cache, return local path
    def cached_image(url)
      cache_dir = File.join(Dir.home, '.heathrow', 'image_cache')
      FileUtils.mkdir_p(cache_dir)

      # Use URL hash as filename
      ext = File.extname(URI.parse(url).path)[0..4] rescue '.img'
      ext = '.jpg' if ext.empty?
      cache_path = File.join(cache_dir, Digest::MD5.hexdigest(url) + ext)

      return cache_path if File.exist?(cache_path) && File.size(cache_path) > 100

      # Download with timeout
      require 'open-uri'
      Timeout.timeout(5) do
        URI.open(url, 'rb', 'User-Agent' => 'Heathrow/1.0') do |remote|
          File.binwrite(cache_path, remote.read)
        end
      end
      cache_path
    rescue => e
      nil
    end

    # Toggle image display in right pane (I key)
    def toggle_inline_image
      if @showing_image
        clear_inline_image
        render_message_content
        return
      end

      return unless init_termpix

      msg = current_message
      return unless msg
      msg = ensure_full_message(msg)

      http_urls = []

      # 1. Check attachments for image URLs (Discord, Messenger, Instagram, etc.)
      att_urls = image_urls_from_attachments(msg)
      http_urls.concat(att_urls)

      # 2. Check HTML content for <img> tags (email, RSS)
      html = msg['html_content']
      if (!html || html.strip.empty?) && msg['content'] =~ /\A\s*<(!DOCTYPE|html|head|body)\b/i
        html = msg['content']
      end
      if html && !html.strip.empty?
        html_urls = extract_image_urls(html).select { |u| u.start_with?('http') }
        http_urls.concat(html_urls)
      end

      http_urls.uniq!

      if http_urls.empty?
        set_feedback("No images found", 245, 2)
        return
      end

      set_feedback("Loading #{http_urls.size > 1 ? "#{http_urls.size} images" : 'image'}...", 226, 2)
      image_paths = []
      http_urls.first(10).each do |url|
        path = cached_image(url)
        image_paths << path if path && File.exist?(path) && File.size(path) > 100
      end

      if image_paths.empty?
        set_feedback("Download failed for #{http_urls.size} image(s)", 196, 2)
        return
      end

      # Clear right pane and show images
      n = image_paths.size
      label = n == 1 ? "1 image" : "#{n} images"
      @panes[:right].text = " [#{label}]  Press ESC to return".fg(245)
      @panes[:right].full_refresh  # Full refresh to clear image area

      pane_w = @panes[:right].w - 2
      pane_h = @panes[:right].h - 2
      img_x = @panes[:right].x
      base_y = @termpix.protocol == :kitty ? @panes[:right].y + 1 : @panes[:right].y

      # Composite multiple images into a grid tile so they use the full pane area
      display_path = if image_paths.size == 1
        image_paths.first
      else
        composite = File.join(Dir.home, '.heathrow', 'image_cache', 'composite.png')
        escaped = image_paths.map { |p| Shellwords.escape(p) }
        # Calculate grid columns: sqrt gives a balanced grid
        cols = Math.sqrt(image_paths.size).ceil
        system("montage #{escaped.join(' ')} -geometry +2+2 -tile #{cols}x -background none #{Shellwords.escape(composite)} 2>/dev/null")
        File.exist?(composite) ? composite : image_paths.first
      end

      @termpix.show(display_path,
        x: img_x,
        y: base_y,
        max_width: pane_w,
        max_height: pane_h)
      @showing_image = true
      @panes[:right].content_update = false
    rescue => e
      set_feedback("Image error: #{e.message}", 196, 2)
    end

    def clear_inline_image
      return unless @showing_image && @termpix
      @termpix.clear(
        x: @panes[:right].x,
        y: @panes[:right].y,
        width: @panes[:right].w - 1,
        height: @panes[:right].h - 1,
        term_width: @w,
        term_height: @h)
      @showing_image = false
    rescue
      @showing_image = false
    end

    def html_to_text(html, width = 80)
      return nil unless html && !html.strip.empty?
      # Override charset to UTF-8 (DB content is always UTF-8, but HTML may declare Windows-1252 etc.)
      fixed = html.gsub(/charset\s*=\s*"?[^";\s>]+/i, 'charset="UTF-8"')
      text = IO.popen(['w3m', '-T', 'text/html', '-dump', '-cols', width.to_s], 'r+') do |io|
        io.write(fixed)
        io.close_write
        io.read
      end
      return nil unless text

      # Extract links from HTML that w3m hides (URL differs from link text)
      links = []
      html.scan(/<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/im) do |url, link_text|
        clean_text = link_text.gsub(/<[^>]+>/, '').strip
        next if url.start_with?('mailto:') || url.start_with?('#') || url.start_with?('cid:')
        next if clean_text.empty?
        next if clean_text == url || text.include?(url)
        links << [clean_text, url]
      end
      links.uniq! { |_, url| url }

      if links.any?
        text += "\n\nLinks:\n"
        links.each_with_index do |(label, url), i|
          text += "  [#{i + 1}] #{label}: #{url}\n"
        end
      end

      text
    rescue => e
      nil  # Fall back to plain text content
    end

    # Format attachment list for display
    # Parse and format calendar events from ICS attachments
    def format_calendar_event(attachments)
      attachments = [] unless attachments.is_a?(Array)
      # Find ICS data from attachments or inline MIME parts
      ics_data = nil
      begin
        require 'mail'

        # First check attachments array
        ics_att = attachments.is_a?(Array) && attachments.find do |att|
          ct = (att['content_type'] || '').downcase
          name = (att['name'] || att['filename'] || '').downcase
          ct.include?('calendar') || ct.include?('ics') || name.end_with?('.ics')
        end

        # Get the maildir file path (from attachment or message metadata)
        file = ics_att['source_file'] if ics_att
        file ||= @_current_render_msg_file  # Set by render_message_content
        return nil unless file && File.exist?(file)

        # Parse MIME parts for calendar data
        mail = Mail.read(file)
        if mail.multipart?
          mail.parts.each do |part|
            ct = (part.content_type || '').downcase
            if ct.include?('calendar') || ct.include?('ics')
              ics_data = part.decoded
              break
            end
            if part.multipart?
              part.parts.each do |sub|
                sct = (sub.content_type || '').downcase
                if sct.include?('calendar') || sct.include?('ics')
                  ics_data = sub.decoded
                  break
                end
              end
              break if ics_data
            end
          end
        end
        ics_data ||= File.read(file) if file.end_with?('.ics')
        return nil unless ics_data && ics_data.include?('BEGIN:')

        # Use VcalView parser
        # Use basic inline ICS parser
        event = parse_ics_basic(ics_data)
        return nil unless event

        # Format the event for display
        lines = []
        lines << ("─" * 50).fg(238)
        lines << "Calendar Event".b.fg(226)
        lines << ""
        lines << "WHAT:  #{event[:summary]}".fg(156) if event[:summary]
        if event[:dates]
          when_str = event[:dates]
          when_str += " (#{event[:weekday]})" if event[:weekday]
          when_str += ", #{event[:times]}" if event[:times]
          lines << "WHEN:  #{when_str}".fg(39)
        end
        lines << "WHERE: #{event[:location]}".fg(45) if event[:location] && !event[:location].to_s.empty?
        lines << "RECUR: #{event[:recurrence]}".fg(180) if event[:recurrence]
        lines << "STATUS: #{event[:status]}".fg(245) if event[:status]
        lines << ""
        lines << "ORGANIZER: #{event[:organizer]}".fg(2) if event[:organizer]
        if event[:participants] && !event[:participants].to_s.strip.empty?
          lines << "PARTICIPANTS:".fg(2)
          lines << event[:participants].fg(245)
        end
        # Skip description (email body already shows it, and ICS descriptions
        # often contain raw URLs that can overflow the pane)
        lines << ("─" * 50).fg(238)
        lines.join("\n")
      rescue => e
        nil  # Don't crash on calendar parse errors
      end
    end

    # Basic ICS parsing fallback (when VcalView is not available)
    def parse_ics_basic(ics)
      # Extract only the VEVENT section (ignore VTIMEZONE which has dummy dates)
      vevent = ics[/BEGIN:VEVENT(.*?)END:VEVENT/m, 1]
      return nil unless vevent

      # Unfold continuation lines (RFC 5545: lines starting with space are continuations)
      vevent = vevent.gsub(/\r?\n[ \t]/, '')

      event = {}

      # SUMMARY (strip LANGUAGE= and other params before the colon-value)
      if vevent =~ /^SUMMARY[^:]*:(.*)$/i
        event[:summary] = $1.strip
      end

      # DTSTART with TZID
      if vevent =~ /^DTSTART;TZID=[^:]*:(\d{8})T?(\d{4,6})?/i
        d = $1; t = $2
        event[:dates] = "#{d[0,4]}-#{d[4,2]}-#{d[6,2]}"
        event[:times] = t ? "#{t[0,2]}:#{t[2,2]}" : "All day"
        begin
          dobj = Time.parse(event[:dates])
          event[:weekday] = dobj.strftime('%A')
        rescue; end
      elsif vevent =~ /^DTSTART;VALUE=DATE:(\d{8})/i
        d = $1
        event[:dates] = "#{d[0,4]}-#{d[4,2]}-#{d[6,2]}"
        event[:times] = "All day"
      elsif vevent =~ /^DTSTART:(\d{8})T?(\d{4,6})?(Z)?/i
        d = $1; t = $2; utc = $3
        event[:dates] = "#{d[0,4]}-#{d[4,2]}-#{d[6,2]}"
        if t
          # Convert UTC times to local
          if utc
            utc_time = Time.utc(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i, t[0,2].to_i, t[2,2].to_i)
            local = utc_time.localtime
            event[:dates] = local.strftime('%Y-%m-%d')
            event[:times] = local.strftime('%H:%M')
            event[:weekday] = local.strftime('%A')
          else
            event[:times] = "#{t[0,2]}:#{t[2,2]}"
            begin
              event[:weekday] = Time.parse(event[:dates]).strftime('%A')
            rescue; end
          end
        else
          event[:times] = "All day"
        end
      end

      # DTEND
      if vevent =~ /^DTEND;TZID=[^:]*:(\d{8})T?(\d{4,6})?/i
        d = $1; t = $2
        end_date = "#{d[0,4]}-#{d[4,2]}-#{d[6,2]}"
        end_time = t ? "#{t[0,2]}:#{t[2,2]}" : nil
      elsif vevent =~ /^DTEND:(\d{8})T?(\d{4,6})?(Z)?/i
        d = $1; t = $2; utc = $3
        if t && utc
          utc_time = Time.utc(d[0,4].to_i, d[4,2].to_i, d[6,2].to_i, t[0,2].to_i, t[2,2].to_i)
          local = utc_time.localtime
          end_date = local.strftime('%Y-%m-%d')
          end_time = local.strftime('%H:%M')
        else
          end_date = "#{d[0,4]}-#{d[4,2]}-#{d[6,2]}"
          end_time = t ? "#{t[0,2]}:#{t[2,2]}" : nil
        end
        event[:dates] += " - #{end_date}" if end_date && end_date != event[:dates]
        event[:times] += " - #{end_time}" if end_time && end_time != event[:times]
      end

      # LOCATION (strip params)
      if vevent =~ /^LOCATION[^:]*:(.*)$/i
        event[:location] = $1.strip
      end

      # ORGANIZER
      if vevent =~ /^ORGANIZER.*CN=([^;:]+)/i
        event[:organizer] = $1.strip
      elsif vevent =~ /^ORGANIZER.*MAILTO:(.+)$/i
        event[:organizer] = $1.strip
      end

      # ATTENDEES
      attendees = vevent.scan(/^ATTENDEE.*CN=([^;:]+)/i).flatten
      if attendees.any?
        event[:participants] = attendees.map { |a| "   #{a.strip}" }.join("\n")
      end

      # STATUS
      event[:status] = $1.strip.capitalize if vevent =~ /^STATUS:(.*)$/i

      event.empty? ? nil : event
    end

    def format_attachments(attachments)
      return nil unless attachments.is_a?(Array) && !attachments.empty?
      lines = []
      lines << "Attachments:".b.fg(208)
      attachments.each_with_index do |att, i|
        name = att['name'] || att['filename'] || 'unnamed'
        size = att['size'] ? " (#{human_size(att['size'])})" : ''
        ctype = att['content_type']&.split(';')&.first || ''
        lines << "  [#{i + 1}] #{name}#{size}  #{ctype}".fg(250)
      end
      lines << "  Press 'v' to view/save attachments".fg(245)
      lines.join("\n")
    end

    def human_size(bytes)
      return '0 B' unless bytes && bytes > 0
      units = ['B', 'KB', 'MB', 'GB']
      exp = (Math.log(bytes) / Math.log(1024)).to_i
      exp = units.length - 1 if exp >= units.length
      "%.1f %s" % [bytes.to_f / (1024 ** exp), units[exp]]
    end

    # Highlight URLs in a line, applying base_color to non-URL text
    # Truncate a string to fit within a given display width (CJK-aware)
    def truncate_to_width(str, max_width)
      w = 0
      str.each_char.with_index do |c, i|
        cw = Rcurses.display_width(c)
        return str[0...i] if w + cw > max_width
        w += cw
      end
      str
    end

    def colorize_links(line, base_color, link_color)
      url_re = %r{https?://[^\s<>\[\]()]+}
      parts = line.split(url_re, -1)
      urls = line.scan(url_re)
      result = ""
      parts.each_with_index do |part, i|
        result += base_color ? part.fg(base_color) : part
        result += urls[i].u.fg(link_color) if urls[i]
      end
      result
    end

    # Sync DB with Maildir filesystem (like mutt's live sync)
    # folder: sync only one folder, or nil for full sync
    # Run sync in background thread, re-render when done
    # The block (if given) should return new filtered_messages, or nil to re-use apply_view_filters
    def bg_sync(folder: nil, &requery_block)
      # Kill any previous sync thread
      @bg_sync_thread&.kill if @bg_sync_thread&.alive?

      view_at_start = @current_view
      db_path = @db.instance_variable_get(:@db_path)
      @bg_sync_thread = Thread.new do
        begin
          # Use a separate DB connection so we don't block the main thread
          bg_db = Heathrow::Database.new(db_path)
          sync_maildir(folder: folder, db: bg_db)
          sync_weechat(db: bg_db) unless folder
          bg_db.close
          @bg_sync_ready = view_at_start  # Signal: sync done for this view
        rescue => e
          File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "bg_sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
        end
      end
      @bg_requery_block = requery_block
    end

    # Called from render_all — check if background sync finished
    def check_bg_sync
      return unless @bg_sync_ready && @bg_sync_ready == @current_view
      @bg_sync_ready = nil

      old_ids = @filtered_messages.map { |m| m['id'] }

      if @bg_requery_block
        result = @bg_requery_block.call
        if result.is_a?(Array)
          @filtered_messages = result
          sort_messages
        end
        # If block returned nil (e.g. apply_view_filters sets @filtered_messages directly)
        sort_messages
      end
      @bg_requery_block = nil

      new_ids = @filtered_messages.map { |m| m['id'] }

      # Only re-render if data actually changed
      if old_ids != new_ids
        @index = 0 if @index >= @filtered_messages.size
        true  # Signal: needs re-render
      else
        false
      end
    end

    # Returns true if any data changed, false otherwise
    def sync_maildir(folder: nil, db: nil, &block)
      db ||= @db
      source = db.get_sources.find { |s| s['plugin_type'] == 'maildir' }
      return false unless source

      require_relative '../sources/maildir'
      maildir = Heathrow::Sources::Maildir.new(source)

      if folder.is_a?(Array)
        all_folders = maildir.discover_folders
        changed = false
        folder.each do |fname|
          f = all_folders.find { |fd| fd[:name] == fname }
          changed = true if f && maildir.sync_folder(db, source['id'], f[:name], f[:path])
        end
        changed
      elsif folder
        folders = maildir.discover_folders
        f = folders.find { |fd| fd[:name] == folder }
        f ? maildir.sync_folder(db, source['id'], f[:name], f[:path]) : false
      else
        maildir.sync_all(db, source['id'], &block)
      end
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "Maildir sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
    end

    def sync_rss(db: nil)
      db ||= @db
      sources = db.get_sources.select { |s| s['plugin_type'] == 'rss' }
      return false if sources.empty?

      require_relative '../sources/rss'
      total = 0
      sources.each do |source|
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        instance = Heathrow::Sources::RSS.new(source['name'], config, db)
        total += (instance.sync(source['id']) || 0)
      end
      total > 0
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "RSS sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
      false
    end

    def sync_webwatch(db: nil)
      db ||= @db
      sources = db.get_sources.select { |s| s['plugin_type'] == 'web' }
      return false if sources.empty?

      require_relative '../sources/webpage'
      total = 0
      sources.each do |source|
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        instance = Heathrow::Sources::Webpage.new(source['name'], config, db)
        total += (instance.sync(source['id']) || 0)
      end
      total > 0
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "Webwatch sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
      false
    end

    def sync_messenger(db: nil)
      db ||= @db
      sources = db.get_sources.select { |s| s['plugin_type'] == 'messenger' }
      return false if sources.empty?

      require_relative '../sources/messenger'
      total = 0
      sources.each do |source|
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        instance = Heathrow::Sources::Messenger.new(source['name'], config, db)
        total += (instance.sync(source['id']) || 0)
      end
      total > 0
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "Messenger sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
      false
    end

    def sync_instagram(db: nil)
      db ||= @db
      sources = db.get_sources.select { |s| s['plugin_type'] == 'instagram' }
      return false if sources.empty?

      require_relative '../sources/instagram'
      total = 0
      sources.each do |source|
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        instance = Heathrow::Sources::Instagram.new(source['name'], config, db)
        total += (instance.sync(source['id']) || 0)
      end
      total > 0
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "Instagram sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
      false
    end

    def sync_weechat(db: nil)
      db ||= @db
      sources = db.get_sources.select { |s| s['plugin_type'] == 'weechat' }
      return false if sources.empty?

      require_relative '../sources/weechat'
      total = 0
      sources.each do |source|
        config = source['config']
        config = JSON.parse(config) if config.is_a?(String)
        instance = Heathrow::Sources::Weechat.new(source['name'], config, db)
        total += (instance.sync(source['id']) || 0)
      end
      total > 0
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "WeeChat sync error: #{e.message}\n#{e.backtrace.first(3).join("\n")}" }
      false
    end

    # Sync a Maildir flag on disk after DB update
    # flag_char: 'S' for seen, 'F' for flagged, 'T' for trashed
    # add: true to add flag, false to remove
    def sync_maildir_flag(msg, flag_char, add)
      return unless msg
      metadata = msg['metadata']
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      return unless metadata.is_a?(Hash)
      file_path = metadata['maildir_file']
      return unless file_path && File.exist?(file_path)

      require_relative '../sources/maildir'
      new_path = Heathrow::Sources::Maildir.rename_with_flag(file_path, flag_char, add: add)

      # Update the stored file path in metadata and DB
      if new_path != file_path
        metadata['maildir_file'] = new_path
        msg['metadata'] = metadata
        @db.execute("UPDATE messages SET metadata = ? WHERE id = ?", metadata.to_json, msg['id'])
      end
    rescue => e
      # Don't crash on flag sync failures
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "Flag sync error: #{e.message}" } if ENV['DEBUG']
    end

    # Delete the Maildir file from disk (like mutt's purge)
    def delete_maildir_file(msg)
      metadata = msg['metadata']
      metadata = JSON.parse(metadata) if metadata.is_a?(String)
      return unless metadata.is_a?(Hash)
      file_path = metadata['maildir_file']
      return unless file_path && File.exist?(file_path)
      File.delete(file_path)
    rescue => e
      File.open('/tmp/heathrow_debug.log', 'a') { |f| f.puts "Delete file error: #{e.message}" } if ENV['DEBUG']
    end

    def cleanup
      @db.close if @db
      # Clear screen and restore terminal
      Rcurses.clear_screen rescue nil
    end
  end
end