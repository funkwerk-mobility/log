//          Copyright Mario Kröplin 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module util.log;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.format;
import std.range;
import std.stdio;
import std.string;
import std.traits;

/// Defines the importance of a log message.
enum LogLevel
{
    /// detailed tracing
    trace = 1,
    /// useful information
    info = 2,
    /// potential problem
    warn = 4,
    /// recoverable _error
    error = 8,
    /// _fatal failure
    fatal = 16,
}

/// Returns a bit set containing the level and all levels above.
@safe
uint orAbove(LogLevel level) pure
{
    return [EnumMembers!LogLevel].find(level).reduce!"a | b";
}

///
unittest
{
    with (LogLevel)
    {
        assert(trace.orAbove == (trace | info | warn | error | fatal));
        assert(fatal.orAbove == fatal);
    }
}

/// Returns a bit set containing the level and all levels below.
@safe
uint orBelow(LogLevel level) pure
{
    return [EnumMembers!LogLevel].retro.find(level).reduce!"a | b";
}

///
unittest
{
    with (LogLevel)
    {
        assert(trace.orBelow == trace);
        assert(fatal.orBelow == (trace | info | warn | error | fatal));
    }
}

@safe
bool disabled(LogLevel level) pure
{
    uint levels = 0;

    with (LogLevel)
    {
        version (DisableTrace)
            levels |= trace;
        version (DisableInfo)
            levels |= info;
        version (DisableWarn)
            levels |= warn;
        version (DisableError)
            levels |= error;
        version (DisableFatal)
            levels |= fatal;
    }
    return (level & levels) != 0;
}

struct Log
{
    private Logger[] loggers;

    private uint levels;

    this(Logger[] loggers ...)
    in
    {
        assert(loggers.all!"a !is null");
    }
    body
    {
        this.loggers = loggers.dup;
        levels = reduce!((a, b) => a | b.levels)(0, this.loggers);
    }

    alias trace = append!(LogLevel.trace);
    alias info = append!(LogLevel.info);
    alias warn = append!(LogLevel.warn);
    alias error = append!(LogLevel.error);
    alias fatal = append!(LogLevel.fatal);

    template append(LogLevel level)
    {
        void append(string file = __FILE__, size_t line = __LINE__, Char, A...)(in Char[] fmt, lazy A args)
        {
            static if (!level.disabled)
                if (level & levels)
                    _append(level, file, line, format(fmt, args));
        }

        void append(string file = __FILE__, size_t line = __LINE__, A)(lazy A arg)
        {
            static if (!level.disabled)
                if (level & levels)
                    _append(level, file, line, arg.to!string);
        }
    }

    private void _append(LogLevel level, string file, size_t line, string message)
    {
        LogEvent event;

        event.time = Clock.currTime;
        event.level = level;
        event.file = file;
        event.line = line;
        event.message = message;

        foreach (logger; loggers)
            if (level & logger.levels)
                logger.append(event);
    }
}

__gshared Log log;

shared static this()
{
    log = Log(stderrLogger);
}

/// Represents a logging event.
struct LogEvent
{
    /// local _time of the event
    SysTime time;
    /// importance of the event
    LogLevel level;
    /// _file name of the event source
    string file;
    /// _line number of the event source
    size_t line;
    /// supplied _message
    string message;
}

auto fileLogger(alias Layout = layout)
    (string name, uint levels = LogLevel.info.orAbove)
{
    return new FileLogger!Layout(name, levels);
}

auto stderrLogger(alias Layout = layout)
    (uint levels = LogLevel.warn.orAbove)
{
    return new FileLogger!Layout(stderr, levels);
}

auto stdoutLogger(alias Layout = layout)
    (uint levels = LogLevel.info.orAbove)
{
    return new FileLogger!Layout(stdout, levels);
}

auto rollingFileLogger(alias Layout = layout)
    (string name, size_t count, size_t size, uint levels = LogLevel.info.orAbove)
{
    return new RollingFileLogger!Layout(name ~ count.archiveFiles(name), size, levels);
}

version (Posix)
    auto rotatingFileLogger(alias Layout = layout)
        (string name, uint levels = LogLevel.info.orAbove)
    {
        return new RotatingFileLogger!Layout(name, levels);
    }

version (Posix)
    auto syslogLogger(alias Layout = syslogLayout)
        (string name = null, uint levels = LogLevel.info.orAbove)
    {
        return new SyslogLogger!Layout(name, levels);
    }

/// Returns n file names based on path for archived files.
@safe
string[] archiveFiles(size_t n, string path)
{
    import std.path : extension, stripExtension;
    import std.range : iota;

    string fmt = "-%%0%ss".format(n.to!string.length);

    return n.iota.map!(i => path.stripExtension ~ format(fmt, i + 1) ~ path.extension).array;
}

///
unittest
{
    assert(1.archiveFiles("dir/log.ext") == ["dir/log-1.ext"]);
    assert(10.archiveFiles("log").startsWith("log-01"));
    assert(10.archiveFiles("log").endsWith("log-10"));
}

abstract class Logger
{
    private uint levels;

    this(uint levels)
    {
        this.levels = levels;
    }

    abstract void append(ref LogEvent event);
}

class FileLogger(alias Layout) : Logger
{
    private File file;

    this(string name, uint levels = LogLevel.info.orAbove)
    {
        super(levels);
        file = File(name, "ab");
    }

    this(File file, uint levels = LogLevel.info.orAbove)
    {
        super(levels);
        this.file = file;
    }

    override void append(ref LogEvent event)
    {
        Layout(this.file.lockingTextWriter, event);
        this.file.flush;
    }
}

