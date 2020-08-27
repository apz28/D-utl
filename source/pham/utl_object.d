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

import std.math : isPowerOf2;
import std.traits : isArray, isAssociativeArray, isPointer;

pragma(inline, true);
size_t alignRoundup(size_t n, size_t powerOf2AlignmentSize) nothrow pure @safe
in
{
    assert(powerOf2AlignmentSize > 1);
    assert(isPowerOf2(powerOf2AlignmentSize));
}
do
{
    return (n + powerOf2AlignmentSize - 1) & ~(powerOf2AlignmentSize - 1);
}

immutable string decimalDigits = "0123456789";
immutable string lowerHexDigits = "0123456789abcdef";
immutable string upperHexDigits = "0123456789ABCDEF";

ubyte[] bytesFromHexs(const(char)[] validHexChars) nothrow pure @safe
{
    const resultLength = (validHexChars.length / 2) + (validHexChars.length % 2);
    auto result = new ubyte[resultLength];
    size_t bitIndex = 0;
    bool shift = false;
    ubyte b = 0;
    for (auto i = 0; i < validHexChars.length; i++)
    {
        if (!isHex(validHexChars[i], b))
        {
            switch (validHexChars[i])
            {
                case ' ':
                case '_':
                    continue;
                default:
                    assert(0);
            }
        }

        if (shift)
        {
            result[bitIndex] = cast(ubyte)((result[bitIndex] << 4) | b);
            bitIndex++;
        }
        else
        {
            result[bitIndex] = b;
        }
        shift = !shift;
    }
    return result;
}

/**
 * Convert byte array to its hex presentation
 * Params:
 *  bytes = bytes to be converted
 *  isUpper = indicates which casing characters for letters
 * Returns:
 *  array of characters
 */
char[] bytesToHexs(const(ubyte)[] bytes,
    bool isUpper = true) nothrow pure @safe
{
    char[] result;
    if (bytes.length)
    {
        result.length = bytes.length * 2;
        const hexDigitSources = isUpper ? upperHexDigits : lowerHexDigits;
        size_t i;
        foreach (b; bytes)
        {
            result[i++] = hexDigitSources[(b >> 4) & 0xF];
            result[i++] = hexDigitSources[b & 0xF];
        }
    }
    return result;
}

/**
 * Check and convert a 'c' from hex to byte
 * Params:
 *  c = a charater to be checked and converted
 *  b = byte presentation of c's value
 * Returns:
 *  true if c is a valid hex characters, false otherwise
 */
bool isHex(char c, out ubyte b) nothrow pure @safe
{
    if (c >= '0' && c <= '9')
        b = cast(ubyte)(c - '0');
    else if (c >= 'A' && c <= 'F')
        b = cast(ubyte)((c - 'A') + 10);
    else if (c >= 'a' && c <= 'f')
        b = cast(ubyte)((c - 'a') + 10);
    else
    {
        b = 0;
        return false;
    }

    return true;
}

/**
 * Returns the class-name of object. If it is null, returns "null"
 * Params:
 *   object = the object to get the class-name from
 */
string className(Object object) nothrow pure @safe
{
    if (object is null)
        return "null";
    else
        return typeid(object).name;
}

/**
 * Returns the short class-name of object without template type. If it is null, returns "null"
 * Params:
 *   object = the object to get the class-name from
 */
string shortClassName(Object object) nothrow pure @safe
{
    import std.algorithm.iteration : filter;
    import std.array : join, split;
    import std.string : indexOf;

    if (object is null)
        return "null";
    else
    {
        string className = typeid(object).name;
        return split(className, ".").filter!(e => e.indexOf('!') < 0).join(".");
    }
}

/**
 * Initialize parameter v if it is null in thread safe manner using pass in initiate function
 * Params:
 *   v = variable to be initialized to object T if it is null
 *   initiate = a function that returns the newly created object as of T
 * Returns:
 *   parameter v
 */
T singleton(T)(ref T v, T function() pure @safe initiate) pure
if (is(T == class))
{
    import core.atomic : cas;
    import std.traits : hasElaborateDestructor;

    if (v is null)
    {
        auto n = initiate();
        if (!cas(&v, cast(T)null, n))
        {
            static if (hasElaborateDestructor!T)
                n.__xdtor();
        }
    }

    return v;
}

interface IDisposable
{
    void disposal(bool disposing) nothrow @safe;
    void dispose() nothrow @safe;
}

