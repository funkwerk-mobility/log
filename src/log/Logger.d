module log.Logger;

mixin template Logger()
{
    private uint levels_;

    public uint levels() const nothrow pure @safe
    {
        return levels_;
    }

    private void testTypeImplementation()
    {
        import log.EventInfo : EventInfo;

        EventInfo eventInfo;

        this.append!"%s"(eventInfo, "Test");
        this.append("%s", eventInfo, "Test");
    }
}
