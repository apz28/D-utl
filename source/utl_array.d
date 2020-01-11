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

module pham.utl_array;

import std.range.primitives : ElementType;
import std.traits : isDynamicArray, isStaticArray, lvalueOf;

void removeAt(T)(ref T array, size_t index) nothrow pure @safe
if (isDynamicArray!T)
in
{
    assert(array.length > 0);
    assert(index < array.length);
}
do
{
    // Move all items after index to the left
    if (array.length > 1)
    {
        while (index < array.length - 1)
        {
            array[index] = array[index + 1];
            ++index;
        }
    }

    // Shrink the array length
    // It will set the array[index] to default value when length is reduced
    array.length = array.length - 1;
}

void removeAt(T)(ref T array, size_t index, ref size_t length) nothrow pure @safe
if (isStaticArray!T)
in
{
    assert(length > 0 && length <= array.length);
    assert(index < length);
}
do
{
    // Safety check
    if (length > array.length)
        length = array.length;

    // Move all items after index to the left
    if (length > 1)
    {
        while (index < length - 1)
        {
            array[index] = array[index + 1];
            ++index;
        }
    }

    // Reset the value at array[index]
    static if (is(typeof(lvalueOf!T[0]) == char))
        array[index] = char.init;
    else
        array[index] = ElementType!T.init;
    --length;
}

struct IndexedArray(T, ushort staticSize)
{
private:
    T[] _dynamicItems;
    T[staticSize] _staticItems;
    size_t _staticLength;

    T doRemove(size_t index) nothrow pure @trusted
    in
    {
        assert(index < length);
    }
    do
    {
        if (useStatic())
        {
            assert(_staticLength > 0 && _staticLength <= staticSize);
            auto res = _staticItems[index];
            .removeAt(_staticItems, index, _staticLength);
            return res;
        }
        else
        {
            auto res = _dynamicItems[index];
            .removeAt(_dynamicItems, index);
            return res;
        }
    }

    void switchToDynamicItems(size_t newLength) nothrow pure @trusted
    {
        if (useStatic())
        {
            assert(_staticLength == staticSize);

            const capacity = newLength > staticSize ? newLength + newLength / 2 : staticSize * 2;
            _dynamicItems.reserve(capacity);

            _dynamicItems.length = newLength > staticSize ? newLength : staticSize;
            _dynamicItems[0..staticSize] = _staticItems[0..staticSize];

            _staticItems[] = T.init;
            _staticLength = 0;
        }
        else
        {
            if (newLength > _dynamicItems.capacity)
                _dynamicItems.reserve(newLength + newLength / 2);

            if (newLength > _dynamicItems.length)
                _dynamicItems.length = newLength;
        }
    }

public:
    this(size_t capacity) nothrow pure @safe
    {
        if (capacity > staticSize)
            _dynamicItems.reserve(capacity);
    }

    this(inout(T)[] value) nothrow pure @safe
    {
        const len = value.length;
        this(len);
        if (len != 0)
        {
            if (len <= staticSize)
            {
                _staticItems[0..len] = value[0..len];
                _staticLength = len;
            }
            else
            {
                _dynamicItems.length = len;
                _dynamicItems[0..len] = value[0..len];
            }
        }
    }

    void opOpAssign(string op)(T item) nothrow pure @safe
    if (op == "~" || op == "+" || op == "-")
    {
        static if (op == "~" || op == "+")
            putBack(item);
        else static if (op == "-")
            remove(item);
        else
            static assert(0);
    }

    bool opCast(To: bool)() const nothrow pure @safe
    {
        return !empty;
    }

    /** Returns range interface
    */
    T[] opIndex() nothrow pure return @safe
    {
        const len = length;
        return len != 0 ? (useStatic() ? _staticItems[0..len] : _dynamicItems) : null;
    }

    T opIndex(size_t index) const nothrow pure @safe
    in
    {
        assert(index < length);
    }
    do
    {
        return useStatic() ? _staticItems[index] : _dynamicItems[index];
    }

    void opIndexAssign(T item, size_t index) nothrow pure @safe
    {
        const newLength = index + 1;
        if (newLength > staticSize || !useStatic())
        {
            switchToDynamicItems(newLength);
            _dynamicItems[index] = item;
        }
        else
        {
            _staticItems[index] = item;
            if (_staticLength < newLength)
                _staticLength = newLength;
            assert(_staticLength <= staticSize);
        }
        assert(newLength <= length);
    }

    void opIndexAssign(inout(T)[] items, size_t startIndex) nothrow pure @safe
    {
        const newLength = startIndex + items.length;
        if (newLength > staticSize || !useStatic())
        {
            switchToDynamicItems(newLength);
            _dynamicItems[startIndex..startIndex + items.length] = items[0..items.length];
        }
        else
        {
            _staticItems[startIndex..startIndex + items.length] = items[0..items.length];
            if (_staticLength < newLength)
                _staticLength = newLength;
            assert(_staticLength <= staticSize);
        }
        assert(newLength <= length);
    }