enum DisposableState
{
    none,
    disposing,
    destructing
}

abstract class DisposableObject : IDisposable
{
public:
    ~this()
    {
        version (TraceInvalidMemoryOp) import pham.utl_test : dgFunctionTrace;
        version (TraceInvalidMemoryOp) dgFunctionTrace(className(this));

        _disposing = byte.min; // Set to min avoid ++ then --
        doDispose(false);

        version (TraceInvalidMemoryOp) dgFunctionTrace(className(this));
    }

    final void disposal(bool disposing) nothrow @safe
    {
        if (!disposing)
            _disposing = byte.min; // Set to min avoid ++ then --

        _disposing++;
        scope (exit)
            _disposing--;

        doDispose(disposing);
    }

    final void dispose() nothrow @safe
    {
        _disposing++;
        scope (exit)
            _disposing--;

        doDispose(true);
    }

    @property final DisposableState disposingState() const nothrow @safe
    {
        if (_disposing == 0)
            return DisposableState.none;
        else if (_disposing > 0)
            return DisposableState.disposing;
        else
            return DisposableState.destructing;
    }

protected:
    abstract void doDispose(bool disposing) nothrow @safe;

private:
    byte _disposing;
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
            else static if (isArray!T || isAssociativeArray!T)
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

    @property inout(T) value() inout pure
    in
    {
        assert(_inited, "value must be set before using!");
    }
    do
    {
        return _value;
    }

    alias value this;

private:
    T _value;
    bool _inited;
}

version (unittest)
{
    class ClassName {}

    class ClassTemplate(T) {}
}

nothrow @safe unittest // className
{
    import pham.utl_test;
    dgWriteln("unittest utl_object.className");

    auto c1 = new ClassName();
    assert(className(c1) == "pham.utl_object.ClassName");

    auto c2 = new ClassTemplate!int();
    assert(className(c2) == "pham.utl_object.ClassTemplate!int.ClassTemplate");
}

nothrow @safe unittest // shortClassName
{
    import pham.utl_test;
    dgWriteln("unittest utl_object.shortClassName");

    auto c1 = new ClassName();
    assert(shortClassName(c1) == "pham.utl_object.ClassName");

    auto c2 = new ClassTemplate!int();
    assert(shortClassName(c2) == "pham.utl_object.ClassTemplate");
}

unittest // singleton
{
    import pham.utl_test;
    dgWriteln("unittest utl_object.singleton");

    static class A {}

    static A createA() pure @safe
    {
        return new A;
    }

    A a;
    assert(a is null);
    assert(singleton(a, &createA) !is null);
}

unittest // InitializedValue
{
    import pham.utl_test;
    dgWriteln("unittest utl_object.InitializedValue");

    InitializedValue!int n;
    assert(!n);
    assert(!n.inited);

    n = 0;
    assert(n);
    assert(n.inited);
    assert(n == 0);

    InitializedValue!ClassName c;
    assert(!c);
    assert(!c.inited);

    c = null;
    assert(!c);
    assert(c.inited);

    c = new ClassName();
    assert(c);
    assert(c.inited);
    assert(c !is null);
}

nothrow @safe unittest // isHex
{
    import pham.utl_test;
    dgWriteln("unittest utl_object.isHex");

    ubyte b;

    assert(isHex('0', b));
    assert(b == 0);

    assert(isHex('a', b));
    assert(b == 10);

    assert(!isHex('z', b));
    assert(b == 0);
}

nothrow @safe unittest // bytesFromHexs & bytesToHexs
{
    import pham.utl_test;
    dgWriteln("unittest utl_object.bytesFromHexs & bytesToHexs");

    assert(bytesToHexs([0], true) == "00");
    assert(bytesToHexs([1], true) == "01");
    assert(bytesToHexs([15], true) == "0F");
    assert(bytesToHexs([255], true) == "FF");

    assert(bytesFromHexs("00") == [0]);
    assert(bytesFromHexs("01") == [1]);
    assert(bytesFromHexs("0F") == [15]);
    assert(bytesFromHexs("FF") == [255]);

    enum testHexs = "43414137364546413943383943443734433130363737303145434232424332363635393136423946384145383143353537453543333044383939463236434443";
    auto bytes = bytesFromHexs(testHexs);
    assert(bytesToHexs(bytes) == testHexs);
}
