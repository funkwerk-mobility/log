module log.LogLevel;

import std.algorithm;
import std.range;
import std.traits : EnumMembers;

/// Defines the importance of a log message.
enum LogLevel
{
    /// detailed tracing
    trace = 1,
    /// useful information
    info = 2,
    /// potential problem
    warn = 4,
    /// recoverable error
    error = 8,
    /// fatal failure
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
