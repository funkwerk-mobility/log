module log.Log;

import log.EventInfo;
import log.LogLevel;
import std.algorithm;
import std.datetime : Clock;
import std.meta : staticMap;
import std.sumtype;
import std.traits : isSomeString;

struct Log(Loggers...)
{
    public alias Logger = SumType!Loggers;

    private Logger[] loggers_;

    private uint levels;

    this(Logger[] loggers...)
    {
        loggers_ = loggers.dup;

        levels = loggers_.map!(.levels)
            .fold!"a | b"(0);
    }

    // Backdoor access for maintenance operations such as segfault handling.
    // See `GenericFileLogger.fileDescriptor`.
    public Logger[] loggers() @nogc nothrow pure @safe
    {
        return loggers_;
    }

    alias trace = append!(LogLevel.trace);
    alias info = append!(LogLevel.info);
    alias warn = append!(LogLevel.warn);
    alias error = append!(LogLevel.error);
    alias fatal = append!(LogLevel.fatal);

    // argument cannot be provided explicitly
    private struct Fence
    {
    }

    template append(LogLevel level)
    {
        void append(alias fmt, Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, A...)(lazy A args)
        if (isSomeString!(typeof(fmt)))
        {
            static if (!level.disabled)
            {
                if (level & levels)
                {
                    _append!fmt(level, file, line, args);
                }
            }
        }

        void append(Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, A...)(
            string fmt, lazy A args)
        {

            static if (!level.disabled)
            {
                if (level & levels)
                {
                    _append(fmt, level, file, line, args);
                }
            }
        }

        void append(Fence _ = Fence(), string file = __FILE__, size_t line = __LINE__, A)(lazy A arg)
        {
            append!("%s", Fence(), file, line)(arg);
        }
    }

    private void _append(string fmt, A...)(LogLevel level, string file, size_t line, A args)
    {
        const eventInfo = EventInfo(Clock.currTime, level, file, line);

        foreach (logger; loggers_)
            if (level & logger.levels)
                logger.match!(
                    staticMap!(logger => logger.append!(fmt, A)(eventInfo, args), Loggers));
    }

    private void _append(A...)(string fmt, LogLevel level, string file, size_t line, A args)
    {
        const eventInfo = EventInfo(Clock.currTime, level, file, line);

        foreach (logger; loggers_)
            if (level & logger.levels)
                logger.match!(
                    staticMap!(logger => logger.append!A(fmt, eventInfo, args), Loggers));
    }
}

private uint levels(Loggers...)(in SumType!Loggers logger)
{
    return logger.match!(
        staticMap!((in a) => a.levels, Loggers));
}
