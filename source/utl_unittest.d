/*
 *
 * License: $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: An Pham
 *
 * Copyright An Pham 2017 - xxxx.
 * Distributed under the Boost Software License, Version 1.0.
 * (See accompanying file LICENSE.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
 *
 */

module pham.utl_unittest;

nothrow:
@safe:

version(unittest)
{
    import std.traits : isSomeChar;

    void dgWrite(A...)(A args)
    {
        import std.stdio : write;

        try
        {
            write(args);
        }
        catch (Exception)
        {
            assert(0);
        }
    }

    void dgWritef(Char, A...)(in Char[] fmt, A args)
    if (isSomeChar!Char)
    {
        import std.stdio : writef;

        try
        {
            writef(fmt, args);
        }
        catch (Exception)
        {
            assert(0);
        }
    }

    void dgWriteln(A...)(A args)
    {
        import std.stdio : writeln;

        try
        {
            writeln(args);
        }
        catch (Exception)
        {
            assert(0);
        }
    }

    void dgWritefln(Char, A...)(in Char[] fmt, A args)
    if (isSomeChar!Char)
    {
        import std.stdio : writefln;

        try
        {
            writefln(fmt, args);
        }
        catch (Exception)
        {
            assert(0);
        }
    }
}
