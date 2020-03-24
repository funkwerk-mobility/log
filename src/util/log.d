//          Copyright Mario Kröplin 2019.
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
import std.typecons;

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

private alias Sink = Appender!(char[]);

struct Log
{
    private Logger[] loggers;

    // preallocate so we can fill it in @nogc fileDescriptors()
    private int[] buffer;

    private uint levels;

    this(Logger[] loggers ...)
    in
    {
        assert(loggers.all!"a !is null");
    }
    body
    {
        this.loggers = loggers.dup;
        buffer = new int[this.loggers.length];
        levels = reduce!((a, b) => a | b.levels)(0, this.loggers);
    }

    public int[] fileDescriptors() @nogc nothrow @safe
    in (buffer.length >= loggers.length)
    {
        size_t length = 0;

        foreach (logger; loggers)
        {
            const fileDescriptor = logger.fileDescriptor;

            if (!fileDescriptor.isNull)
                buffer[length++] = fileDescriptor.get;
        }
        return buffer[0 .. length];
    }

    alias trace = append!(LogLevel.trace);
    alias info = append!(LogLevel.info);
    alias warn = append!(LogLevel.warn);
    alias error = append!(LogLevel.error);
    alias fatal = append!(LogLevel.fatal);

    private struct Fence {}  // argument cannot be provided explicitly

    template append(LogLevel level)
    {
        void append(alias fmt, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, A...)
            (lazy A args)
        if (isSomeString!(typeof(fmt)))
        {
            static if (!level.disabled)
                if (level & levels)
                    _append(level, file, line,
                        (ref Sink sink) { sink.formattedWrite!fmt(args); });
        }

        void append(Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, Char, A...)
            (const Char[] fmt, lazy A args)
        {
            static if (!level.disabled)
                if (level & levels)
                    _append(level, file, line,
                        (ref Sink sink) { sink.formattedWrite(fmt, args); });
        }

        void append(Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, A)
            (lazy A arg)
        {
            static if (!level.disabled)
                if (level & levels)
                    _append(level, file, line,
                        (ref Sink sink) { sink.put(arg.to!string); });
        }
    }

    private void _append(LogLevel level, string file, size_t line,
        scope void delegate(ref Sink sink) putMessage)
    {
        EventInfo eventInfo;

        eventInfo.time = Clock.currTime;
        eventInfo.level = level;
        eventInfo.file = file;
        eventInfo.line = line;

        foreach (logger; loggers)
            if (level & logger.levels)
                logger.append(eventInfo, putMessage);
    }
}

__gshared Log log;

shared static this()
{
    log = Log(stderrLogger);
}

/// Represents information about a logging event.
struct EventInfo
{
    /// local _time of the event
    SysTime time;
    /// importance of the event
    LogLevel level;
    /// _file name of the event source
    string file;
    /// _line number of the event source
    size_t line;
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

    auto length = n.to!string.length;

    return n.iota
        .map!(i => format!"%s-%0*s%s"(path.stripExtension, length, i + 1, path.extension))
        .array;
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

    abstract void append(const ref EventInfo eventInfo,
        scope void delegate(ref Sink sink) putMessage);

    // Exposed so that client code can write data to the log file directly in
    // emergency situations, such as a crash.
    // Returns null if the logger does not use a straightforward file descriptor.
    // The effect of writing to the returned handle should be some form of
    // readable logging.
    Nullable!int fileDescriptor() const @nogc nothrow @safe
    {
        return Nullable!int();
    }
}

struct ReusableAppender
{
    import std.algorithm.mutation : swap;

    // threadlocal output buffer
    private static Appender!(char[]) appender;

    public static Appender!(char[]) use()
    {
        Appender!(char[]) appender;
        ReusableAppender.appender.swap(appender);
        return appender;
    }

    public static void release(Appender!(char[]) appender)
    {
        appender.clear;
        ReusableAppender.appender.swap(appender);
    }
}

class FileLogger(alias Layout) : Logger
{
    private File file;

    // store cause it's awkward to derive in fileDescriptor, which must be signal-safe
    private int fileno;

    this(string name, uint levels = LogLevel.info.orAbove)
    {
        super(levels);
        file = File(name, "ab");
        fileno = file.fileno;
    }

    this(File file, uint levels = LogLevel.info.orAbove)
    {
        super(levels);
        this.file = file;
        fileno = this.file.fileno;
    }

    override void append(const ref EventInfo eventInfo,
        scope void delegate(ref Sink sink) putMessage)
    {
        auto appender = ReusableAppender.use;

        scope(exit) ReusableAppender.release(appender);

        Layout(appender, eventInfo, putMessage);
        file.lockingTextWriter.put(appender.data);
        file.flush;
    }

    override Nullable!int fileDescriptor() const @nogc nothrow @safe
    {
        return Nullable!int(fileno);
    }
}

class RollingFileLogger(alias Layout) : FileLogger!Layout
{
    private string[] names;

    private size_t size;

