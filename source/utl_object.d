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

module pham.utl_object;

@safe:

/** Returns the class-name of object.
    If it is null, returns "null"
    Params:
        object = the object to get the class-name from
*/
string className(Object object) nothrow pure
{
    if (object is null)
        return "null";
    else
        return object.classinfo.name;
}

/** Returns the short class-name of object.
    If it is null, returns "null"
    Params:
        object = the object to get the class-name from
*/
string shortClassName(Object object) nothrow pure
{
    import std.array : join, split;
    import std.algorithm.iteration : filter;
    import std.string : indexOf;

    if (object is null)
        return "null";
    else
    {
        string className = object.classinfo.name;
        return split(className, ".").filter!(e => e.indexOf('!') < 0).join(".");
    }
}
