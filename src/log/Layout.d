module log.Layout;

import log.EventInfo;
import log.LogLevel;
import std.array;
import std.datetime;
import std.format;
import std.range;

/**
 * Simple default layout of the form 'Time Thread Category Context'
 */
final class Layout
{
    void write(string fmt, Writer, A...)(ref Writer writer, in EventInfo eventInfo, in A args)
    {
        write(writer, eventInfo);
        writer.formattedWrite!fmt(args);
        writer.put('\n');
    }

    void write(Writer, A...)(string fmt, ref Writer writer, in EventInfo eventInfo, in A args)
    {
        write(writer, eventInfo);
        writer.formattedWrite(fmt, args);
        writer.put('\n');
    }

    private void write(Writer)(ref Writer writer, in EventInfo eventInfo)
    {
        import core.thread : Thread;

        with (eventInfo)
        {
            time._toISOExtString(writer);
            writer.formattedWrite!" %-5s %s:%s"(level, file, line);

            if (Thread thread = Thread.getThis)
            {
                string name = thread.name;

                if (!name.empty)
                    writer.formattedWrite!" [%s]"(name);
            }

            writer.put(' ');
        }
    }
}

unittest
{
    EventInfo eventInfo;

    eventInfo.time = SysTime.fromISOExtString("2003-02-01T11:55:00.123456Z");
    eventInfo.level = LogLevel.error;
    eventInfo.file = "log.d";
    eventInfo.line = 42;

    auto writer = appender!string;
    auto layout = new Layout;

    layout.write!"%s"(writer, eventInfo, "don't panic");
    assert(writer.data == "2003-02-01T11:55:00.123+00:00 error log.d:42 don't panic\n");
}

// SysTime.toISOExtString has no fixed length and no time-zone offset for local time
private void _toISOExtString(W)(SysTime time, ref W writer)
if (isOutputRange!(W, char))
{
    (cast(DateTime) time).toISOExtString(writer);
    writer.formattedWrite!".%03d"(time.fracSecs.total!"msecs");
    time.utcOffset._toISOString(writer);
}

unittest
{
    auto dateTime = DateTime(2003, 2, 1, 12);
    auto fracSecs = 123_456.usecs;
    auto timeZone = new immutable SimpleTimeZone(1.hours);
    auto time = SysTime(dateTime, fracSecs, timeZone);
    auto writer = appender!string;

    time._toISOExtString(writer);
    assert(writer.data == "2003-02-01T12:00:00.123+01:00");
}

// SimpleTimeZone.toISOString is private
@safe
private void _toISOString(W)(Duration offset, ref W writer)
if (isOutputRange!(W, char))
{
    uint hours;
    uint minutes;

    abs(offset).split!("hours", "minutes")(hours, minutes);
    writer.formattedWrite!"%s%02d:%02d"(offset.isNegative ? '-' : '+', hours, minutes);
}

unittest
{
    auto writer = appender!string;

    90.minutes._toISOString(writer);
    assert(writer.data == "+01:30");
}

unittest
{
    auto writer = appender!string;

    (-90).minutes._toISOString(writer);
    assert(writer.data == "-01:30");
}