    this(const string[] names, size_t size, uint levels = LogLevel.info.orAbove)
    in
    {
        assert(!names.empty);
    }
    body
    {
        this.names = names.dup;
        this.size = size;
        super(this.names.front, levels);
    }

    override void append(const ref EventInfo eventInfo,
        scope void delegate(ref Sink sink) putMessage)
    {
        synchronized (this)
        {
            if (file.size >= size)
                roll;
            super.append(eventInfo, putMessage);
        }
    }

    private void roll()
    {
        import std.file : exists, rename;

        foreach_reverse (i, destination; names[1 .. $])
        {
            const source = names[i];

            if (source.exists)
                rename(source, destination);
        }
        file.open(names.front, "wb");
        fileno = file.fileno;
    }
}

version (Posix)
{
    private shared uint _count = 0;

    private extern (C) void hangup(int sig) nothrow @nogc
    {
        import core.atomic : atomicOp;

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
            import core.stdc.signal : signal, SIG_ERR;
            import core.sys.posix.signal : SIGHUP;
            import std.exception : enforce;

            enforce(signal(SIGHUP, &hangup) !is SIG_ERR);
        }

        override void append(const ref EventInfo eventInfo,
            scope void delegate(ref Sink sink) putMessage)
        {
            import core.atomic : atomicLoad;

            uint count = _count.atomicLoad;

            synchronized (this)
            {
                if (this.count != count)
                {
                    reopen;
                    this.count = count;
                }
                super.append(eventInfo, putMessage);
            }
        }

        private void reopen()
        {
            if (!file.name.empty)
            {
                file.close;
                file.open(file.name, "ab");
                fileno = file.fileno;
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

        override void append(const ref EventInfo eventInfo,
            scope void delegate(ref Sink sink) putMessage)
        {
            auto appender = ReusableAppender.use;

            scope(exit) ReusableAppender.release(appender);

            Layout(appender, eventInfo, putMessage);
            appender.put('\0');
            syslog(priority(eventInfo.level), "%s", appender.data.ptr);
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

    void syslogLayout(ref Sink sink, const ref EventInfo eventInfo,
        scope void delegate(ref Sink sink) putMessage)
    {
        putMessage(sink);
    }
}

// Time Thread Category Context layout
void layout(ref Sink sink, const ref EventInfo eventInfo,
    scope void delegate(ref Sink sink) putMessage)
{
    import core.thread : Thread;

    with (eventInfo)
    {
        time._toISOExtString(sink);
        sink.formattedWrite!" %-5s %s:%s"(level, file, line);

        if (Thread thread = Thread.getThis)
        {
            string name = thread.name;

            if (!name.empty)
                sink.formattedWrite!" [%s]"(name);
        }

        sink.put(' ');
        putMessage(sink);
        sink.put('\n');
    }
}

unittest
{
    EventInfo eventInfo;

    eventInfo.time = SysTime.fromISOExtString("2003-02-01T11:55:00.123456Z");
    eventInfo.level = LogLevel.error;
    eventInfo.file = "log.d";
    eventInfo.line = 42;

    auto writer = appender!(char[]);

    layout(writer, eventInfo, (ref Sink sink) { sink.put("don't panic"); });
    assert(writer.data == "2003-02-01T11:55:00.123+00:00 error log.d:42 don't panic\n");
}

unittest
{
    // instantiate templates to check for compilation errors
    if (false)
    {
        cast(void) rollingFileLogger("name", 10, 1024 * 1024);
        version (Posix)
        {
            cast(void) rotatingFileLogger("name");
            cast(void) syslogLogger;
        }
    }
}

// SysTime.toISOExtString has no fixed length and no time-zone offset for local time
private void _toISOExtString(W)(SysTime time, ref W writer)
if (isOutputRange!(W, char))
{
    (cast (DateTime) time).toISOExtString(writer);
    writer.formattedWrite!".%03d"(time.fracSecs.total!"msecs");
    time.utcOffset._toISOString(writer);
}

unittest
{
    auto dateTime = DateTime(2003, 2, 1, 12);
    auto fracSecs = 123_456.usecs;
    auto timeZone =  new immutable SimpleTimeZone(1.hours);
    auto time = SysTime(dateTime, fracSecs, timeZone);
    auto writer = appender!string;

    time._toISOExtString(writer);
    assert(writer.data == "2003-02-01T12:00:00.123+01:00");
}

// SimpleTimeZone.toISOString is private
@safe
private void _toISOString(W)(Duration offset, ref W writer)
if (isOutputRange!(W, char))
{
    uint hours;
    uint minutes;

    abs(offset).split!("hours", "minutes")(hours, minutes);
    writer.formattedWrite!"%s%02d:%02d"(offset.isNegative ? '-' : '+', hours, minutes);
}

unittest
{
    auto writer = appender!string;

    90.minutes._toISOString(writer);
    assert(writer.data == "+01:30");
}

unittest
{
    auto writer = appender!string;

    (-90).minutes._toISOString(writer);
    assert(writer.data == "-01:30");
}
