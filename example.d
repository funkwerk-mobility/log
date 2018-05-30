#!/usr/bin/env dub
/+ dub.sdl:
name "example"
dependency "log" path="."
+/

import util.log;

string details()
{
    import std.stdio : writeln;

    writeln("lazy evaluation");
    return "details";
}

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

    version (Posix)
    {
        Log syslog = Log(syslogLogger);

        syslog.error("don't panic");
    }
}
