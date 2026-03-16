module Heathrow
  class AddressBook
    attr_reader :aliases

    def initialize(path = File.expand_path('~/setup/addressbook'))
      @aliases = {}
      parse(path) if File.exist?(path)
    end

    def parse(path)
      File.readlines(path).each do |line|
        next unless line =~ /^alias\s+(\S+)\s+(.+)/
        @aliases[$1] = $2.strip
      end
    end

    # Search aliases and addresses by query string
    def lookup(query)
      query_down = query.downcase
      @aliases.select { |k, v| k.include?(query_down) || v.downcase.include?(query_down) }
    end

    # Expand an alias name to full address, or return input unchanged
    def expand(name)
      @aliases[name] || name
    end

    # Get all alias names
    def names
      @aliases.keys.sort
    end

    # Get completion candidates for a partial string
    def complete(partial)
      return [] if partial.nil? || partial.empty?
      partial_down = partial.downcase
      @aliases.select { |k, v|
        k.start_with?(partial_down) || v.downcase.include?(partial_down)
      }.map { |k, v| "#{k} → #{v}" }
    end
  end
end
