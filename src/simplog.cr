require "compress/gzip"
require "log"

# Provides a file-based `Log::Backend` that supports automatic log
# file rotation, compression, and purging.
#
# Example:
# ```
# require "simplog"
#
# Log.setup_from_env(backend: SimpLog::FileBackend.new)
# Log.info { "Hello World" } # => writes to log file ./log/<executable>.log
# ```
module SimpLog
  # :nodoc:
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}

  # Provides a `Log::Backend` that is backed with a log file that
  # supports automatic rotation, compression, and purging at specified
  # durations
  class FileBackend < ::Log::Backend
    # Datetime pattern used to suffix rotated file names
    DATETIME_FORMAT = "%Y%m%d%H%M%S%3N"
    # Default compress duration: logs will be compress after 1 week
    DEFAULT_COMPRESS_AT = 7.days
    # Default rotation duration: logs will be rotated after 1 day
    DEFAULT_ROTATE_AT = 1.day
    # Default `Log::DispatchMode`
    DEFAULT_DISPATCH_MODE = ::Log::DispatchMode::Async
    # Default file extension used for gzip compressed log files
    DEFAULT_GZIP_EXTENSION = ".gz"

    # File age at which log files will be gzip compressed
    property compress_at : Time::Span = DEFAULT_COMPRESS_AT
    # File age at which log files will be purged, if not set logs will
    # be retained forever by default
    property retention : Time::Span?
    # File age at which the current log file will be rotated
    property rotate_at : Time::Span = DEFAULT_ROTATE_AT
    # When the next log file rotation is scheduled to occur
    getter next_rotation_at : Time

    # Creates a new LogFileBackend, filename should use .log extension for log retention to
    # work correctly and use a directory dedicated to log files
    def initialize(@formatter : ::Log::Formatter = ::Log::ShortFormat)
      initialize(log_filename, formatter)
    end

    # Creates a new LogFileBackend, filename should use .log extension for log retention to
    # work correctly and use a directory dedicated to log files
    def initialize(filename : String, @formatter : ::Log::Formatter = ::Log::ShortFormat)
      parent_dir = Path.new(filename).dirname
      Dir.mkdir(parent_dir) unless File.exists?(parent_dir) && File.directory?(parent_dir)

      # rotate immediately if file already exists
      if File.exists?(filename) && File.info(filename).size > 0
        File.rename filename, rotated_filename(filename)
      end

      initialize(File.new(filename, "a"), formatter)
    end

    # Creates a new FileBackend, filename should use .log extension for log retention to
    # work correctly and use a directory dedicated to log files
    private def initialize(@file : File, @formatter : ::Log::Formatter = ShortFormat)
      super(DEFAULT_DISPATCH_MODE)
      @parent_dir = Path.new(@file.path).normalize.parent
      @lock = Mutex.new
      @next_rotation_at = next_rotation
    end

    # Writes an entry to the log rotating the log file if required
    def write(entry : ::Log::Entry) : Nil
      rotate_log_if_required
      raw_write entry
    end

    # Writes an entry to the current file without log file rotation
    private def raw_write(entry : ::Log::Entry) : Nil
      raw_write entry, @file
    end

    # Writes an entry to the given file without log file rotation
    private def raw_write(entry : ::Log::Entry, file : File) : Nil
      format entry, file
      file.puts
      file.flush
    end

    # Emits the *entry* to the current file.
    # It uses the `#formatter` to convert.
    def format(entry : ::Log::Entry) : Nil
      format entry, @file
    end

    # Emits the *entry* to the given *file*.
    # It uses the `#formatter` to convert.
    private def format(entry : ::Log::Entry, file : File) : Nil
      @formatter.format(entry, file)
    end

    # Sets the age at which the log file will be rotated
    def rotate_at=(rotate_at : Time::Span) : Nil
      @rotate_at = rotate_at
      @next_rotation_at = next_rotation
    end

    # Rotates the current log file if required
    private def rotate_log_if_required : Nil
      @lock.synchronize do
        if Time.local >= @next_rotation_at
          @file = rotate @file
          @next_rotation_at = next_rotation
          spawn process_aged_logs
        end
      end
    end

    # Returns the new filename to use when rotating the given filename
    private def rotated_filename(filename : String) : String
      "#{filename}.#{Time.local.to_s(DATETIME_FORMAT)}"
    end

    # Rotates the given log file
    private def rotate(file : File) : File
      source = file.path
      target = rotated_filename source
      message = "Rotate log file: #{source} --> #{target}"

      begin
        file.rename target
        file = File.new(source, "a")
      rescue ex
        raw_write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex), file
      else
        raw_write Log::Entry.new("LOG", Log::Severity::Info, message, Log.context.metadata, nil), file
      end
      file
    end

    # Compresses log files older than specified compression duration,
    # and deletes any log files (compressed or otherwise) older than
    # specified retention duration
    private def process_aged_logs : Nil
      @lock.synchronize do
        # currently need to use a Path object with Dir, because it
        # doesn't handle strings with backslashes on Windows correctly
        # but works fine with Path objects
        # TODO: investigate this issue further in Crystal source
        Dir[Path.new(@parent_dir, "*.log.*")].each do |file|
          info = File.info(file)
          unless info.directory?
            file_age = Time.local - info.modification_time
            if (retention = @retention) && file_age >= retention
              message = "Purge aged log file: #{file}"
              begin
                File.delete file
              rescue ex
                raw_write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex)
              else
                raw_write Log::Entry.new("LOG", Log::Severity::Info, message, Log.context.metadata, nil)
              end
            elsif (compress_at = @compress_at) && file_age >= compress_at && !file.ends_with?(DEFAULT_GZIP_EXTENSION)
              target = "#{file}#{DEFAULT_GZIP_EXTENSION}"
              message = "Compress aged log file: #{file} --> #{target}"
              begin
                compress(file, target) do |source, _|
                  File.delete source
                end
              rescue ex
                raw_write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex)
              else
                raw_write Log::Entry.new("LOG", Log::Severity::Info, message, Log.context.metadata, nil)
              end
            end
          end
        end
      end
    end

    # Compresses the contents of the source file writing the results
    # to the target file
    private def compress(source : String, target : String) : Nil
      if File.exists?(source) && !File.directory?(source) && !File.exists?(target)
        modification_time = File.info(source).modification_time
        File.open(source, "r") do |input|
          File.open(target, "w") do |output|
            Compress::Gzip::Writer.open(output) do |compressed_output|
              IO.copy(input, compressed_output)
            end
            # set the source file's modfication time on the target file
            output.utime modification_time, modification_time
          end
        end
        yield source, target
      end
    end

    # Returns datetime for when the next log rotation should occur
    private def next_rotation : Time
      next_rotation_time = Time.local + @rotate_at
      next_rotation_time = next_rotation_time.at_beginning_of_day if @rotate_at.days > 0
      next_rotation_time
    end

    # Returns the current executable's file name
    private def executable_filename : String
      if executable_path = ::Process.executable_path
        File.basename executable_path
      else
        "unknown"
      end
    end

    # Returns the base path to the current executable
    private def base_path : String
      if executable_path = ::Process.executable_path
        File.dirname executable_path
      else
        "./bin/"
      end
    end

    # Returns the log path relative to the current executable
    private def log_path : String
      File.join base_path, "..", "log"
    end

    # Returns the default log filename and path used if not specified
    private def log_filename : String
      File.join log_path, "#{executable_filename.split(".").shift? || executable_filename}.log"
    end
  end
end
