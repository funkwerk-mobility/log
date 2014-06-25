module log;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.format;
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

/// Returns a bit set containing the level and all higher levels.
@safe
uint andHigher(LogLevel level) pure
{
    return [EnumMembers!LogLevel].find(level).reduce!"a | b";
}

///
unittest
{
    with (LogLevel)
    {
        assert(trace.andHigher == (trace | info | warn | error | fatal));
        assert(fatal.andHigher == fatal);
    }
}

alias trace=log!(LogLevel.trace);
alias info=log!(LogLevel.info);
alias warn=log!(LogLevel.warn);
alias error=log!(LogLevel.error);
alias fatal=log!(LogLevel.fatal);

template log(LogLevel level)
{
    void log(string file = __FILE__, size_t line = __LINE__, Char, A...)(in Char[] fmt, lazy A args)
    {
        _log(level, file, line, format(fmt, args));
    }

    void log(string file = __FILE__, size_t line = __LINE__, A)(lazy A arg)
    {
        _log(level, file, line, arg.to!string);
    }
}

private void _log(LogLevel level, string file, size_t line, lazy string message)
{
    with (Loggers.instance)
    {
        if (level & levels)
        {
            LogEvent event;

            event.time = Clock.currTime;
            event.level = level;
            event.file = file;
            event.line = line;
            event.message = message;
            log(event);
        }
    }
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

struct Loggers
{
    private static __gshared Loggers instance;

    private Logger[] loggers;

    private uint levels;

    private shared static this()
    {
        Loggers = [stderrLogger];
    }

    static opAssign(Logger[] loggers)
    in
    {
        assert(loggers.all!"a !is null");
    }
    body
    {
        instance = Loggers(loggers);
    }

    private this(Logger[] loggers)
    {
        this.loggers = loggers.dup;
        levels = reduce!((a, b) => a | b.levels)(0, this.loggers);
    }

    @disable
    this();

    void log(ref LogEvent event)
    {
        foreach (logger; loggers)
            if (event.level & logger.levels)
                logger.log(event);
    }
}

auto fileLogger(alias Layout = layout)
    (string name, uint levels = LogLevel.info.andHigher)
{
    return new FileLogger!Layout(name, levels);
}

auto stderrLogger(alias Layout = layout)
    (uint levels = LogLevel.warn.andHigher)
{
    return new FileLogger!Layout(stderr, levels);
}

auto stdoutLogger(alias Layout = layout)
    (uint levels = LogLevel.info.andHigher)
{
    return new FileLogger!Layout(stdout, levels);
}

auto rollingFileLogger(alias Layout = layout)
    (string name, size_t count, size_t size, uint levels = LogLevel.info.andHigher)
{
    return new RollingFileLogger!Layout(name ~ count.archiveFiles(name), size, levels);
}

auto rotatingFileLogger(alias Layout = layout)
    (string name, uint levels = LogLevel.info.andHigher)
{
    return new RotatingFileLogger!Layout(name, levels);
}

/// Returns n file names based on path for archived files.
@safe
string[] archiveFiles(size_t n, string path)
{
    import std.path;
    import std.range;

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

    abstract void log(ref LogEvent event);
}

class FileLogger(alias Layout) : Logger
{
    private File file;

    this(string name, uint levels = LogLevel.info.andHigher)
    {
        super(levels);
        file = File(name, "ab");
    }

    this(File file, uint levels = LogLevel.info.andHigher)
    {
        super(levels);
        this.file = file;
    }

    override void log(ref LogEvent event)
    {
        Layout(this.file.lockingTextWriter, event);
        this.file.flush;
    }
}

class RollingFileLogger(alias Layout) : FileLogger!Layout
{
    private string[] names;

    private size_t size;

    this(in string[] names, size_t size, uint levels = LogLevel.info.andHigher)
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

    override void log(ref LogEvent event)
    {
        synchronized (this)
        {
            if (file.size >= size)
            {
                roll;
            }
            super.log(event);
        }
    }

    private void roll()
    {
        import std.file;

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

    extern (C) void hangup(int sig)
    {
       _count.atomicOp!"+="(1);
    }

    class RotatingFileLogger(alias Layout) : FileLogger!Layout
    {
        private uint count = 0;

        this(string name, uint levels = LogLevel.info.andHigher)
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

        override void log(ref LogEvent event)
        {
            uint count = _count.atomicLoad;

            synchronized (this)
            {
                if (this.count != count)
                {
                    reopen;
                    this.count = count;
                }
                super.log(event);
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

// Time Thread Category Context layout
void layout(Writer)(Writer writer, ref LogEvent event)
{
    import core.thread;

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
    auto fracSec = FracSec.from!"usecs"(123456);
    auto timeZone =  new immutable SimpleTimeZone(1.hours);
    auto time = SysTime(dateTime, fracSec, timeZone);

    assert(time._toISOExtString == "2003-02-01T12:00:00.123+01:00");
}

// SimpleTimeZone.toISOString is private
 @safe
 private string _toISOString(Duration offset) pure
{
    if (offset.isNegative)
        return format("-%02d:%02d", -offset.hours, -offset.minutes);
    else
        return format("+%02d:%02d", offset.hours, offset.minutes);
}

unittest
{
    assert(_toISOString(90.minutes) == "+01:30");
    assert(_toISOString(-90.minutes) == "-01:30");
}