    /** Returns range interface
    */
    T[] opSlice(size_t begin, size_t end) nothrow pure return @safe
    in
    {
        assert(begin < end);
        assert(begin < length);
    }
    do
    {
        const len = length;
        if (end > len)
            end = len;

        return end - begin > 0 ? (useStatic() ? _staticItems[begin..end] : _dynamicItems[begin..end]) : null;
    }

    void clear(size_t capacity = 0) nothrow pure @safe
    {
        assert(_staticLength <= staticSize);

        if (_staticLength != 0)
        {
            _staticItems[0.._staticLength] = T.init;
            _staticLength = 0;
        }

        if (capacity > staticSize)
        {
            if (_dynamicItems.length != 0)
                _dynamicItems.length = 0;
            _dynamicItems.reserve(capacity);
        }
        else
            _dynamicItems = null;
    }

    T[] dup() nothrow pure @safe
    {
        return opIndex().dup;
    }

    ptrdiff_t indexOf(in T item) nothrow pure @trusted
    {
        if (length == 0)
            return -1;

        auto items = opIndex();
        for (ptrdiff_t i = 0; i < items.length; ++i)
        {
            if (items[i] == item)
                return i;
        }
        return -1;
    }

    alias put = putBack;

    T putBack(T item) nothrow pure @safe
    {
        const newLength = length + 1;
        if (newLength > staticSize || !useStatic())
        {
            switchToDynamicItems(newLength);
            _dynamicItems[newLength - 1] = item;
        }
        else
        {
            _staticItems[_staticLength++] = item;
            assert(_staticLength <= staticSize);
        }
        assert(length == newLength);

        return item;
    }

    T remove(in T item) nothrow pure @safe
    {
        const i = indexOf(item);
        if (i >= 0)
            return doRemove(i);
        else
            return T.init;
    }

    T removeAt(size_t index) nothrow pure @safe
    {
        if (index < length)
            return doRemove(index);
        else
            return T.init;
    }

    T* ptr(size_t startIndex = 0) nothrow pure return @safe
    in
    {
        assert(startIndex < length);
    }
    do
    {
        return useStatic() ? &_staticItems[startIndex] : &_dynamicItems[startIndex];
    }

    void fill(T item, size_t startIndex = 0) nothrow pure @safe
    in
    {
        assert(startIndex < length);
    }
    do
    {
        if (useStatic())
            _staticItems[startIndex..$] = item;
        else
        {
            _staticItems[] = item;
            _dynamicItems[startIndex..$] = item;
        }
    }

    pragma (inline, true)
    bool useStatic() const nothrow pure @safe
    {
        return _dynamicItems.ptr is null;
    }

    @property bool empty() const nothrow pure @safe
    {
        return length == 0;
    }

    @property size_t length() const nothrow pure @safe
    {
        return useStatic() ? _staticLength : _dynamicItems.length;
    }

    @property size_t length(size_t newLength) nothrow pure @safe
    {
        if (length() != newLength)
        {
            if (newLength <= staticSize && useStatic())
                _staticLength = newLength;
            else
                switchToDynamicItems(newLength);
        }
        return newLength;
    }
}

struct UnshrinkArray(T)
{
private:
    T[] _items;

    T doRemove(size_t index) nothrow @trusted
    in
    {
        assert(_items.length > 0);
        assert(index < _items.length);
    }
    do
    {
        auto res = _items[index];
        .removeAt(_items, index);
        return res;
    }

public:
    this(size_t capacity) nothrow @safe
    {
        if (capacity != 0)
            _items.reserve(capacity);
    }

    void opOpAssign(string op)(T item) nothrow @safe
    if (op == "~" || op == "+" || op == "-")
    {
        static if (op == "~" || op == "+")
            putBack(item);
        else static if (op == "-")
            remove(item);
        else
            static assert(0);
    }

    bool opCast(To: bool)() const nothrow @safe
    {
        return !empty;
    }

    /** Returns range interface
    */
    T[] opIndex() nothrow return @safe
    {
        return _items;
    }

    T opIndex(size_t index) nothrow @safe
    in
    {
        assert(index < _items.length);
    }
    do
    {
        return _items[index];
    }

    void opIndexAssign(T item, size_t index) nothrow @safe
    in
    {
        assert(index < _items.length);
    }
    do
    {
        _items[index] = item;
    }

    void clear() nothrow @trusted
    {
        _items.length = 0;
    }

    T[] dup() nothrow @safe
    {
        if (_items.length != 0)
            return _items.dup;
        else
            return null;
    }

    ptrdiff_t indexOf(in T item) nothrow @trusted
    {
        if (_items.length != 0)
            for (ptrdiff_t i = 0; i < _items.length; ++i)
            {
                if (_items[i] == item)
                    return i;
            }

        return -1;
    }

    T putBack(T item) nothrow @safe
    {
        _items ~= item;
        return item;
    }

