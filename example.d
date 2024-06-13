#!/usr/bin/env dub
/+ dub.sdl:
name "example"
dependency "log" path="."
+/

import std.compiler : version_minor;
import util.log;

string details()
{
    import std.stdio : writeln;

    writeln("lazy evaluation");
    return "details";
}

enum supportsStringInterpolation = version_minor >= 108;

void main()
{
    log = Log(stderrLogger, stdoutLogger(LogLevel.info), fileLogger("log"));

    try
    {
        throw new Exception("something went wrong");
    }
    catch (Exception exception)
    {
        log.fatal(exception);
    }
    log.error("don't panic");
    log.warn("mostly harmless"d);
    log.info("the answer is %s", 42);
    log.info!"the answer is %s"(42);
    log.trace(details);

    static if (supportsStringInterpolation)
    {
        // mixin so that it passes the lexer on older dmd
        mixin(`log.info(i"the answer is $(42)");`);
    }

    version (Posix)
    {
        Log syslog = Log(syslogLogger);

        syslog.error("don't panic");
    }
}
