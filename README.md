# Logging Framework for D

[![D](https://github.com/funkwerk-mobility/log/actions/workflows/d.yml/badge.svg)](https://github.com/funkwerk-mobility/log/actions/workflows/d.yml)
[![License](https://img.shields.io/badge/license-BSL_1.0-blue.svg)](https://raw.githubusercontent.com/funkwerk-mobility/log/master/LICENSE_1_0.txt)
[![Dub Version](https://img.shields.io/dub/v/gamma.svg)](https://code.dlang.org/packages/log)

This is a composable high-performance logging framework for the
[D Programming Language](http://dlang.org).

Note that "batteries are not included": you will need to adapt the framework to your usecase.

# Usage

Think of `log` less as a logger and more a toolkit to build your own logger,
containing only the parts you need. In exchange, the logger you create will know
exactly what backends are available at runtime, keeping indirection minimal.

# What happened to util.log?

For those who want to keep it simple, the old `util.log` still exists in the `log:util` subconfiguration.
However, you can only use it with the built-in loggers shipped with the library.

## log.Log

The starting point is `log.Log`. `Log` is a template that is instantiated with a list of logging
backends that you want to be available at runtime.

Example: `alias MyLog = Log!(FileLogger!Layout, RollingFileLogger!Layout)` will support file logging with and
without rollover.

Allocate this type with a list of backends that should actually be written to, depending on your
configuration.

The given logger types will be rolled into a sumtype available under `MyLog.Logger`. The constructor takes
an array of this type. Log messages will be written to all the passed loggers.

Example: `auto log = MyLog([MyLog.Logger(new FileLogger!Layout(layout, "log.txt"))])` will create a logging
backend that will write all messages into "log.txt".

A common approach is to define a logger module containing `__gshared MyLog log`.

## Layout

The loggers shipped with `log` are instantiated with a `Layout` parameter.
This is not required, but can be helpful.

To log a message consists of two aspects:

1. Laying out the message, ie. determining which part of the log event info
  (file, line, module, thread, time, message) goes where and in what format
2. Actually writing data to the output stream.

The `Layout` parameter handles the first part. `log.Layout` is provided as an example and starting point.

## LogLevel

`Log` offers five logging methods: `log.trace`, `log.info`, `log.warn`, `log.error`, `log.fatal`.

The method called determines the `LogLevel` value in the event info:

- `trace`: verbose logging, useful only for debugging
- `info`: messages for understanding process behavior in normal operation
- `warn`: issues with the input that prevented normal operation
- `error`: recoverable errors, such as `Exception`
- `fatal`: unrecoverable errors, such as `Error`, that force a process restart

## Loggers

A logger type must implement two methods:

```
void append(string fmt, A...)(in EventInfo eventInfo, in A args);
void append(A...)(in string fmt, in EventInfo eventInfo, in A args);
```

They correspond to `log.info!"%s"(5)` and `log.info("%s", 5)`.

All logger types must `mixin log.Logger.Logger`. This adds the `levels_` bitmask for setting the log level.
It also checks that the `append` methods are implemented correctly.

The constructor must set `levels_` to a log level bitmask, for instance `LogLevel.info.orAbove`.
This will usually be user configurable.

`log` comes with several default loggers.

### FileLogger

Logs to a file, line by line.

### RollingFileLogger

As `FileLogger`, but renames files in a sequence once a size limit is reached. (`log0`, `log1`, etc.)

### RotatingFileLogger

As `FileLogger`, but reopens the output file when `SIGHUP` is sent to the process.
This is intended for use with logrotate.

### SyslogLogger

Writes output to the syslog via the `syslog` function.

# Examples

Start with the [util.log](subpackages/util/src/util/log.d) package.

# Related Projects

- [log.d](https://github.com/jsancio/log.d):
  abandoned D standard library submission, inspired by
  [glog](https://github.com/google/glog)
- [logger](https://github.com/burner/logger):
  D standard library submission
- [dlogg](https://github.com/NCrashed/dlogg):
  logging utilities aimed to be used concurrently under high load
- [vibe.core.log](https://github.com/vibe-d/vibe-core/blob/master/source/vibe/core/log.d):
  the logging facility for [vibe.d](https://vibed.org)
