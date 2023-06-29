module log.GenericFileLogger;

import log.EventInfo;
import log.Logger;
import log.LogLevel;
import std.array;
import std.stdio;

class GenericFileLogger(Layout)
{
    // must be static to be thread-local
    private static Appender!(char[]) buffer;

    package File file;

    // store cause it's awkward to derive in fileDescriptor, which must be signal-safe
    package int fileno;

    package Layout layout;

    mixin Logger;

    this(Layout layout, string name, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        levels_ = levels;
        this.file = File(name, "ab");
        fileno = this.file.fileno;
        this.layout = layout;
    }

    this(Layout layout, File file, uint levels = LogLevel.info.orAbove)
    in (layout !is null)
    {
        levels_ = levels;
        this.file = file;
        fileno = this.file.fileno;
        this.layout = layout;
    }

    void append(string fmt, A...)(in EventInfo eventInfo, in A args)
    {
        file.writeToFile!((ref buffer) => layout.write!fmt(buffer, eventInfo, args));
    }

    void append(A...)(in string fmt, in EventInfo eventInfo, in A args)
    {
        file.writeToFile!((ref buffer) => layout.write(fmt, buffer, eventInfo, args));
    }

    // Segfault handling requires limiting ourselves to signal-safe functions,
    // which is a very limited subset - Phobos/toString/anything GC is right out.
    // For such cases, offer backdoor access to the file handle.
    public int fileDescriptor() const @nogc nothrow @safe
    {
        return fileno;
    }
}

private static Appender!(char[]) writerBuffer;

package void writeToFile(alias toString)(File file)
{
    import std.algorithm.mutation : swap;

    // avoid problems if toString functions call log - "borrow" static buffer
    Appender!(char[]) buffer;

    buffer.swap(writerBuffer);

    // put it back on exit, so the next call can use it
    scope (exit)
    {
        buffer.clear;
        buffer.swap(writerBuffer);
    }

    toString(buffer);
    file.lockingTextWriter.put(buffer.data);
    file.flush;
}
