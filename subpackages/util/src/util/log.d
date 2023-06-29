module util.log;

import log.EventInfo : EventInfo;
import log.FileLogger : FileLogger;
import log.Log : Log;
import log.Layout : Layout;
import log.LogLevel : LogLevel, orAbove;
import log.RollingFileLogger : RollingFileLogger;
import std.algorithm;
import std.datetime;
import std.format;
import std.meta;
import std.range;
import std.stdio : stderr;

version (Posix)
{
    import log.RotatingFileLogger : RotatingFileLogger;
    import log.SyslogLogger : SyslogLayout, SyslogLogger;

    alias PosixLoggers = AliasSeq!(
        RotatingFileLogger!Layout,
        SyslogLogger!SyslogLayout,
    );
}
else
{
    alias PosixLoggers = AliasSeq!();
}

__gshared Log!(
    FileLogger!Layout,
    RollingFileLogger!Layout,
    PosixLoggers
) log;

shared static this()
{
    log = typeof(log)([log.Logger(stderrLogger)]);
}

package FileLogger!Layout stderrLogger(uint levels = LogLevel.warn.orAbove)
out (logger; logger !is null)
{
    return new FileLogger!Layout(new Layout, stderr, levels);
}