class RollingFileLogger(alias Layout) : FileLogger!Layout
{
    private string[] names;

    private size_t size;

    this(in string[] names, size_t size, uint levels = LogLevel.info.orAbove)
    in
    {
        assert(!names.empty);
    }
    body
    {
        this.names = names.dup;
        this.size = size;
        super(names[0], levels);
    }

    override void append(ref LogEvent event)
    {
        synchronized (this)
        {
            if (file.size >= size)
            {
                roll;
            }
            super.append(event);
        }
    }

    private void roll()
    {
        import std.file : exists, rename;

        foreach_reverse (i, destination; names[1 .. $])
        {
            string source = names[i];

            if (source.exists)
                rename(source, destination);
        }
        file.open(names[0], "wb");
    }
}

version (Posix)
{
    import core.atomic;
    import core.sys.posix.signal;
    import std.exception;

    private shared uint _count = 0;

    private extern (C) void hangup(int sig)
    {
       _count.atomicOp!"+="(1);
    }

    class RotatingFileLogger(alias Layout) : FileLogger!Layout
    {
        private uint count = 0;

        this(string name, uint levels = LogLevel.info.orAbove)
        {
            super(name, levels);
            setUpSignalHandler;
        }

        private void setUpSignalHandler()
        {
            sigaction_t action;

            action.sa_handler = &hangup;
            sigemptyset(&action.sa_mask);
            action.sa_flags = SA_RESTART;

            enforce(sigaction(SIGHUP, &action, null) == 0);
        }

        override void append(ref LogEvent event)
        {
            uint count = _count.atomicLoad;

            synchronized (this)
            {
                if (this.count != count)
                {
                    reopen;
                    this.count = count;
                }
                super.append(event);
            }
        }

        private void reopen()
        {
            if (!file.name.empty)
            {
                file.close;
                file.open(file.name, "ab");
            }
        }
    }
}


version (Posix)
{
    private extern (C) void openlog(const char *ident, int option, int facility);

    private extern (C) void syslog(int priority, const char *format, ...);

    class SyslogLogger(alias Layout) : Logger
    {
        enum SyslogLevel
        {
            LOG_EMERG   = 0,  // system is unusable
            LOG_ALERT   = 1,  // action must be taken immediately
            LOG_CRIT    = 2,  // critical conditions
            LOG_ERR     = 3,  // error conditions
            LOG_WARNING = 4,  // warning conditions
            LOG_NOTICE  = 5,  // normal but significant condition
            LOG_INFO    = 6,  // informational
            LOG_DEBUG   = 7,  // debug-level messages
        }

        this(string identifier = null, uint levels = LogLevel.info.orAbove)
        {
            enum LOG_USER = 1 << 3;

            super(levels);
            openlog(identifier.empty ? null : identifier.toStringz, 0, LOG_USER);
        }

        override void append(ref LogEvent event)
        {
            auto writer = appender!string;

            Layout(writer, event);
            writer.put('\0');
            syslog(priority(event.level), "%s", writer.data.ptr);
        }

        static SyslogLevel priority(LogLevel level) pure
        {
            final switch (level) with (LogLevel) with (SyslogLevel)
            {
                case trace:
                    return LOG_DEBUG;
                case info:
                    return LOG_INFO;
                case warn:
                    return LOG_WARNING;
                case error:
                    return LOG_ERR;
                case fatal:
                    return LOG_CRIT;
            }
        }
    }

    void syslogLayout(Writer)(Writer writer, ref LogEvent event)
    {
        writer.put(event.message);
    }
}

// Time Thread Category Context layout
void layout(Writer)(Writer writer, ref LogEvent event)
{
    import core.thread : Thread;

    with (event)
    {
        writer.formattedWrite("%s %-5s %s:%s",
                time._toISOExtString, level, file, line);

        if (Thread thread = Thread.getThis)
        {
            string name = thread.name;

            if (!name.empty)
                writer.formattedWrite(" [%s]", name);
        }

        writer.put(' ');
        writer.put(message);
        writer.put('\n');
    }
}

unittest
{
    LogEvent event;

    event.time = SysTime.fromISOExtString("2003-02-01T11:55:00.123456Z");
    event.level = LogLevel.error;
    event.file = "log.d";
    event.line = 42;
    event.message = "don't panic";

    auto writer = appender!string;

    layout(writer, event);
    assert(writer.data == "2003-02-01T11:55:00.123+00:00 error log.d:42 don't panic\n");
}

// SysTime.toISOExtString has no fixed length and no time-zone offset for local time
private string _toISOExtString(SysTime time)
{
    return format("%s.%03d%s",
        (cast (DateTime) time).toISOExtString,
        time.fracSec.msecs,
        time.utcOffset._toISOString);
}

unittest
{
    auto dateTime = DateTime(2003, 2, 1, 12);
    auto fracSec = FracSec.from!"usecs"(123_456);
    auto timeZone =  new immutable SimpleTimeZone(1.hours);
    auto time = SysTime(dateTime, fracSec, timeZone);

    assert(time._toISOExtString == "2003-02-01T12:00:00.123+01:00");
}

// SimpleTimeZone.toISOString is private
@safe
private string _toISOString(Duration offset) pure
{
    uint hours;
    uint minutes;

    abs(offset).split!("hours", "minutes")(hours, minutes);
    return format("%s%02d:%02d", offset.isNegative ? '-' : '+', hours, minutes);
}

unittest
{
    assert(_toISOString(90.minutes) == "+01:30");
    assert(_toISOString(-90.minutes) == "-01:30");
}
