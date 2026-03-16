require 'rss'
require 'time'
require 'digest'
require 'shellwords'
require_relative 'base'

module Heathrow
  module Sources
    class RSS < Base
      def initialize(name, config, db)
        super
        # feeds can be simple URLs or hashes with {url:, title:, tags:}
        @feeds = config['feeds'] || []
      end

      # Sync all feeds into the database. Called from application.rb on refresh.
      def sync(source_id)
        count = 0
        changed = false
        @feeds.each do |feed_entry|
          url, title, tags = parse_feed_entry(feed_entry)
          begin
            n = sync_feed(source_id, url, title, tags)
            count += n
            if feed_entry.is_a?(Hash)
              feed_entry['last_status'] = 'ok'
              feed_entry['last_sync'] = Time.now.to_i
              changed = true
            end
          rescue => e
            STDERR.puts "RSS error #{url}: #{e.message}" if ENV['DEBUG']
            if feed_entry.is_a?(Hash)
              feed_entry['last_status'] = "error: #{e.message}"[0..120]
              feed_entry['last_sync'] = Time.now.to_i
              changed = true
            end
          end
        end
        if changed
          @config['feeds'] = @feeds
          save_config
        end
        count
      end

      # Legacy interface for source_manager
      def fetch
        return [] unless enabled?
        source = @db.get_source_by_name(@name)
        return [] unless source
        sync(source['id'])
        update_last_fetch
        []
      end

      def add_feed(url, title: nil, tags: [])
        entry = { 'url' => url, 'title' => title, 'tags' => tags }
        @feeds << entry unless @feeds.any? { |f| feed_url(f) == url }
        @config['feeds'] = @feeds
        save_config
      end

      def remove_feed(url)
        @feeds.reject! { |f| feed_url(f) == url }
        @config['feeds'] = @feeds
        save_config
      end

      def list_feeds
        @feeds.map { |f| { url: feed_url(f), title: feed_title(f), tags: feed_tags(f) } }
      end

      def test_connection(&progress)
        ok = 0
        fail_names = []
        fail_details = []
        @feeds.each_with_index do |f, i|
          url = feed_url(f)
          title = feed_title(f) || url
          progress.call("Testing #{i+1}/#{@feeds.size}: #{title}") if progress
          begin
            data = http_get(url)
            if data && !data.empty?
              ok += 1
            else
              fail_names << title
              fail_details << title
            end
          rescue => e
            fail_names << title
            fail_details << "#{title}: #{e.message[0..50]}"
          end
        end
        if fail_names.empty?
          { success: true, message: "All #{ok} feeds OK" }
        else
          { success: false, message: "#{ok}/#{@feeds.size} OK. Failed: #{fail_details.join(', ')}", failed_feeds: fail_names }
        end
      end

      private

      def parse_feed_entry(entry)
        if entry.is_a?(Hash)
          [entry['url'], entry['title'], entry['tags'] || []]
        else
          [entry.to_s, nil, []]
        end
      end

      def feed_url(entry)
        entry.is_a?(Hash) ? entry['url'] : entry.to_s
      end

      def feed_title(entry)
        entry.is_a?(Hash) ? entry['title'] : nil
      end

      def feed_tags(entry)
        entry.is_a?(Hash) ? (entry['tags'] || []) : []
      end

      def sync_feed(source_id, url, custom_title, tags)
        count = 0

        raw = http_get(url)
        raise "fetch failed (no response)" unless raw && !raw.empty?

        feed = ::RSS::Parser.parse(raw, false)
        raise "parse failed (not a valid feed)" unless feed && feed.items

        is_atom = feed.is_a?(::RSS::Atom::Feed)
        feed_title = custom_title || (is_atom ? atom_text(feed.title) : feed.channel&.title) || url

        feed.items.each do |item|
          link = item_link(item, is_atom)
          ext_id = link || item_id(item, is_atom) || Digest::MD5.hexdigest(item_title(item, is_atom) + url)

          title = strip_html(item_title(item, is_atom)).gsub(/\s+/, ' ').strip
          # Keep HTML for rich rendering; also store plain text
          html_content = item_content(item, is_atom)
          plain_content = strip_html(html_content)

          timestamp = extract_timestamp(item)
          author = strip_html(extract_author(item) || '')
          categories = extract_categories(item)

          labels = [feed_title] + tags + categories
          labels.uniq!

          data = {
            source_id: source_id,
            external_id: "rss_#{Digest::MD5.hexdigest(ext_id)}",
            sender: (author.nil? || author.empty?) ? feed_title : author,
            sender_name: (author.nil? || author.empty?) ? feed_title : author,
            recipients: [feed_title],
            subject: title,
            content: plain_content,
            html_content: html_content,
            timestamp: timestamp.to_i,
            received_at: Time.now.to_i,
            read: false,
            starred: false,
            archived: false,
            labels: labels,
            metadata: {
              link: link,
              feed_url: url,
              feed_title: feed_title,
              author: author,
              categories: categories,
              tags: tags
            },
            raw_data: { link: link, feed_title: feed_title, author: author, categories: categories }
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

      def http_get(url, _redirects = 8)
        # Use curl — Ruby's net-http gem has chunked encoding bugs
        result = `curl -sL --max-time 15 --max-redirs 8 -A 'Heathrow/1.0 (RSS Reader)' #{Shellwords.escape(url)} 2>/dev/null`
        $?.success? && !result.empty? ? result : nil
      rescue => e
        STDERR.puts "RSS fetch error #{url}: #{e.message}" if ENV['DEBUG']
        nil
      end

      # Atom/RSS2 normalization helpers
      def atom_text(obj)
        return nil unless obj
        obj.respond_to?(:content) ? obj.content : obj.to_s
      end

      def item_title(item, is_atom)
        if is_atom
          atom_text(item.title) || 'No title'
        else
          item.title || 'No title'
        end
      end

      def item_link(item, is_atom)
        if is_atom
          # Atom links: find rel="alternate" or first link
          if item.respond_to?(:links) && item.links
            alt = item.links.find { |l| l.rel.nil? || l.rel == 'alternate' }
            (alt || item.links.first)&.href
          elsif item.link.respond_to?(:href)
            item.link.href
          else
            item.link.to_s
          end
        else
          item.link
        end
      end

      def item_id(item, is_atom)
        if is_atom
          atom_text(item.id)
        else
          item.guid&.content
        end
      end

      def item_content(item, is_atom)
        if is_atom
          # Prefer content over summary for Atom
          c = atom_text(item.content) if item.respond_to?(:content) && item.content
          c ||= atom_text(item.summary) if item.respond_to?(:summary) && item.summary
          c || ''
        else
          item.description || (item.content_encoded rescue nil) || ''
        end
      end

      def extract_timestamp(item)
        if item.respond_to?(:pubDate) && item.pubDate
          item.pubDate
        elsif item.respond_to?(:dc_date) && item.dc_date
          item.dc_date
        elsif item.respond_to?(:updated) && item.updated
          item.updated.content rescue Time.now
        else
          Time.now
        end
      end

      def extract_author(item)
        if item.respond_to?(:author) && item.author
          # Atom author objects have a .name method; .to_s may give raw XML
          author = if item.author.respond_to?(:name) && item.author.name
                     atom_text(item.author.name)
                   else
                     item.author.to_s
                   end
          return author unless author.nil? || author.empty?
        end
        if item.respond_to?(:dc_creator) && item.dc_creator
          item.dc_creator
        else
          nil
        end
      end

      def extract_categories(item)
        cats = []
        if item.respond_to?(:categories) && item.categories
          cats = item.categories.map { |c| c.content rescue c.to_s }.compact
        end
        cats
      rescue
        []
      end

      def strip_html(text)
        return '' if text.nil? || text.empty?
        text.gsub(/<[^>]*>/, '')
            .gsub(/&nbsp;/, ' ')
            .gsub(/&amp;/, '&')
            .gsub(/&lt;/, '<')
            .gsub(/&gt;/, '>')
            .gsub(/&quot;/, '"')
            .gsub(/&#39;/, "'")
            .gsub(/\n\s*\n\s*\n/, "\n\n")
            .strip
      end
    end
  end
end
