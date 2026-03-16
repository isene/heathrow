require 'json'
require 'shellwords'

module Heathrow
  class Notmuch
    NOTMUCH_BIN = '/usr/bin/notmuch'

    def self.available?
      File.executable?(NOTMUCH_BIN)
    end

    # Search for messages matching query, returns array of file paths
    def self.search_files(query)
      return [] unless available?
      cmd = "#{NOTMUCH_BIN} search --output=files #{Shellwords.escape(query)}"
      output = `#{cmd} 2>/dev/null`
      output.split("\n").reject(&:empty?)
    end

    # Search for messages, returns structured results
    def self.search(query, limit: 50)
      return [] unless available?
      cmd = "#{NOTMUCH_BIN} search --format=json --limit=#{limit} #{Shellwords.escape(query)}"
      output = `#{cmd} 2>/dev/null`
      JSON.parse(output)
    rescue JSON::ParserError
      []
    end

    # Get thread containing a message
    def self.thread(message_id)
      return [] unless available?
      cmd = "#{NOTMUCH_BIN} search --output=files --format=text #{Shellwords.escape("thread:{id:#{message_id}}")}"
      output = `#{cmd} 2>/dev/null`
      output.split("\n").reject(&:empty?)
    end

    # Count results for a query
    def self.count(query)
      return 0 unless available?
      cmd = "#{NOTMUCH_BIN} count #{Shellwords.escape(query)}"
      `#{cmd} 2>/dev/null`.strip.to_i
    end
  end
end
