module log.SyslogLogger;

version (Posix)  : import log.EventInfo;
import log.Logger;
import log.LogLevel;
import std.range;
import std.string : toStringz;

private extern (C) void openlog(const char* ident, int option, int facility);

private extern (C) void syslog(int priority, const char* format, ...);

class SyslogLogger(Layout)
{
    enum SyslogLevel
    {
        LOG_EMERG = 0, // system is unusable
        LOG_ALERT = 1, // action must be taken immediately
        LOG_CRIT = 2, // critical conditions
        LOG_ERR = 3, // error conditions
        LOG_WARNING = 4, // warning conditions
        LOG_NOTICE = 5, // normal but significant condition
        LOG_INFO = 6, // informational
        LOG_DEBUG = 7, // debug-level messages
    }

    private Layout layout;

    mixin Logger;

    this(Layout layout, string identifier = null, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        enum LOG_USER = 1 << 3;

        this.levels_ = levels;
        this.layout = layout;
        openlog(identifier.empty ? null : identifier.toStringz, 0, LOG_USER);
    }

    void append(string fmt, A...)(in EventInfo eventInfo, A args)
    {
        auto writer = appender!string;

        layout.write!fmt(writer, eventInfo, args);
        writer.put('\0');
        syslog(priority(eventInfo.level), "%s", writer.data.ptr);
    }

    void append(A...)(in string fmt, in EventInfo eventInfo, in A args)
    {
        auto writer = appender!string;

        layout.write(writer, fmt, eventInfo, args);
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
    public void write(string fmt, Writer, A...)(ref Writer writer, in EventInfo eventInfo, in A args)
    {
        import std.format : formattedWrite;

        writer.formattedWrite!fmt(args);
    }

    public void write(Writer, A...)(ref Writer writer, in string fmt, in EventInfo eventInfo, in A args)
    {
        import std.format : formattedWrite;

        writer.formattedWrite(fmt, args);
    }
}
