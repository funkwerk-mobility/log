//          Copyright Mario Kröplin 2023.
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

private alias Sink = OutputRange!(const(char)[]);

struct Log
{
    private Logger[] loggers_;

    private uint levels;

    this(Logger[] loggers ...)
    in (loggers.all!"a !is null")
    {
        loggers_ = loggers.dup;
        levels = reduce!((a, b) => a | b.levels)(0, loggers_);
    }

    // Backdoor access for maintenance operations such as segfault handling.
    // See `FileLogger.fileDescriptor`.
    public Logger[] loggers() @nogc nothrow pure @safe
    {
        return loggers_;
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
            {
                if (level & levels)
                {
                    A evaluatedArgs = args;

                    _append(level, file, line,
                        (scope Sink sink) { sink.formattedWrite!(fmt.simplifyNamedReferences)(evaluatedArgs); });
                }
            }
        }

        void append(Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, Char, A...)
            (const Char[] fmt, lazy A args)
        {

            static if (!level.disabled)
            {
                if (level & levels)
                {
                    A evaluatedArgs = args;

                    _append(level, file, line,
                        (scope Sink sink) { sink.formattedWrite(fmt.simplifyNamedReferences, evaluatedArgs); });
                }
            }
        }

        void append(Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, A)
            (lazy A arg)
        {

            static if (!level.disabled)
            {
                if (level & levels)
                {
                    A evaluatedArg = arg;

                    _append(level, file, line,
                        (scope Sink sink) { sink.put(evaluatedArg.to!string); });
                }
            }
        }
    }

    private void _append(LogLevel level, string file, size_t line,
        scope void delegate(scope Sink sink) putMessage)
    {
        EventInfo eventInfo;

        eventInfo.time = Clock.currTime;
        eventInfo.level = level;
        eventInfo.file = file;
        eventInfo.line = line;

        foreach (logger; loggers_)
            if (level & logger.levels)
                logger.append(eventInfo, putMessage);
    }
}

// Helper to allow using named references in format strings, ie. treat %{name} equivalent to %s.
// Avoid std.regex because it's used at CTFE.
private const(char)[] simplifyNamedReferences(const(char)[] fmt)
{
    import std.exception : enforce;

    const(char)[] replacement = fmt;

    while (replacement.canFind("%{"))
    {
        enforce(replacement.find("%{").canFind("}"), fmt ~ ": terminating '}' not found");
        replacement = replacement[0 .. $ - replacement.find("%{").length]
            ~ "%s"
            ~ replacement.find("%{").find("}").dropOne;
    }
    return replacement;
}

unittest
{
    assert("".simplifyNamedReferences == "");
    assert("hello".simplifyNamedReferences == "hello");
    assert("%s world".simplifyNamedReferences == "%s world");
    assert("hello %{name} world".simplifyNamedReferences == "hello %s world");
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

auto fileLogger(string name, uint levels = LogLevel.info.orAbove)
{
    return new FileLogger!Layout(new Layout, name, levels);
}

auto stderrLogger(uint levels = LogLevel.warn.orAbove)
{
    return new FileLogger!Layout(new Layout, stderr, levels);
}

auto stdoutLogger(uint levels = LogLevel.info.orAbove)
{
    return new FileLogger!Layout(new Layout, stdout, levels);
}

auto rollingFileLogger(string name, size_t count, size_t size, uint levels = LogLevel.info.orAbove)
{
    return new RollingFileLogger!Layout(new Layout, name ~ count.archiveFiles(name), size, levels);
}

version (Posix)
{
    auto rotatingFileLogger(string name, uint levels = LogLevel.info.orAbove)
    {
        return new RotatingFileLogger!Layout(new Layout, name, levels);
    }

    auto syslogLogger(string name = null, uint levels = LogLevel.info.orAbove)
    {
        return new SyslogLogger!SyslogLayout(new SyslogLayout, name, levels);
    }
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
        scope void delegate(scope Sink sink) putMessage);
}

class FileLogger(Layout) : Logger
{
    // must be static to be thread-local
    private static Appender!(char[]) buffer;

    private File file;

