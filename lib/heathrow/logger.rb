require 'logger'
require 'fileutils'

module Heathrow
  # Logger - Structured logging for Heathrow
  #
  # Usage:
  #   log = Heathrow::Logger.instance
  #   log.info("Application started")
  #   log.error("Failed to connect", error: e, source_id: 123)
  #   log.debug("Processing message", message_id: 456)
  #
  # Log Levels: DEBUG < INFO < WARN < ERROR < FATAL
  #
  class Logger
    LEVELS = {
      debug: ::Logger::DEBUG,
      info: ::Logger::INFO,
      warn: ::Logger::WARN,
      error: ::Logger::ERROR,
      fatal: ::Logger::FATAL
    }.freeze

    attr_reader :logger, :log_file

    def initialize(log_file = nil, level: :info)
      @log_file = log_file || default_log_file
      ensure_log_directory
      @logger = ::Logger.new(@log_file, 'daily')
      @logger.level = LEVELS[level] || ::Logger::INFO
      @logger.formatter = method(:format_message)
    end

    # Log methods
    def debug(message, context = {})
      log(:debug, message, context)
    end

    def info(message, context = {})
      log(:info, message, context)
    end

    def warn(message, context = {})
      log(:warn, message, context)
    end

    def error(message, context = {})
      log(:error, message, context)
    end

    def fatal(message, context = {})
      log(:fatal, message, context)
    end

    # Generic log method
    def log(level, message, context = {})
      return unless @logger

      # Extract error if present
      if context[:error].is_a?(Exception)
        error = context.delete(:error)
        context[:error_class] = error.class.name
        context[:error_message] = error.message
        context[:backtrace] = error.backtrace&.first(5)
      end

      @logger.send(level, message) do
        context.empty? ? message : "#{message} #{context.inspect}"
      end
    end

    # Change log level
    def level=(level)
      @logger.level = LEVELS[level] || ::Logger::INFO
    end

    # Get current log level as symbol
    def level
      LEVELS.key(@logger.level) || :info
    end

    # Close logger
    def close
      @logger.close if @logger
    end

    private

    def default_log_file
      home = Dir.home
      File.join(home, '.heathrow', 'heathrow.log')
    end

    def ensure_log_directory
      dir = File.dirname(@log_file)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
    end

    def format_message(severity, datetime, progname, msg)
      timestamp = datetime.strftime('%Y-%m-%d %H:%M:%S')
      "[#{timestamp}] #{severity.ljust(5)} #{msg}\n"
    end

    # Singleton pattern
    class << self
      def instance
        @instance ||= new
      end

      def reset_instance!
        @instance&.close
        @instance = nil
      end

      # Configure the singleton instance
      def configure(log_file: nil, level: :info)
        reset_instance!
        @instance = new(log_file, level: level)
      end
    end
  end
end
