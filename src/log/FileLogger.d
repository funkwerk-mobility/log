module log.FileLogger;

import log.GenericFileLogger;
import log.LogLevel;
import std.stdio;

class FileLogger(Layout) : GenericFileLogger!Layout
{
    this(Layout layout, string name, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        super(layout, name, levels);
        assert(this.levels == levels);
    }

    this(Layout layout, File file, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        super(layout, file, levels);
    }
}
