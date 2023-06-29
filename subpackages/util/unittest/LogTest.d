module LogTest;

import util.log;

unittest
{
    log.info!"Hello World";
    log.fatal("%s", "Goodbye World");
}
