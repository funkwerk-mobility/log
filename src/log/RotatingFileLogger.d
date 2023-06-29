module log.RotatingFileLogger;

version (Posix)  : import log.EventInfo;
import log.GenericFileLogger;
import log.LogLevel;
import std.range;

class RotatingFileLogger(Layout) : GenericFileLogger!Layout
{
    private uint count = 0;

    this(Layout layout, string name, uint levels = LogLevel.info.orAbove)
    {
        super(layout, name, levels);
        setUpSignalHandler;
    }

    private void setUpSignalHandler()
    {
        import core.stdc.signal : SIG_ERR, signal;
        import core.sys.posix.signal : SIGHUP;
        import std.exception : enforce;

        enforce(signal(SIGHUP, &hangup) !is SIG_ERR);
    }

    void append(string fmt, A...)(in EventInfo eventInfo, in A args)
    {
        import core.atomic : atomicLoad;

        uint count = _count.atomicLoad;

        synchronized (this)
        {
            if (this.count != count)
            {
                reopen;
                this.count = count;
            }
            super.append!fmt(eventInfo, args);
        }
    }

    void append(A...)(in string fmt, in EventInfo eventInfo, in A args)
    {
        import core.atomic : atomicLoad;

        uint count = _count.atomicLoad;

        synchronized (this)
        {
            if (this.count != count)
            {
                reopen;
                this.count = count;
            }
            super.append(fmt, eventInfo, args);
        }
    }

    private void reopen()
    {
        if (!file.name.empty)
        {
            file.close;
            file.open(file.name, "ab");
            fileno = file.fileno;
        }
    }
}

private shared uint _count = 0;

private extern (C) void hangup(int sig) nothrow @nogc
{
    import core.atomic : atomicOp;

    _count.atomicOp!"+="(1);
}
