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

module pham.utl.object;

import std.traits;

nothrow @safe:

/** Returns the class-name of object.
    If it is null, returns "null"
    Params:
        object = the object to get the class-name from
*/
string className(Object object) pure
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
string shortClassName(Object object) pure
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

@system
interface IDisposable
{
    void dispose();
}

struct InitializedValue(T)
{
nothrow @safe:

public:
    this(T value)
    {
        this._value = value;
        this._inited = true;
    }

    ref typeof(this) opAssign(T)(T value) return
    {
        this._value = value;
        this._inited = true;
        return this;
    }

    C opCast(C: bool)() const
    {
        if (_inited)
        {
            static if (isPointer!T || is(T == class))
                return _value !is null;
            else static if (isArray!T)
                return _value.length != 0;
            else
                return true;
        }
        else
            return false;
    }

    ref typeof(this) reset() return
    {
        if (_inited)
        {
            _value = T.init;
            _inited = false;
        }
        return this;
    }

    @property bool inited() const
    {
        return _inited;
    }

    @property inout T value() pure
    {
        assert(_inited, "value must be set before using!");

        return _value;
    }

    alias value this;

private:
    T _value;
    bool _inited;
}
