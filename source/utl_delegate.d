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

module pham.utl_delegate;

import pham.utl_array;

struct DelegateList(Args...)
{
public:
    alias DelegateHandler = void delegate(Args args);

private:
    UnshrinkArray!DelegateHandler items;

public:
    @disable this(this);

    void opOpAssign(string op)(DelegateHandler handler) nothrow
    if (op == "~" || op == "+" || op == "-")
    {
        static if (op == "~" || op == "+")
            items.putBack(handler);
        else static if (op == "-")
            items.remove(handler);
        else
            static assert(0);
    }

    void opCall(Args args)
    {
        if (items.length != 0)
        {        
            // Always make a copy to avoid skip/misbehavior if handler removes 
            // any from the list that means the lifetime of the caller instance
            // must be out lived while notifying
            auto foreachItems = items.dup();
            foreach (i; foreachItems)
                i(args);
        }
    }

    bool opCast(ToT)() @safe nothrow
    if (is(ToT == bool))
    {
        return length != 0;
    }

    /** Removes all the elements from the array
    */
    void clear() nothrow
    {
        items.clear();
    }

    /** Appends element, handler, into end of array
        Params:
            handler = element to be appended
    */
    void putBack(DelegateHandler handler) nothrow
    {
        if (handler !is null)
            items.putBack(handler);
    }

    /** Eliminates matched element, handler, from array
        Params:
            handler = element to be removed
    */
    void remove(DelegateHandler handler) nothrow
    {        
        if (handler !is null)
            items.remove(handler);
    }

@property:
    size_t length() const nothrow
    {
        return items.length;
    }
}

unittest // DelegateList
{
    import std.stdio : writeln;
    writeln("unittest utl_delegate.DelegateList");

    string eName;
    int eValue;

    struct S1
    {
        int a;
        void accumulate(string name, int value) nothrow 
        {
            a += value;
        }
    }

    DelegateList!(string, int) list;
    assert(!list);

    auto s1 = S1(100);
    list += &s1.accumulate;
    assert(list && list.length == 1);

    list += (string name, int value) { eName = name; eValue = value; };
    assert(list && list.length == 2);

    list("1", 1);
    assert(eName == "1" && eValue == 1);
    assert(s1.a == 101);

    list -= &s1.accumulate;
    assert(list && list.length == 1);
    list("2", 2);
    assert(eName == "2" && eValue == 2);
    assert(s1.a == 101);
}