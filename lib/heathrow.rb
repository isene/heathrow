# Main Heathrow module
require 'fileutils'
require 'yaml'
require 'json'
require 'sqlite3'
require 'time'

# Create Heathrow home directory structure
HEATHROW_HOME = File.expand_path('~/.heathrow')
HEATHROW_DB = File.join(HEATHROW_HOME, 'heathrow.db')
HEATHROW_CONFIG = File.join(HEATHROW_HOME, 'config.yml')
HEATHROW_SOURCES = File.join(HEATHROW_HOME, 'sources')
HEATHROW_VIEWS = File.join(HEATHROW_HOME, 'views')
HEATHROW_ATTACHMENTS = File.join(HEATHROW_HOME, 'attachments')
HEATHROW_PLUGINS = File.join(HEATHROW_HOME, 'plugins')
HEATHROW_LOGS = File.join(HEATHROW_HOME, 'logs')

# Create directory structure
[HEATHROW_HOME, HEATHROW_SOURCES, HEATHROW_VIEWS, HEATHROW_ATTACHMENTS, HEATHROW_PLUGINS, HEATHROW_LOGS].each do |dir|
  FileUtils.mkdir_p(dir)
end

# Load all components
require_relative 'heathrow/version'

# Core infrastructure (Phase 0)
require_relative 'heathrow/logger'
require_relative 'heathrow/event_bus'
require_relative 'heathrow/database'
require_relative 'heathrow/config'

# Plugin system
require_relative 'heathrow/plugin/base'
require_relative 'heathrow/plugin_manager'

# Models
require_relative 'heathrow/message'
require_relative 'heathrow/source'

# Sources
require_relative 'heathrow/sources/source_manager'

# Background polling
require_relative 'heathrow/poller'

# UI components
require_relative 'heathrow/ui/application'
require_relative 'heathrow/ui/source_wizard'
require_relative 'heathrow/ui/panes'
require_relative 'heathrow/ui/navigation'
require_relative 'heathrow/ui/views'

module Heathrow
  class Error < StandardError; end
end