    T remove(in T item) nothrow @safe
    {
        const i = indexOf(item);
        if (i >= 0)
            return doRemove(i);
        else
            return T.init;
    }

    T removeAt(size_t index) nothrow @safe
    {
        if (index < length)
            return doRemove(index);
        else
            return T.init;
    }

    @property bool empty() const nothrow @safe
    {
        return length == 0;
    }

    @property size_t length() const nothrow @safe
    {
        return _items.length;
    }
}

unittest
{
    import std.stdio : writeln;
    writeln("unittest utl_array.IndexedArray");

    auto a = IndexedArray!(int, 2)(0);

    // Check initial state
    assert(a.empty);
    assert(a.length == 0);
    assert(a.remove(1) == 0);
    assert(a.removeAt(1) == 0);
    assert(a.useStatic());

    // Append element
    a.putBack(1);
    assert(!a.empty);
    assert(a.length == 1);
    assert(a.indexOf(1) == 0);
    assert(a[0] == 1);
    assert(a.useStatic());

    // Append second element
    a += 2;
    assert(a.length == 2);
    assert(a.indexOf(2) == 1);
    assert(a[1] == 2);
    assert(a.useStatic());

    // Append element & remove
    a += 10;
    assert(a.length == 3);
    assert(a.indexOf(10) == 2);
    assert(a[2] == 10);
    assert(!a.useStatic());

    a -= 10;
    assert(a.indexOf(10) == -1);
    assert(a.length == 2);
    assert(a.indexOf(2) == 1);
    assert(a[1] == 2);
    assert(!a.useStatic());

    // Check duplicate
    assert(a.dup == [1, 2]);

    // Set new element at index (which is at the end for this case)
    a[2] = 3;
    assert(a.length == 3);
    assert(a.indexOf(3) == 2);
    assert(a[2] == 3);

    // Replace element at index
    a[1] = -1;
    assert(a.length == 3);
    assert(a.indexOf(-1) == 1);
    assert(a[1] == -1);

    // Check duplicate
    assert(a.dup == [1, -1, 3]);

    // Remove element
    auto r = a.remove(-1);
    assert(r == -1);
    assert(a.length == 2);
    assert(a.indexOf(-1) == -1);
    assert(!a.useStatic());

    // Remove element at
    r = a.removeAt(0);
    assert(r == 1);
    assert(a.length == 1);
    assert(a.indexOf(1) == -1);
    assert(a[0] == 3);
    assert(!a.useStatic());

    // Clear all elements
    a.clear();
    assert(a.empty);
    assert(a.length == 0);
    assert(a.remove(1) == 0);
    assert(a.removeAt(1) == 0);
    assert(a.useStatic());

    a[0] = 1;
    assert(!a.empty);
    assert(a.length == 1);
    assert(a.useStatic());

    a.clear();
    assert(a.empty);
    assert(a.length == 0);
    assert(a.remove(1) == 0);
    assert(a.removeAt(1) == 0);
    assert(a.useStatic());

    a.putBack(1);
    a.fill(10);
    assert(a.length == 1);
    assert(a[0] == 10);
}

unittest
{
    import std.stdio : writeln;
    writeln("unittest utl_array.UnshrinkArray");

    auto a = UnshrinkArray!int(0);

    // Check initial state
    assert(a.empty);
    assert(a.length == 0);
    assert(a.remove(1) == 0);
    assert(a.removeAt(1) == 0);

    // Append element
    a.putBack(1);
    assert(!a.empty);
    assert(a.length == 1);
    assert(a.indexOf(1) == 0);
    assert(a[0] == 1);

    // Append element
    a += 2;
    assert(a.length == 2);
    assert(a.indexOf(2) == 1);
    assert(a[1] == 2);

    // Append element & remove
    a += 10;
    assert(a.length == 3);
    assert(a.indexOf(10) == 2);
    assert(a[2] == 10);

    a -= 10;
    assert(a.indexOf(10) == -1);
    assert(a.length == 2);
    assert(a.indexOf(2) == 1);
    assert(a[1] == 2);

    // Check duplicate
    assert(a.dup == [1, 2]);

    // Append element
    a ~= 3;
    assert(a.length == 3);
    assert(a.indexOf(3) == 2);
    assert(a[2] == 3);

    // Replace element at index
    a[1] = -1;
    assert(a.length == 3);
    assert(a.indexOf(-1) == 1);
    assert(a[1] == -1);

    // Check duplicate
    assert(a.dup == [1, -1, 3]);

    // Remove element
    auto r = a.remove(-1);
    assert(r == -1);
    assert(a.length == 2);
    assert(a.indexOf(-1) == -1);

    // Remove element at
    r = a.removeAt(0);
    assert(r == 1);
    assert(a.length == 1);
    assert(a.indexOf(1) == -1);
    assert(a[0] == 3);

    // Clear all elements
    a.clear();
    assert(a.empty);
    assert(a.length == 0);
    assert(a.remove(1) == 0);
    assert(a.removeAt(1) == 0);
}