    // store cause it's awkward to derive in fileDescriptor, which must be signal-safe
    private int fileno;

    private Layout layout;

    this(Layout layout, string name, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        super(levels);
        file = File(name, "ab");
        fileno = file.fileno;
        this.layout = layout;
    }

    this(Layout layout, File file, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        super(levels);
        this.file = file;
        fileno = this.file.fileno;
        this.layout = layout;
    }

    override void append(const ref EventInfo eventInfo,
        scope void delegate(scope Sink sink) putMessage)
    {
        import std.algorithm.mutation : swap;

        // avoid problems if toString functions call log - "borrow" static buffer
        Appender!(char[]) buffer;

        buffer.swap(this.buffer);

        // put it back on exit, so the next call can use it
        scope(exit)
        {
            buffer.clear;
            buffer.swap(this.buffer);
        }

        layout.write(buffer, eventInfo, putMessage);
        file.lockingTextWriter.put(buffer.data);
        file.flush;
    }

    // Segfault handling requires limiting ourselves to signal-safe functions,
    // which is a very limited subset - Phobos/toString/anything GC is right out.
    // For such cases, offer backdoor access to the file handle.
    public int fileDescriptor() const @nogc nothrow @safe
    {
        return fileno;
    }
}

class RollingFileLogger(Layout) : FileLogger!Layout
{
    private string[] names;

    private size_t size;

    this(Layout layout, const string[] names, size_t size, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    in(!names.empty)
    {
        super(layout, names.front, levels);
        this.names = names.dup;
        this.size = size;
    }

    override void append(const ref EventInfo eventInfo,
        scope void delegate(scope Sink sink) putMessage)
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

    class RotatingFileLogger(Layout) : FileLogger!Layout
    {
        private uint count = 0;

        this(Layout layout, string name, uint levels = LogLevel.info.orAbove)
        {
            super(layout, name, levels);
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
            scope void delegate(scope Sink sink) putMessage)
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

    class SyslogLogger(Layout) : Logger
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

        private Layout layout;

        this(Layout layout, string identifier = null, uint levels = LogLevel.info.orAbove)
        in (layout !is null)
        {
            enum LOG_USER = 1 << 3;

            super(levels);
            this.layout = layout;
            openlog(identifier.empty ? null : identifier.toStringz, 0, LOG_USER);
        }

        override void append(const ref EventInfo eventInfo,
            scope void delegate(scope Sink sink) putMessage)
        {
            auto writer = appender!string;

            layout.write(writer, eventInfo, putMessage);
            writer.put('\0');
            syslog(priority(eventInfo.level), "%s", writer.data.ptr);
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

    final class SyslogLayout
    {
        public void write(Writer)(ref Writer writer, const ref EventInfo eventInfo,
            scope void delegate(scope Sink sink) putMessage)
        {
            putMessage(outputRangeObject!(const(char)[])(writer));
        }
    }
}

// Time Thread Category Context layout
final class Layout
{
    void write(Writer)(ref Writer writer, const ref EventInfo eventInfo,
        scope void delegate(scope Sink sink) putMessage)
    {
        import core.thread : Thread;

        with (eventInfo)
        {
            time._toISOExtString(writer);
            writer.formattedWrite!" %-5s %s:%s"(level, file, line);

            if (Thread thread = Thread.getThis)
            {
                string name = thread.name;

                if (!name.empty)
                    writer.formattedWrite!" [%s]"(name);
            }

            writer.put(' ');
            putMessage(outputRangeObject!(const(char)[])(writer));
            writer.put('\n');
        }
    }
}

unittest
{
    EventInfo eventInfo;

    eventInfo.time = SysTime.fromISOExtString("2003-02-01T11:55:00.123456Z");
    eventInfo.level = LogLevel.error;
    eventInfo.file = "log.d";
    eventInfo.line = 42;

    auto writer = appender!string;
    auto layout = new Layout;

    layout.write(writer, eventInfo, (scope Sink sink) { sink.put("don't panic"); });
    assert(writer.data == "2003-02-01T11:55:00.123+00:00 error log.d:42 don't panic\n");
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
