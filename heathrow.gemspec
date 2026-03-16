require_relative 'lib/heathrow/version'

Gem::Specification.new do |spec|
  spec.name          = 'heathrow'
  spec.version       = Heathrow::VERSION
  spec.authors       = ['Geir Isene', 'Claude Code']
  spec.email         = ['g@isene.com']

  spec.summary       = 'Communication Hub In The Terminal'
  spec.description   = 'A unified TUI application for managing all your communication sources in one place. Brings together emails, WhatsApp, Discord, Reddit, RSS feeds, and more into a single, efficient terminal interface.'
  spec.homepage      = 'https://github.com/isene/heathrow'
  spec.license       = 'Unlicense'

  spec.required_ruby_version = '>= 2.7.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/isene/heathrow'
  spec.metadata['changelog_uri'] = 'https://github.com/isene/heathrow/blob/master/CHANGELOG.md'

  # Specify which files should be added to the gem
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{\A(?:test|spec|features)/})
    end
  end

  spec.bindir        = 'bin'
  spec.executables   = ['heathrow']
  spec.require_paths = ['lib']

  # Runtime dependencies - keep it simple!
  spec.add_runtime_dependency 'rcurses', '>= 5.0'
  spec.add_runtime_dependency 'sqlite3', '>= 1.4'
end