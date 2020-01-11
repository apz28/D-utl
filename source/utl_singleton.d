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

module pham.utl_singleton;

import core.atomic : atomicFence;

@safe:

/** Initialize parameter v if it is null in thread safe manner using pass in initiate function
    Params:
        v = variable to be initialized to object T if it is null
        initiate = a function that returns the newly created object as of T
    Returns:
        parameter v
*/
T singleton(T)(ref T v, T function() @safe initiate)
if (is(T == class))
{
    if (v is null)
    {
        atomicFence();
        synchronized
        {
            if (v is null)
                v = initiate();
        }
    }

    return v;
}
