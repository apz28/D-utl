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

module pham.utl.dlinklist;

nothrow @safe:

template isDLink(T)
if (is(T == class))
{
    static if (__traits(hasMember, T, "_next") && __traits(hasMember, T, "_prev"))
        enum isDLink = true;
    else
        enum isDLink = false;
}

struct DLinkRange(T)
if (isDLink!T)
{
nothrow @safe:

public:
    this(T lastNode)
    {
        this._lastNode = lastNode;
        if (lastNode is null)
            _done = true;
        else
            _nextNode = cast(T)lastNode._next;
    }

    void dispose()
    {
        _lastNode = null;
        _nextNode = null;
        _done = true;
    }

    void popFront() nothrow
    {
        if (_nextNode !is null)
        {
            _nextNode = cast(T)_nextNode._next;
            _done = _nextNode is null || _nextNode is _lastNode;
        }
    }

    @property T front() nothrow
    {
        return _nextNode;
    }

    @property bool empty() const nothrow
    {
        return _done;
    }

private:
    T _lastNode;
    T _nextNode;
    bool _done;
}

pragma (inline, true)
bool dlinkHasPrev(T)(T lastNode, T checkNode) const
if (isDLink!T)
{
    return checkNode !is lastNode._prev;
}

pragma (inline, true)
bool dlinkHasNext(T)(T lastNode, T checkNode) const
if (isDLink!T)
{
    return checkNode !is lastNode._next;
}

T dlinkInsertAfter(T)(T refNode, T newNode)
if (isDLink!T)
in 
{
    assert(refNode !is null);
    assert(refNode._next !is null);
}
do
{
    newNode._next = refNode._next;
    newNode._prev = refNode;
    refNode._next._prev = newNode;
    refNode._next = newNode;
    return newNode;
}

T dlinkInsertEnd(T)(ref T lastNode, T newNode)
if (isDLink!T)
{
    if (lastNode is null)
    {
        newNode._next = newNode;
        newNode._prev = newNode;
    }
    else
        dlinkInsertAfter(lastNode, newNode);
    lastNode = newNode;
    return newNode;
}

T dlinkRemove(T)(ref T lastNode, T oldNode)
if (isDLink!T)
{
    if (oldNode._next is oldNode)
        lastNode = null;
    else
    {
        oldNode._next._prev = oldNode._prev;
        oldNode._prev._next = oldNode._next;
        if (oldNode is lastNode)
            lastNode = cast(T)oldNode._prev;
    }
    oldNode._next = null;
    oldNode._prev = null;
    return oldNode;
}
