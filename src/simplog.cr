require "compress/gzip"
require "log"

# Provides a file-based `Log::Backend` that supports automatic log file
# rotation, compression, and purging.
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
  class FileBackend < ::Log::IOBackend
    # Datetime pattern used to suffix rotated file names
    DATETIME_FORMAT = "%Y%m%d%H%M%S%3N"
    # Default compress duration: logs will be compress after 1 week
    DEFAULT_COMPRESS_AFTER = 7.days
    # Default rotation duration: logs will be rotated after 1 day
    DEFAULT_ROTATE_AT = 1.day
    # Default `Log::DispatchMode`
    DEFAULT_DISPATCH_MODE = ::Log::DispatchMode::Async
    # Default file extension used for gzip compressed log files
    DEFAULT_GZIP_EXTENSION = ".gz"

    # File age at which log files will be gzip compressed
    property compress_after : Time::Span = DEFAULT_COMPRESS_AFTER
    # File age at which log files will be purged, if not set logs will
    # be retained forever by default
    property delete_after : Time::Span? = nil
    # File age at which the current log file will be rotated
    property rotate_at : Time::Span = DEFAULT_ROTATE_AT
    # When the next log file rotation is scheduled to occur
    getter next_rotation_at : Time

    # Creates a new LogFileBackend with a log filename inferred from the
    # executable filename
    def initialize(*, formatter : ::Log::Formatter = ::Log::ShortFormat, dispatcher : ::Log::Dispatcher::Spec = DEFAULT_DISPATCH_MODE)
      initialize(log_filename, formatter: formatter, dispatcher: dispatcher)
    end

    # Creates a new LogFileBackend, filename should use .log extension for log
    # retention to work correctly and ideally use a dedicated directory
    def initialize(filename : String, *, formatter : ::Log::Formatter = ::Log::ShortFormat, dispatcher : ::Log::Dispatcher::Spec = DEFAULT_DISPATCH_MODE)
      parent_dir = Path.new(filename).dirname
      Dir.mkdir(parent_dir) unless File.exists?(parent_dir) && File.directory?(parent_dir)
      initialize(File.new(filename, "a"), formatter: formatter, dispatcher: dispatcher)
    end

    # Creates a new FileBackend with the given file
    private def initialize(@file : File, *, formatter : ::Log::Formatter = ShortFormat, dispatcher : ::Log::Dispatcher::Spec = DEFAULT_DISPATCH_MODE)
      super(@file, formatter: formatter, dispatcher: dispatcher)
      @parent_dir = Path.new(@file.path).normalize.parent
      @rotate_lock, @housekeeping_lock = Mutex.new, Mutex.new
      # rotate immediately if log file already exists and is not empty
      rotate_log if File.exists?(@file.path) && File.info(@file.path).size > 0
      @next_rotation_at = next_rotation
      spawn rotate_log_at_next_scheduled_datetime
    end

    # Writes an entry to the log file, first rotating the log file if required
    def write(entry : ::Log::Entry) : Nil
      rotate_log_if_required
      write entry, @file
    end

    # Writes the given *entry* to the given *io*
    protected def write(entry : ::Log::Entry, io : IO) : Nil
      format(entry, io)
      io.puts
      io.flush
    end

    # Emits the *entry* to the log file, using the `#formatter` to convert
    def format(entry : ::Log::Entry) : Nil
      format entry, @file
    end

    # Emits the *entry* to the given *io*, using the `#formatter` to convert
    protected def format(entry : ::Log::Entry, io : IO) : Nil
      @formatter.format(entry, io)
    end

    # Closes underlying resources used by this backend including the log file
    def close : Nil
      super
      @rotate_lock.synchronize do
        @file.close
      end
    end

    def filename : String
      @file.path
    end

    # Sets the age at which the log file will be rotated
    def rotate_at=(rotate_at : Time::Span) : Nil
      @rotate_at = rotate_at
      @next_rotation_at = next_rotation
    end

    # Waits until the next rotation scheduled datetime and then rotates the
    # log unless already rotated
    private def rotate_log_at_next_scheduled_datetime : Nil
      wait = @next_rotation_at - Time.local
      sleep(wait) if wait > Time::Span.zero
      rotate_log_if_required
    end

    # Rotates the current log file if required
    private def rotate_log_if_required : Nil
      if Time.local >= @next_rotation_at
        @rotate_lock.synchronize do
          # check again in case another fiber already rotated file
          if Time.local >= @next_rotation_at
            rotate_log
            spawn rotate_log_at_next_scheduled_datetime
          end
        end
      end
    end

    # Rotates the log file, and then processes aged logs in another fiber
    private def rotate_log : Nil
      io = @file = rotate(@file)
      @next_rotation_at = next_rotation
      {% if Fiber.has_constant? "ExecutionContext" %}
        Fiber::ExecutionContext::Isolated.new("SIMPLOG COMPRESS AND PURGE AGED LOGS") do
          process_aged_logs
        end
      {% else %}
        spawn process_aged_logs
      {% end %}
    end

    # Returns the new filename to use when rotating the given filename
    private def rotate_filename(filename : String) : String
      "#{filename}.#{Time.local.to_s(DATETIME_FORMAT)}"
    end

    # Rotates the given file by renaming it with a datetime suffix extension
    # and then returning a newly opened file with the original name
    private def rotate(file : File) : File
      source_file, source_path, renamed, rotated = file, file.path, false, false
      target_path = rotate_filename(source_path)
      message = "Rotate log file: #{source_path} --> #{target_path}"

      begin
        # if rename fails, we will keep logging to the existing open file
        source_file.rename(target_path)
        renamed = true
        # if opening new file fails we will keep logging to the renamed file
        file = File.new(source_path, "a")
        rotated = true
      rescue ex
        begin
          write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex), file
          # if we renamed the existing file but could not open a new one,
          # attempt to rename the existing file back to its original name
          source_file.rename(source_path) if renamed && !rotated
        rescue e
          write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, e), file
        end
      else
        write Log::Entry.new("LOG", Log::Severity::Info, message, Log.context.metadata, nil), file
      ensure
        if renamed && rotated
          begin
            source_file.close
          rescue ex
            write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex), file
          end
        end
      end
      file
    end

    # Compresses log files older than `compress_after` duration, and deletes
    # any log files (compressed or otherwise) older than `delete_after`
    # duration
    private def process_aged_logs : Nil
      @housekeeping_lock.synchronize do
        if (parent_dir = @parent_dir) && (file = @file)
          # currently need to use a Path object with Dir, because it
          # doesn't handle strings with backslashes on Windows correctly
          # but works fine with Path objects
          # TODO: investigate this issue further in Crystal source
          Dir[Path.new(parent_dir, File.basename(file.path) + ".*")].each do |source|
            info = File.info(source)
            unless info.directory?
              file_age = Time.local - info.modification_time
              if (delete_after = @delete_after) && delete_after > Time::Span.zero && file_age > delete_after
                message = "Delete aged log file: #{source}"
                begin
                  File.delete source
                rescue ex
                  write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex)
                else
                  write Log::Entry.new("LOG", Log::Severity::Info, message, Log.context.metadata, nil)
                end
              elsif (compress_after = @compress_after) && compress_after > Time::Span.zero && file_age > compress_after && !source.ends_with?(DEFAULT_GZIP_EXTENSION)
                target = "#{source}#{DEFAULT_GZIP_EXTENSION}"
                message = "Compress aged log file: #{source} (#{File.size(source).humanize_bytes(format: :JEDEC)}) --> #{target}"
                begin
                  elapsed = Time.measure do
                    compress(source, target) do |source, _|
                      File.delete source
                    end
                  end
                  message = "#{message} (#{File.size(target).humanize_bytes(format: :JEDEC)}) in #{elapsed}"
                rescue ex
                  write Log::Entry.new("LOG", Log::Severity::Error, message, Log.context.metadata, ex)
                else
                  write Log::Entry.new("LOG", Log::Severity::Info, message, Log.context.metadata, nil)
                end
              end
            end
          end
        end
      end
    end

    # Compresses the contents of the source file writing the results to the
    # target file
    private def compress(source : String, target : String, &) : Nil
      if File.exists?(source) && !File.directory?(source) && !File.exists?(target)
        modification_time = File.info(source).modification_time
        File.open(source, "r") do |input|
          File.open(target, "w") do |output|
            Compress::Gzip::Writer.open(output) do |compressed_output|
              # preserve source file modification time within compressed file
              compressed_output.header.modification_time = modification_time
              IO.copy(input, compressed_output)
            end
            # preserve source file modification time on the compressed file
            output.utime modification_time, modification_time
          end
        end
        yield source, target
      end
    end

    # Returns datetime for when the next log rotation should occur
    private def next_rotation : Time
      next_rotation_time = Time.local + @rotate_at
      # pin rotation to midnight local time when rotating at 1 or more days
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
      if File.basename(base_path).downcase == "bin"
        File.join base_path, "..", "log"
      else
        base_path
      end
    end

    # Returns the default log filename and path used if not specified
    private def log_filename : String
      File.join log_path, "#{executable_filename.split(".").shift? || executable_filename}.log"
    end
  end
end
