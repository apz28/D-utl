/*
 *
 * License: $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: An Pham
 *
 * Copyright An Pham 2017 - xxxx.
 * Distributed under the Boost Software License, Version 1.0.
 * (See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
 *
 */

module pham.utl_object;

/** Returns the class-name of aObject.
    If it is null, returns "null"
    Params:
        aObject = the object to get the class-name from
*/
string className(Object aObject) pure nothrow @safe
{
    if (aObject is null)
        return "null";
    else
        return aObject.classinfo.name;
}

/** Returns the short class-name of aObject.
    If it is null, returns "null"
    Params:
        aObject = the object to get the class-name from
*/
string shortClassName(Object aObject) pure nothrow @safe
{
    import std.array : join, split;
    import std.algorithm.iteration : filter;
    import std.string : indexOf;

    if (aObject is null)
        return "null";
    else
    {
        string className = aObject.classinfo.name;
        return split(className, ".").filter!(e => e.indexOf('!') < 0).join(".");
    }
}
