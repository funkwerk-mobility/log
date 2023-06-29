module log.RollingFileLogger;

import log.EventInfo;
import log.GenericFileLogger;
import log.LogLevel;
import std.range;

class RollingFileLogger(Layout) : GenericFileLogger!Layout
{
    private string[] names;

    private size_t size;

    this(Layout layout, const string[] names, size_t size, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    in (!names.empty)
    {
        super(layout, names.front, levels);
        this.names = names.dup;
        this.size = size;
    }

    void append(string fmt, A...)(in EventInfo eventInfo, in A args)
    {
        synchronized (this)
        {
            if (file.size >= size)
                roll;
            file.writeToFile!((ref buffer) => layout.write!fmt(buffer, eventInfo, args));
        }
    }

    void append(A...)(in string fmt, in EventInfo eventInfo, in A args)
    {
        synchronized (this)
        {
            if (file.size >= size)
                roll;
            file.writeToFile!((ref buffer) => layout.write(fmt, buffer, eventInfo, args));
        }
    }

    private void roll()
    {
        import std.file : exists, rename;

        foreach_reverse (i, destination; names[1 .. $])
        {
            const source = names[i];

            if (source.exists)
                rename(source, destination);
        }
        file.open(names.front, "wb");
        fileno = file.fileno;
    }
}
