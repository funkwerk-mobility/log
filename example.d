#!/usr/bin/env rdmd -unittest -Isrc

import log;

string details()
{
    import std.stdio;

    writeln("lazy evaluation");
    return "details";
}

void main()
{
    Loggers = [stderrLogger, fileLogger("log")];

    try
    {
        throw new Exception("something went wrong");
    }
    catch (Exception exception)
    {
        fatal(exception);
    }
    error("don't panic"d);
    warn("mostly harmless");
    info("the answer is %s", 42);
    trace(details);
}
