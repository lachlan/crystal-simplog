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

Log.setup_from_env(backend: SimpLog::FileBackend.new)
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
