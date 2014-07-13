#!/usr/bin/env rdmd -unittest -Isrc

static import log;

string details()
{
    import std.stdio;

    writeln("lazy evaluation");
    return "details";
}

void main()
{
    log.Loggers = [log.stderrLogger, log.fileLogger("log")];

    try
    {
        throw new Exception("something went wrong");
    }
    catch (Exception exception)
    {
        log.fatal(exception);
    }
    log.error("don't panic"d);
    log.warn("mostly harmless");
    log.info("the answer is %s", 42);
    log.trace(details);
}
