# SimpLog

Crystal language shard which provides a file-based `Log::Backend` that
supports automatic log file rotation, compression, and purging.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     simplog:
       github: lachlan/crystal-simplog
   ```

2. Run `shards install`

## Usage

```crystal
require "simplog"

# create a new log backend
backend = SimpLog::FileBackend.new
# defaults to retaining log files forever, however log purging can be enabled
# by setting the file retention as follows:
backend.retention = 14.days
# defaults to compressing logs older than 7 days, however this can be changed
# as follows:
backend.compress_at = 2.days

# setup logging to use simplog backend
Log.setup_from_env(backend: backend)

# then log messages as required...
Log.info { "Hello World" } # => writes to log file ./log/<executable>.log
```

## Contributing

1. Fork it (<https://github.com/lachlan/crystal-simplog/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Lachlan Dowding](https://github.com/lachlan) - creator and maintainer
