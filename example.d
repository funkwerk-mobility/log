#!/usr/bin/env rdmd -unittest -Isrc

import log;

string everything()
{
    import std.stdio;

    writeln("lazy evaluation");
    return "everything";
}

void main()
{
    Loggers = [stderrLogger, fileLogger("log")];

    trace(everything);
    info("the answer is %s", 42);
    warn("mostly harmless");
    error("don't panic"d);
    try
    {
        throw new Exception("something went wrong");
    }
    catch (Exception exception)
    {
        fatal(exception);
    }
}
