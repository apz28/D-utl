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

module pham.utl_array;

import std.traits : isDynamicArray;

void removeItemAt(T)(ref T array, size_t index)
if (isDynamicArray!T)
in
{
    assert(index < array.length);
}
do
{
    // Move all items to the left
    while (index < array.length - 1)
    {
        array[index] = array[index + 1];
        ++index;
    }

    // Shrink the array length
    array.length = array.length - 1;
}

struct UnshrinkArray(T)
{
private:
    T[] _items;
    size_t _length;

    T doRemove(size_t index) nothrow
    in
    {
        assert(index < length);
        assert(length <= _items.length);
    }
    do
    {
        auto res = _items[index];
        for (size_t i = index + 1; i < length; ++i)
            _items[index++] = _items[i];
        _items[index] = T.init;
        --_length;
        return res;
    }

public:
    @disable this(this);

    //ref DbUniqueArray!T opOpAssign(string op)(T item)
    void opOpAssign(string op)(T item)
    if (op == "~" || op == "+" || op == "-")
    {
        static if (op == "~" || op == "+")
            putBack(item);
        else static if (op == "-")
            remove(item);
        else
            static assert(0);
    }

    bool opCast(ToT)()
    if (is(ToT == bool))
    {
        return length != 0;
    }

    /** Returns range interface
    */
    T[] opIndex() nothrow
    {
        if (_length != 0)
            return _items[0 .. _length];
        else
            return null;    
    }

    ref T opIndex(size_t index) nothrow
    in
    {
        assert(index < length);
    }
    do
    {
        return _items[index];
    }

    T opIndexAssign(T item, size_t index) nothrow
    in
    {
        assert(index < length);
    }
    do
    {
        _items[index] = item;
        return item;
    }

    void clear() nothrow
    {
        for (size_t i = 0; i < length; ++i)
            _items[i] = T.init;        

        _length = 0;
        _items.length = 0;
        _items.assumeSafeAppend();
    }

    T[] dup()
    {
        if (length != 0)
            return _items[0..length].dup;
        else
            return null;
    }

    ptrdiff_t indexOf(in T item)
    {
        for (auto i = length; i > 0; --i)
        {
            if (_items[i - 1] == item)
                return i - 1;
        }    
        return -1;
    }

    T putBack(T item) nothrow
    {
        if (length < _items.length)
            _items[length] = item;
        else
            _items ~= item;
        ++_length;
        assert(length <= _items.length);
        return item;
    }

    T remove(in T item)
    in
    {
        assert(length <= _items.length);
    }
    do
    {
        T res = T.init;
        while (1)
        {
            const i = indexOf(item);
            if (i >= 0)
                res = doRemove(i);
            else
                break;
        }
        return res;
    }

    T remove(size_t index) nothrow
    {
        if (index < length)
            return doRemove(index);
        else
            return T.init;
    }

@property:
    size_t length() const nothrow
    {
        return _length;
    }
}
