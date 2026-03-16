require 'digest'
require 'shellwords'
require 'json'
require 'time'
require_relative 'base'

module Heathrow
  module Sources
    class Webpage < Base
      def initialize(name, config, db)
        super
        @pages = config['pages'] || []
        @snapshots_dir = File.join(Dir.home, '.heathrow', 'webwatch')
        Dir.mkdir(@snapshots_dir) unless Dir.exist?(@snapshots_dir)
      end

      def sync(source_id)
        count = 0
        @pages.each do |page|
          begin
            count += check_page(source_id, page)
          rescue => e
            STDERR.puts "Webwatch error #{page['url']}: #{e.message}" if ENV['DEBUG']
          end
        end
        count
      end

      def fetch
        return [] unless enabled?
        source = @db.get_source_by_name(@name)
        return [] unless source
        sync(source['id'])
        update_last_fetch
        []
      end

      def add_page(url, title: nil, selector: nil, tags: [])
        entry = { 'url' => url, 'title' => title, 'selector' => selector, 'tags' => tags }
        @pages << entry unless @pages.any? { |p| p['url'] == url }
        @config['pages'] = @pages
        save_config
      end

      def remove_page(url)
        @pages.reject! { |p| p['url'] == url }
        @config['pages'] = @pages
        save_config
      end

      def list_pages
        @pages.map { |p| { url: p['url'], title: p['title'], selector: p['selector'], tags: p['tags'] || [] } }
      end

      private

      def check_page(source_id, page)
        url = page['url']
        title = page['title'] || url
        selector = page['selector']
        tags = page['tags'] || []

        raw = http_get(url)
        return 0 unless raw && !raw.empty?

        # Extract relevant content
        content = if selector && !selector.empty?
                    extract_by_selector(raw, selector)
                  else
                    extract_body(raw)
                  end
        return 0 if content.nil? || content.empty?

        # Normalize whitespace for comparison
        normalized = content.gsub(/\s+/, ' ').strip

        # Compare with stored snapshot
        snapshot_file = File.join(@snapshots_dir, Digest::MD5.hexdigest(url))
        old_content = File.exist?(snapshot_file) ? File.read(snapshot_file) : nil

        # First run — store snapshot, no message
        if old_content.nil?
          File.write(snapshot_file, normalized)
          return 0
        end

        # No change
        return 0 if Digest::MD5.hexdigest(normalized) == Digest::MD5.hexdigest(old_content)

        # Changed! Generate diff and create message
        diff = generate_diff(old_content, normalized)
        File.write(snapshot_file, normalized)

        ext_id = "webwatch_#{Digest::MD5.hexdigest(url + Time.now.to_i.to_s)}"

        data = {
          source_id: source_id,
          external_id: ext_id,
          sender: title,
          sender_name: title,
          recipients: ['Web Watch'],
          subject: "Changed: #{title}",
          content: diff,
          html_content: diff,
          timestamp: Time.now.to_i,
          received_at: Time.now.to_i,
          read: false,
          starred: false,
          archived: false,
          labels: ['Web Watch'] + tags,
          metadata: {
            link: url,
            page_title: title,
            selector: selector,
            tags: tags,
            changed_at: Time.now.iso8601
          },
          raw_data: { link: url, page_title: title }
        }

        begin
          @db.insert_message(data)
          1
        rescue SQLite3::ConstraintException
          0
        end
      end

      def http_get(url)
        result = `curl -sL --max-time 20 --max-redirs 8 -A 'Mozilla/5.0 (X11; Linux x86_64) Heathrow/1.0' #{Shellwords.escape(url)} 2>/dev/null`
        $?.success? && !result.empty? ? result : nil
      rescue => e
        STDERR.puts "Webwatch fetch error #{url}: #{e.message}" if ENV['DEBUG']
        nil
      end

      def extract_body(html)
        # Strip script/style/head tags, then extract text
        html.gsub(/<script[^>]*>.*?<\/script>/mi, '')
            .gsub(/<style[^>]*>.*?<\/style>/mi, '')
            .gsub(/<head[^>]*>.*?<\/head>/mi, '')
            .gsub(/<nav[^>]*>.*?<\/nav>/mi, '')
            .then { |h| strip_html(h) }
      end

      def extract_by_selector(html, selector)
        # Simple CSS selector extraction via regex
        # Supports: #id, .class, tag, tag.class
        pattern = case selector
                  when /^#([\w-]+)$/
                    /<[^>]+id\s*=\s*["']#{Regexp.escape($1)}["'][^>]*>(.*?)<\/[^>]+>/mi
                  when /^\.([\w-]+)$/
                    /<[^>]+class\s*=\s*["'][^"']*\b#{Regexp.escape($1)}\b[^"']*["'][^>]*>(.*?)<\/[^>]+>/mi
                  when /^(\w+)$/
                    /<#{Regexp.escape($1)}[^>]*>(.*?)<\/#{Regexp.escape($1)}>/mi
                  when /^(\w+)\.([\w-]+)$/
                    /<#{Regexp.escape($1)}[^>]+class\s*=\s*["'][^"']*\b#{Regexp.escape($2)}\b[^"']*["'][^>]*>(.*?)<\/#{Regexp.escape($1)}>/mi
                  else
                    nil
                  end

        if pattern
          matches = html.scan(pattern).flatten
          strip_html(matches.join("\n"))
        else
          extract_body(html)
        end
      end

      def generate_diff(old_text, new_text)
        old_lines = old_text.split('. ').map(&:strip).reject(&:empty?)
        new_lines = new_text.split('. ').map(&:strip).reject(&:empty?)

        removed = old_lines - new_lines
        added = new_lines - old_lines

        diff = []
        unless removed.empty?
          diff << "REMOVED:"
          removed.first(15).each { |l| diff << "  - #{l}" }
          diff << "  ... (#{removed.size - 15} more)" if removed.size > 15
        end
        unless added.empty?
          diff << "" unless diff.empty?
          diff << "ADDED:"
          added.first(15).each { |l| diff << "  + #{l}" }
          diff << "  ... (#{added.size - 15} more)" if added.size > 15
        end

        diff.empty? ? "Content changed (details differ in whitespace/structure)" : diff.join("\n")
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
