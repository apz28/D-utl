/*
 *
 * License: $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: An Pham
 *
 * Copyright An Pham 2020 - xxxx.
 * Distributed under the Boost Software License, Version 1.0.
 * (See accompanying file LICENSE.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
 *
 */

module pham.utl_variant;

import core.lifetime : emplace;
import core.stdc.string : memcpy, memset;
import std.algorithm.comparison : max;
import std.conv : to;
import std.meta;
import std.range.primitives : ElementType;
import std.traits;
import std.typecons;

struct This;

enum VariantType
{
    null_,
    boolean,
    character,
    integer,
    float_,
    enum_,
    string,
    staticArray,
    dynamicArray,
    associativeArray,
    class_,
    interface_,
    struct_,
    union_,
    delegate_,
    function_,
    pointer,
    unknown
}

/**
 * Returns an array of variants constructed from `args`.
 *
 * This is by design. During construction the `Variant` needs
 * static type information about the type being held, so as to store a
 * pointer to function for fast retrieval.
 */
Variant[] variantArray(T...)(T args)
{
    Variant[] result;
    result.reserve(args.length);
    foreach (arg; args)
        result ~= Variant(arg);
    return result;
}

/**
 * Back-end type seldom used directly by user
 * code. Two commonly-used types using `VariantN` are:
 *
 * $(OL $(LI $(LREF Algebraic): A closed discriminated union with a
 * limited type universe (e.g., $(D Algebraic!(int, double, string))
 * only accepts these three types and rejects anything else).)
 * $(LI $(LREF Variant): An open discriminated union allowing an
 * unbounded set of types. If any of the types in the `Variant`
 * are larger than the largest built-in type, they will automatically
 * be boxed. This means that even large types will only be the size
 * of a pointer within the `Variant`, but this also implies some
 * overhead. `Variant` can accommodate all primitive types and
 * all user-defined types.))
 *
 * Both `Algebraic` and `Variant` share $(D VariantN)'s interface.
 * (See their respective documentations below.)
 *
 * `VariantN` is a discriminated union type parameterized
 * with the largest size of the types stored (`MaxDataSize`)
 * and with the list of allowed types (`AllowedTypes`). If
 * the list is empty, then any type up of size up to $(D MaxDataSize)
 * (rounded up for alignment) can be stored in a
 * `VariantN` object without being boxed (types larger than this will be boxed).
 */
struct VariantN(size_t MaxDataSize, AllowedDataTypes...)
{
public:
    /**
     * The list of allowed types. If empty, any type is allowed.
     */
    alias AllowedTypes = This2Variant!(VariantN, AllowedDataTypes);

    /**
     * Tells whether a type `T` is statically allowed for
     * storage inside a `VariantN` object by looking `T` up in `AllowedTypes`.
     */
    template allowed(T)
    {
        enum bool allowed = is(T == VariantN)
            || (AllowedTypes.length == 0
                || staticIndexOf!(T, AllowedTypes) >= 0
                || (staticIndexOf!(Unqual!T, AllowedTypes) >= 0 && (isBasicType!T || !hasIndirections!T)));
    }

    enum bool elaborateConstructor = !AllowedTypes.length
        || anySatisfy!(hasElaborateCopyConstructor, AllowedTypes);

    enum bool elaborateDestructor = !AllowedTypes.length
        || anySatisfy!(hasElaborateDestructor, AllowedTypes);

    enum bool elaborateIndirection = !AllowedTypes.length
        || anySatisfy!(hasIndirections, AllowedTypes)
        || elaborateDestructor;

public:
    /**
     * Constructs a `VariantN` value given an argument of a generic type.
     * Statically rejects disallowed types.
     */
    this(T)(T value) nothrow
    {
        static assert(allowed!T,
            "Cannot store a " ~ T.stringof ~ " in a " ~ VariantN.stringof
            ~ ".\nValid types are " ~ AllowedTypes.stringof);

        doAssign!(T, false)(value);
    }

    /// Allows assignment from a subset algebraic type
    this(T : VariantN!(TypeSize, Types), size_t TypeSize, Types...)(T value) nothrow
    if (!is(T : VariantN) && Types.length > 0 && allSatisfy!(allowed, Types))
    {
        doAssign!(T, false)(value);
    }

    static if (elaborateConstructor)
    this(this) nothrow @safe
    {
        handler.construct(size, pointer);
    }

    static if (elaborateDestructor)
    ~this() nothrow @safe
    {
        if (handler)
        {
            handler.destruct(size, pointer);
            () @trusted { handler = &voidHandler; } ();
        }
    }

    /**
     * If the `VariantN` contains an array, applies `dg` to each
     * element of the array in turn; if `dg` result evaluates to true, it will stop.
     * Otherwise, throw VariantException.
     */
    int opApply(Dg)(scope Dg dg)
    if (is(Dg == delegate) && Parameters!Dg.length != 0)
    {
        alias P = Parameters!Dg;

        static if (Parameters!Dg.length == 2)
        {
            alias E = P[1];
            alias K = P[0];

            // Construct foreach for associative-array
            // double[string] aa; E=double, K=string
            // foreach (string s, double d; v)
        }
        else
            alias E = P[0];

        switch (variantType)
        {
            case VariantType.staticArray:
                static if (P.length == 1)
                if ((cast(TypeInfo_StaticArray)typeInfo).value is typeid(E))
                {
                    auto ar = (cast(E*)handler.valuePointer(size, pointer))[0..length];
                    foreach (ref e; ar)
                        {
                            if (auto r = dg(e))
                                return r;
                        }
                    return 0;
                }
                break;

            case VariantType.dynamicArray:
                static if (P.length == 1)
                if (typeInfo is typeid(E[]))
                {
                    auto ar = doGet!(E[])();
                    foreach (ref e; ar)
                        {
                            if (auto r = dg(e))
                                return r;
                        }
                    return 0;
                }
                break;

            case VariantType.associativeArray:
                static if (P.length == 2)
                if (typeInfo is typeid(E[K]))
                {
                    auto aa = doGet!(E[K])();
                    foreach (K k, ref E v; aa)
                    {
                        if (auto r = dg(k, v))
                            return r;
                    }
                    return 0;
                }
                break;

            default:
                break;
        }

        throw new VariantException(typeInfo, typeInfo.toString() ~ " not supported opApply() for delegate " ~ Dg.stringof);
    }

    /**
     * Assigns a `VariantN` value given an argument of a generic type.
     * Statically rejects disallowed types.
     */
    ref VariantN opAssign(T)(T rhs) nothrow return
    {
        static assert(allowed!T,
            "Cannot store a " ~ T.stringof ~ " in a " ~ VariantN.stringof
            ~ ".\nValid types are " ~ AllowedTypes.stringof);

        doAssign!(T, true)(rhs);
        return this;
    }

    /// Allow assignment from another variant which is a subset of this one
    ref VariantN opAssign(T : VariantN!(TypeSize, Types), size_t TypeSize, Types...)(T rhs) nothrow return
    if (!is(T : VariantN) && Types.length > 0 && allSatisfy!(allowed, Types))
    {
        // discover which typeInfo of rhs is actually storing
        foreach (V; T.AllowedTypes)
        {
            if (rhs.typeInfo is typeid(V))
            {
                doAssign!(V, true)(rhs.doGet!V());
                return this;
            }
        }

        assert(0, T.AllowedTypes.stringof);
    }

    ///ditto
    ref VariantN opOpAssign(string op, T)(T rhs) return @trusted
    if (op == "~")
    {
        static if (is(T == Variant))
            alias appendValue = rhs;
        else
            auto appendValue = Variant(rhs);

        if (!handler.append(size, pointer, &appendValue))
            throw new VariantException(typeInfo, typeid(T), "opOpAssign()");

        return this;
    }

    ///ditto
    ref VariantN opOpAssign(string op, T)(T rhs) nothrow return
    if (op != "~")
    {
        mixin("this = this " ~ op ~ " rhs;");
        return this;
    }

    VariantN opBinary(string op, T)(T rhs) @safe
    if (op == "~")
    {
        auto result = this;
        result ~= rhs;
        return result;
    }

    /**
     * Arithmetic between `VariantN` objects and numeric
     * values. All arithmetic operations return a `VariantN`
     * object typed depending on the types of both values
     * involved. The conversion rules mimic D's built-in rules for
     * arithmetic conversions.
     */
    VariantN opBinary(string op, T)(T rhs) nothrow @safe
    if ((op == "+" || op == "-" || op == "*" || op == "/" || op == "^^" || op == "%")
        && is(typeof(doArithmetic!(op, T)(rhs))))
    {
        return doArithmetic!(op, T)(rhs);
    }

    ///ditto
    VariantN opBinary(string op, T)(T rhs) nothrow @safe
    if ((op == "&" || op == "|" || op == "^" || op == ">>" || op == "<<" || op == ">>>")
        && is(typeof(doLogic!(op, T)(rhs))))
    {
        return doLogic!(op, T)(rhs);
    }

    ///ditto
    VariantN opBinaryRight(string op, T)(T lhs) nothrow @safe
    if ((op == "+" || op == "*" || op == "/" || op == "^^" || op == "%")
        && is(typeof(doArithmetic!(op, T)(lhs))))
    {
        return doArithmetic!(op, T)(lhs);
    }

    ///ditto
    VariantN opBinaryRight(string op, T)(T lhs) nothrow @safe
    if ((op == "&" || op == "|" || op == "^")
        && is(typeof(doLogic!(op, T)(lhs))))
    {
        return doLogic!(op, T)(lhs);
    }

    Variant opCall(P...)(auto ref P params) @trusted
    {
        Variant[P.length] paramVariants;
        foreach (i, _; params)
            paramVariants[i] = params[i];
        Variant result;
        auto r = handler.call(size, pointer, P.length, &paramVariants, &result);
        if (r == 0)
            return result;

        auto errorMessage = typeInfo.toString() ~ " not supported opCall()";
        if (r > 0)
            errorMessage ~= ".\nArgument count mismatch; expects " ~ to!string(r) ~ ", not " ~ to!string(P.length);
        throw new VariantException(typeInfo, errorMessage);
    }

    bool opCast(C: bool)() const nothrow pure @safe
    {
        return handler.boolCast(size, pointer);
    }

    // Temporary hack until bug http://d.puremagic.com/issues/show_bug.cgi?id=5747 is fixed.
    VariantN opCast(T)() const nothrow
    if (is(Unqual!T == VariantN))
    {
        return this;
    }

    /**
     * Ordering comparison used by the "<", "<=", ">", and ">="
     * operators. In case comparison is not sensible between the held
     * value and `rhs`, an float.nan is returned.
     */
    float opCmp(T)(auto ref T rhs) const nothrow @trusted
    if (allowed!T || is(Unqual!T == VariantN))
    {
        static if (is(Unqual!T == VariantN))
        {
            alias trhs = Unqual!T;
            scope prhs = &rhs;
        }
        else
        {
            alias trhs = VariantN;
            auto vrhs = VariantN(rhs);
            scope prhs = &vrhs;
        }

        // Same type without modifier?
        if (handler.typeInfo(false) is prhs.handler.typeInfo(false))
            return handler.cmp(size, pointer, prhs.size, prhs.pointer);

        // Convert rhs to self type?
        VariantN convertedToSelf;
        if (prhs.handler.tryGet(prhs.size, prhs.pointer, convertedToSelf.size, convertedToSelf.pointer, this.typeInfo))
        {
            () nothrow @trusted { convertedToSelf.handler = cast(Handler!void*)handler; } ();
            return handler.cmp(size, pointer, convertedToSelf.size, convertedToSelf.pointer);
        }

        // Convert self to rhs type?
        trhs convertedToRhs;
        if (handler.tryGet(size, pointer, convertedToRhs.size, convertedToRhs.pointer, prhs.typeInfo))
        {
            () nothrow @trusted { convertedToRhs.handler = cast(Handler!void*)prhs.handler; } ();
            return prhs.handler.cmp(convertedToRhs.size, convertedToRhs.pointer, prhs.size, prhs.pointer);
        }

        // Try special cases for array
        static if (isArray!T)
        {
            if (handler.isCompatibleArrayComparison(typeid(Unqual!(ElementType!T))))
                return handler.cmp(size, pointer, prhs.size, prhs.pointer);
        }

        version (assert)
            assert(0, "Cannot do VariantN(" ~ typeInfo.toString() ~ ") opCmp() with " ~ T.stringof);
        else
            return float.nan;
    }

    /**
     * Comparison for equality used by the "==" and "!="  operators.
     * returns true if the two are equal
     */
    bool opEquals(T)(auto ref T rhs) const nothrow @trusted
    if (allowed!T || is(Unqual!T == VariantN))
    {
        static if (is(Unqual!T == VariantN))
        {
            alias trhs = Unqual!T;
            scope prhs = &rhs;
        }
        else
        {
            alias trhs = VariantN;
            auto vrhs = VariantN(rhs);
            scope prhs = &vrhs;
        }

        // Same type without modifier?
        if (handler.typeInfo(false) is prhs.handler.typeInfo(false))
            return handler.equals(size, pointer, prhs.size, prhs.pointer);

        // Convert rhs to self type?
        VariantN convertedToSelf;
        if (prhs.handler.tryGet(prhs.size, prhs.pointer, convertedToSelf.size, convertedToSelf.pointer, this.typeInfo))
        {
            () nothrow @trusted { convertedToSelf.handler = cast(Handler!void*)handler; } ();
            return handler.equals(size, pointer, convertedToSelf.size, convertedToSelf.pointer);
        }

        // Convert self to rhs type?
        trhs convertedToRhs;
        if (handler.tryGet(size, pointer, convertedToRhs.size, convertedToRhs.pointer, prhs.typeInfo))
        {
            () nothrow @trusted { convertedToRhs.handler = cast(Handler!void*)prhs.handler; } ();
            return prhs.handler.equals(convertedToRhs.size, convertedToRhs.pointer, prhs.size, prhs.pointer);
        }

        // Try special cases for array
        static if (isArray!T)
        {
            if (handler.isCompatibleArrayComparison(typeid(Unqual!(ElementType!T))))
                return handler.equals(size, pointer, prhs.size, prhs.pointer);
        }

        version (assert)
            assert(0, "Cannot do VariantN(" ~ typeInfo.toString() ~ ") opEquals() with " ~ T.stringof);
        else
            return false;
    }

    /**
     * Array and associative array operations. If a $(D VariantN)
     * contains an (associative) array, it can be indexed
     * into. Otherwise, a VariantException is thrown.
     */
    inout(Variant) opIndex(I)(I indexOrKey) inout return
    {
        string errorMessage() nothrow pure
        {
            return "Cannot get type " ~ Variant.stringof ~ " from type " ~ VariantN.stringof ~ " with indexed type " ~ I.stringof;
        }

        inout(Variant) result;

        switch (variantType)
        {
            case VariantType.dynamicArray:
            case VariantType.staticArray:
                static if (isIntegral!I)
                if (handler.indexAR(size, pointer, cast(size_t)indexOrKey, cast(void*)&result))
                    return result;
                goto default;

            case VariantType.associativeArray:
                if (handler.indexAA(size, pointer, &indexOrKey, typeid(I), cast(void*)&result))
                    return result;
                goto default;

            default:
                throw new VariantException(typeInfo, errorMessage());
        }
    }

    /// ditto
    T opIndexAssign(T, I)(return T value, I indexOrKey) @trusted
    {
        string errorMessage() nothrow pure
        {
            return "Cannot assign value type " ~ T.stringof ~ " to " ~ VariantN.stringof ~ " with indexed type " ~ I.stringof;
        }

        static if (AllowedTypes.length && !isInstanceOf!(.VariantN, T))
        {
            enum canAssign(U) = __traits(compiles, (U u) { u[indexOrKey] = value; });
            static assert(anySatisfy!(canAssign, AllowedTypes), errorMessage());
        }

        static if (is(T == Variant))
            alias assignValue = value;
        else
            auto assignValue = Variant(value);

        switch (variantType)
        {
            case VariantType.dynamicArray:
            case VariantType.staticArray:
                static if (isIntegral!I)
                {
                    if (handler.indexAssignAR(size, pointer, &assignValue, cast(size_t)indexOrKey))
                        return value;
                }
                break;

            case VariantType.associativeArray:
                static if (is(I == Variant))
                    alias assignKey = indexOrKey;
                else
                    auto assignKey = Variant(indexOrKey);

                if (handler.indexAssignAA(size, pointer, &assignValue, &assignKey))
                    return value;
                break;

            default:
                break;
        }

        throw new VariantException(typeInfo, errorMessage());
    }

    /// ditto
    T opIndexOpAssign(string op, T, I)(return T value, I indexOrKey) @safe
    {
        return opIndexAssign(mixin("opIndex(indexOrKey) " ~ op ~ " value"), indexOrKey);
    }

    /**
     * Returns `true` if and only if the `VariantN`
     * object holds an object implicitly convertible to type `T`.
     * Implicit convertibility is defined as per
     * $(REF_ALTTEXT ImplicitConversionTargets, ImplicitConversionTargets, std.traits).
     */
    bool canGet(T)() inout nothrow @safe
    {
        return handler.tryGet(size, pointer, 0, null, typeid(T));
    }

    /**
     * Returns the value stored in the `VariantN` object,
     * explicitly converted (coerced) to the requested type $(D T).
     * If `T` is a string type, the value is formatted as
     * a string. If the `VariantN` object is a string, a
     * parse of the string to type `T` is attempted. If a
     * conversion is not possible, application terminated.
     */
    T coerce(T)() @trusted
    {
        static if (allowed!T)
        if (auto pv = peek!T())
            return *pv;

        static if (isNumeric!T || isBoolean!T)
        {
            static if (is(typeof(Unqual!T.max) : int))
            if (canGet!int())
                return to!T(doGet!int());

            static if (is(typeof(Unqual!T.max) : uint))
            if (canGet!uint())
                return to!T(doGet!uint());

            static if (is(typeof(Unqual!T.max) : long))
            if (canGet!long())
                return to!T(doGet!long());

            static if (is(typeof(Unqual!T.max) : ulong))
            if (canGet!ulong())
                return to!T(doGet!ulong());

            static if (is(Unqual!T : float))
            if (canGet!float())
                return to!T(doGet!float());

            static if (is(Unqual!T : double))
            if (canGet!double())
                return to!T(doGet!double());

            static if (is(Unqual!T : real))
            if (canGet!real())
                return to!T(doGet!real());

            if (canGet!int())
                return to!T(doGet!int());
            else if (canGet!(const(char)[])())
                return to!T(doGet!(const(char)[])());
            // I'm not sure why this doesn't convert to const(char),
            // but apparently it doesn't (probably a deeper bug).
            // Until that is fixed, this quick addition keeps a common
            // function working. "10".coerce!int ought to work.
            else if (canGet!(immutable(char)[])())
                return to!T(doGet!(immutable(char)[])());
            else
                assert(0, "Unsupported type for coerce: " ~ T.stringof);
        }
        else static if (is(T : Object))
            return to!T(doGet!Object());
        else static if (isSomeString!T)
            return to!T(toString());
        // Fix for bug 1649
        else
            static assert(0, "Unsupported type for coerce: " ~ T.stringof);
    }

    /**
     * Returns the value stored in the `VariantN` object, either by specifying the
     * needed type or the index in the list of allowed types. The latter overload
     * only applies to bounded variants (e.g. $(LREF Algebraic)).
     *
     * Params:
     *   T = The requested type. The currently stored value must implicitly convert
     *   to the requested type, in fact `DecayStaticToDynamicArray!T`. If an
     *   implicit conversion is not possible, throws a `VariantException`.
     *   index = The index of the type among `AllowedDataTypes`, zero-based.
     */
    inout(T) get(T)() inout @trusted
    {
        static if (is(T == Variant))
            return this;
        else
        {
            static if (is(T == shared))
                alias R = shared Unqual!T;
            else
                alias R = Unqual!T;

            inout(T) result = void;
            if (handler.tryGet(size, pointer, T.sizeof, cast(void*)(cast(R*)&result), typeid(T)))
                return result;
            else if (auto pv = peek!T())
                return *pv;
            else
            {
                // Value type will invoke destructor with garbage -> access violation
                static if (hasElaborateDestructor!T)
                memset(cast(R*)&result, 0, T.sizeof);

                throw new VariantException(typeInfo, typeid(T), "get()");
            }
        }
    }

    /// Ditto
    auto get(uint allowTypeIndex)() inout @safe
    if (allowTypeIndex < AllowedTypes.length)
    {
        static foreach (i, T; AllowedTypes)
        {
            static if (allowTypeIndex == i)
                return get!T();
        }

        assert(0);
    }

    ref VariantN nullify() nothrow return @safe
    {
        handler.destruct(size, pointer);
        () nothrow @trusted { handler = &voidHandler; } ();

        return this;
    }

    /**
     * If the `VariantN` object holds a value of the $(I exact) type `T`,
     * returns a pointer to that value. Otherwise, returns `null`.
     * In cases where `T` is statically disallowed, $(D peek) will not compile.
     */
    inout(T)* peek(T)() inout nothrow pure return @trusted
    {
        static if (!is(T == void))
        static assert(allowed!T,
            "Cannot store a " ~ T.stringof ~ " in a " ~ VariantN.stringof
            ~ ".\nValid types are " ~ AllowedTypes.stringof);

        if (typeInfo !is typeid(T))
            return null;
        else
            return cast(inout(T)*)(handler.valuePointer(size, pointer));
    }

    /**
     * Computes the hash of the held value.
     */
    size_t toHash() const nothrow @safe
    {
        return handler.toHash(size, pointer);
    }

    /**
     * Formats the stored value as a string.
     */
    string toString()
    {
        return handler.toString(size, pointer);
    }

    /**
     * Returns true if the value stored in the `VariantN` object can assign to value parameter,
     * either by specifying the needed type or the index in the list of allowed types.
     * The latter overload only applies to bounded variants (e.g. $(LREF Algebraic)).
     * Will return false if implicit conversion is not possible.
     *
     * Params:
     *   T = The requested type (not `const`, `immutable` or `shared`).
     *   The currently stored value must implicitly convert
     *   to the requested type, in fact `DecayStaticToDynamicArray!T`.
     *   index = The index of the type among `AllowedDataTypes`, zero-based.
     *
     *   value = reference storage to get the stored value
     */
    bool tryGet(T)(ref T value) nothrow @trusted
    if (!is(T == const) && !is(T == immutable) && !is(T == shared))
    {
        T tempValue = void;
        if (handler.tryGet(size, pointer, T.sizeof, cast(void*)cast(T*)&tempValue, typeid(T)))
        {
            value = tempValue;
            return true;
        }
        else
        {
            // Value type will invoke destructor with garbage -> access violation
            static if (hasElaborateDestructor!T)
            memset(&tempValue, 0, T.sizeof);

            return false;
        }
    }

    static Variant varNull() nothrow @safe
    {
        return Variant.init;
    }

    /**
     * Returns true if VariantN held value of type void or null
    */
    @property bool isNull() const nothrow pure @safe
    {
        return variantType == VariantType.null_;
    }

    /**
     * Returns true if VariantN held value of type void
     */
    @property bool isVoid() const nothrow pure @safe
    {
        return handler.nullType() == NullType.voidType;
    }

    /**
     * If the `VariantN` contains an array or associativeArray,
     * returns its' length. Otherwise, return 0
     */
    @property size_t length() const nothrow pure @safe
    {
        return handler.length(size, pointer);
    }

    /**
     * Returns the `typeid` of the currently held value.
     */
    @property TypeInfo typeInfo() const nothrow pure @safe
    {
        return handler.typeInfo(true);
    }

    /**
     * Returns the `VariantType` of the currently held value.
     */
    @property VariantType variantType() const nothrow pure @safe
    {
        return handler.variantType();
    }

private:
    VariantN doArithmetic(string op, T)(T other) nothrow @safe
    {
        static if (isInstanceOf!(.VariantN, T))
        {
            string tryUseType(string tp)
            {
                import std.format : format;
                return q{
                    static if (allowed!(%1$s) && T.allowed!(%1$s))
                    if (canGet!(%1$s)() && other.canGet!(%1$s)())
                        return VariantN(doGet!(%1$s)() %2$s other.doGet!(%1$s)());
                }.format(tp, op);
            }

            mixin(tryUseType("int"));
            mixin(tryUseType("uint"));
            mixin(tryUseType("long"));
            mixin(tryUseType("ulong"));
            mixin(tryUseType("float"));
            mixin(tryUseType("double"));
            mixin(tryUseType("real"));
        }
        else
        {
            static if (allowed!T)
            if (auto pv = peek!T())
                return VariantN(mixin("*pv " ~ op ~ " other"));

            static if (allowed!int && is(typeof(T.max) : int) && !isUnsigned!T)
            if (canGet!int)
                return VariantN(mixin("doGet!int() " ~ op ~ " other"));

            static if (allowed!uint && is(typeof(T.max) : uint) && isUnsigned!T)
            if (canGet!uint)
                return VariantN(mixin("doGet!uint() " ~ op ~ " other"));

            static if (allowed!long && is(typeof(T.max) : long) && !isUnsigned!T)
            if (canGet!long)
                return VariantN(mixin("doGet!long() " ~ op ~ " other"));

            static if (allowed!ulong && is(typeof(T.max) : ulong) && isUnsigned!T)
            if (canGet!ulong)
                return VariantN(mixin("doGet!ulong() " ~ op ~ " other"));

            static if (allowed!float && is(T : float))
            if (canGet!float)
                return VariantN(mixin("doGet!float() " ~ op ~ " other"));

            static if (allowed!double && is(T : double))
            if (canGet!double)
                return VariantN(mixin("doGet!double() " ~ op ~ " other"));

            static if (allowed!real && is(T : real))
            if (canGet!real)
                return VariantN(mixin("doGet!real() " ~ op ~ " other"));
        }

        assert(0, "Cannot do VariantN(" ~ AllowedTypes.stringof ~ ") " ~ op ~ " " ~ T.stringof);
    }

    /**
     * Assigns a `VariantN` from a generic argument.
     * Statically rejects disallowed types.
     */
    void doAssign(T, bool Assign)(T rhs) nothrow @trusted
    {
        static if (is(T == void))
        {
            // Assignment must destruct previous value
            static if (Assign)
            handler.destruct(size, pointer);

            handler = &voidHandler;
        }
        else static if (is(T : VariantN))
        {
            // Assignment must destruct previous value
            static if (Assign)
            handler.destruct(size, pointer);

            handler = rhs.handler;
            if (rhs.typeInfo !is typeid(void))
            {
                handler.assignSelf(rhs.size, rhs.pointer, size, pointer);

                // PostBlit after copy
                handler.construct(size, pointer);
            }
        }
        else static if (is(T : const(VariantN)))
            static assert(false, "Unsupport assigning `VariantN` from `const VariantN`");
        else
        {
            // Assignment must destruct previous value
            static if (Assign)
            {
                handler.destruct(size, pointer);
                handler = &voidHandler; // In case of failed initialization
            }

            static if (T.sizeof <= size)
            {
                // rhs has already been copied onto the stack, so even if T is
                // shared, it's not really shared. Therefore, we can safely
                // remove the shared qualifier when copying, as we are only
                // copying from the unshared stack.
                //
                // In addition, the storage location is not accessible outside
                // the Variant, so even if shared data is stored there, it's
                // not really shared, as it's copied out as well.
                memcpy(pointer, cast(const(void*))&rhs, T.sizeof);

                // PostBlit after copy
                static if (hasElaborateCopyConstructor!T)
                (cast(T*)pointer).__xpostblit();
            }
            else
            {
                alias UT = Unqual!T;

                // Exclude compiler generated constructor
                // https://issues.dlang.org/show_bug.cgi?id=21021
                static if (hasMember!(T, "__ctor") && __traits(compiles, { T* _ = new T(T.init); }))
                {
                    T* prhs = new T(rhs);
                    auto rrhs = RefCounted!(T*)(prhs);
                }
                else static if (is(T == U[n], U, size_t n))
                {
                    UT* prhs = cast(UT*)(new U[n]).ptr;
                    *prhs = cast(UT)rhs;
                    auto rrhs = RefCounted!(UT*)(prhs);
                }
                else
                {
                    UT* prhs = new UT;
                    *prhs = cast(UT)rhs;
                    auto rrhs = RefCounted!(UT*)(prhs);
                }

                memcpy(pointer, &rrhs, rrhs.sizeof);

                // PostBlit after copy to increase refcount
                (cast(RefCounted!(T*)*)pointer).__xpostblit();
            }

            handler = cast(Handler!void*)Handler!T.getHandler();
        }
    }

    inout(T) doGet(T)() inout nothrow @trusted
    {
        static if (is(T == shared))
            alias R = shared Unqual!T;
        else
            alias R = Unqual!T;

        inout(T) result = void;
        handler.tryGet(size, pointer, T.sizeof, cast(void*)(cast(R*)&result), typeid(T)) || assert(0);
        return result;
    }

    VariantN doLogic(string op, T)(T other) nothrow @safe
    {
        static if (is(T == VariantN))
        {
            if (canGet!uint() && other.canGet!uint())
                return VariantN(mixin("doGet!uint() " ~ op ~ " other.doGet!uint()"));
            else if (canGet!int() && other.canGet!int())
                return VariantN(mixin("doGet!int() " ~ op ~ " other.doGet!int()"));
            else if (canGet!ulong() && other.canGet!ulong())
                return VariantN(mixin("doGet!ulong() " ~ op ~ " other.doGet!ulong()"));
            else if (canGet!long() && other.canGet!long())
                return VariantN(mixin("doGet!long() " ~ op ~ " other.doGet!long()"));
        }
        else
        {
            if (is(typeof(T.max) : uint) && T.min == 0 && canGet!uint())
                return VariantN(mixin("doGet!uint() " ~ op ~ " other"));
            else if (is(typeof(T.max) : int) && T.min < 0 && canGet!int())
                return VariantN(mixin("doGet!int() " ~ op ~ " other"));
            else if (is(typeof(T.max) : ulong) && T.min == 0 && canGet!ulong())
                return VariantN(mixin("doGet!ulong() " ~ op ~ " other"));
            else if (canGet!long())
                return VariantN(mixin("doGet!long() " ~ op ~ " other"));
        }

        assert(0, "Cannot do VariantN(" ~ AllowedTypes.stringof ~ ") " ~ op ~ " " ~ T.stringof);
    }

    @property void* pointer() const nothrow pure return @trusted
    {
        return cast(void*)&store;
    }

private:
    // Compute the largest practical size from MaxDataSize
    struct SizeChecker
    {
        void* handler;
        ubyte[MaxDataSize] store;
    }
    enum size = SizeChecker.sizeof - (void*).sizeof;

    union
    {
        align(maxAlignment!(AllowedTypes)) ubyte[size] store;

        // Conservatively mark the region as pointers?
        static if (size >= (void*).sizeof && elaborateIndirection)
        void*[size / (void*).sizeof] dummy;
    }

    Handler!void* handler = &voidHandler;
}

/**
 * Gives the `alignof` the largest types given.
 * Default to size_t.alignof if no types given.
 */
template maxAlignment(T...)
{
    enum maxAlignment =
    {
        size_t result;
        static foreach (t; T)
        {
            if (t.alignof > result)
                result = t.alignof;
        }
        return result == 0 ? size_t.alignof : result;
    }();
}

/**
 * Gives the `sizeof` the largest types given.
 */
template maxSize(T...)
{
    enum maxSize =
    {
        size_t result;
        static foreach (t; T)
        {
            if (t.sizeof > result)
                result = t.sizeof;
        }
        return result;
    }();
}

/**
 * Alias for $(LREF VariantN) instantiated with the largest size of `creal`,
 * `char[]`, and `void delegate()`. This ensures that `Variant` is large enough
 * to hold all of D's predefined types unboxed, including all numeric types,
 * pointers, delegates, and class references. You may want to use
 * `VariantN` directly with a different maximum size either for
 * storing larger types unboxed, or for saving memory.
 */
alias Variant = VariantN!(maxSize!(RealComplex, char[], void delegate()));

/**
 * Algebraic data type restricted to a closed set of possible
 * types. It's an alias for $(LREF VariantN) with an
 * appropriately-constructed maximum size. `Algebraic` is
 * useful when it is desirable to restrict what a discriminated type
 * could hold to the end of defining simpler and more efficient
 * manipulation.
 */
template Algebraic(T...)
{
    alias Algebraic = VariantN!(maxSize!T, T);
}

/**
 * Applies a delegate or function to the given $(LREF Algebraic) depending on the held type,
 * ensuring that all types are handled by the visiting functions.
 *
 * The delegate or function having the currently held value as parameter is called
 * with `variant`'s current value. Visiting handlers are passed
 * in the template parameter list.
 * It is statically ensured that all held types of
 * `variant` are handled across all handlers.
 * `visit` allows delegates and static functions to be passed
 * as parameters.
 *
 * If a function with an untyped parameter is specified, this function is called
 * when the variant contains a type that does not match any other function.
 * This can be used to apply the same function across multiple possible types.
 * Exactly one generic function is allowed.
 *
 * If a function without parameters is specified, this function is called
 * when `variant` doesn't hold a value. Exactly one parameter-less function
 * is allowed.
 *
 * Duplicate overloads matching the same type in one of the visitors are disallowed.
 *
 * Returns: The return type of visit is deduced from the visiting functions and must be
 * the same across all overloads.
 * Throws: $(LREF VariantException) if `variant` doesn't hold a value and no
 * parameter-less fallback function is specified.
 */
template visit(Handlers...)
if (Handlers.length > 0)
{
    auto visit(T)(T variant)
    if (isAlgebraic!T)
    {
        return visitImpl!(true, T, Handlers)(variant);
    }
}

/**
 * Behaves as $(LREF visit) but doesn't enforce that all types are handled
 * by the visiting functions.
 *
 * If a parameter-less function is specified it is called when
 * either `variant` doesn't hold a value or holds a type
 * which isn't handled by the visiting functions.
 *
 * Returns: The return type of tryVisit is deduced from the visiting functions and must be
 * the same across all overloads.
 * Throws: $(LREF VariantException) if `variant` doesn't hold a value or
 * `variant` holds a value which isn't handled by the visiting functions,
 * when no parameter-less fallback function is specified.
 */
template tryVisit(Handlers...)
if (Handlers.length > 0)
{
    auto tryVisit(T)(T variant)
    if (isAlgebraic!T)
    {
        return visitImpl!(false, T, Handlers)(variant);
    }
}

/**
 * Thrown `VariantException` if a `Variant` function call does not supported
 *
 * Uninitialized `Variant` object is used in any way except assignment or checking.
 * `get` is attempted with an incompatible target type.
 * Comparison between `Variant` objects of incompatible types.
 */
class VariantException : Exception
{
public:
    /// The source type in the conversion or comparison
    TypeInfo source;
    /// The target type in the conversion or comparison
    TypeInfo target;

    version (none)
    this(string s, Exception next = null) nothrow @safe
    {
        super(s, next);
    }

    this(TypeInfo source, TypeInfo target, string operation, Exception next = null) nothrow @safe
    {
        auto s = "Unsupport Variant." ~ operation ~
            " with incompatible type " ~ source.toString() ~" and " ~ target.toString();
        if (next !is null)
            s ~= ".\n" ~ next.msg;
        super(s, next);
        this.source = source;
        this.target = target;
    }

    this(TypeInfo source, string message, Exception next = null) nothrow @safe
    {
        auto s = message;
        if (next !is null)
            s ~= ".\n" ~ next.msg;
        super(s, next);
        this.source = source;
    }
}


// All implement after this point must be private
private:

enum NullType { no, voidType, nullType }

struct Handler(T)
{
public:
    static if (is(T == shared))
        alias R = shared Unqual!T;
    else
        alias R = Unqual!T;

    static Handler* getHandler() nothrow @trusted
    {
        static if (is(T == void))
            return &voidHandler;
        else
            return cast(Handler*)&hHandler;
    }
    private static shared Handler hHandler;

public:
    bool function(size_t size, scope void* store, scope void* value) @trusted append = &hAppend;
    void function(size_t srcSize, scope void* srcStore,
        size_t dstSize, scope void* dstStore) nothrow @safe assignSelf = &hAssignSelf;
    bool function(size_t size, scope void* store) nothrow pure @safe boolCast = &hBoolCast;
    int function(size_t size, scope void* store,
        size_t pLength, scope void* pValues, scope void* result) @trusted call = &hCall;
    float function(size_t lhsSize, scope void* lhsStore,
        size_t rhsSize, scope void* rhsStore) nothrow @safe cmp = &hCmp;
    void function(size_t size, scope void* store) nothrow @safe construct = &hConstruct;
    void function(size_t size, scope void* store) nothrow @safe destruct = &hDestruct;
    bool function(size_t lhsSize, scope void* lhsStore,
        size_t rhsSize, scope void* rhsStore) nothrow @safe equals = &hEquals;
    bool function(size_t size, scope void* store, scope void* key, scope TypeInfo keyTypeInfo,
        void* value) nothrow @trusted indexAA = &hIndexAA;
    bool function(size_t size, scope void* store, size_t index,
        void* value) nothrow @trusted indexAR = &hIndexAR;
    bool function(size_t size, scope void* store,
        scope void* value, scope void* key) @trusted indexAssignAA = &hIndexAssignAA;
    bool function(size_t size, scope void* store,
        scope void* value, size_t index) @trusted indexAssignAR = &hIndexAssignAR;
    bool function(TypeInfo unqualifiedRhsValue) nothrow pure @safe isCompatibleArrayComparison = &hIsCompatibleArrayComparison;
    size_t function(size_t size, scope void* store) nothrow pure @safe length = &hLength;
    NullType function() nothrow pure @safe nullType = &hNullType;
    size_t function(size_t size, scope void* store) nothrow @safe toHash = &hToHash;
    string function(size_t size, scope void* store) toString = &hToString;
    bool function(size_t srcSize, scope void* srcStore,
        size_t dstSize, scope void* dst, scope TypeInfo dstTypeInfo) nothrow @safe tryGet = &hTryGet;
    TypeInfo function(bool asIs) nothrow pure @safe typeInfo = &hTypeInfo;
    T* function(size_t size, return void* store) nothrow pure @trusted valuePointer = &hValuePointer;
    VariantType function() nothrow pure @safe variantType = &hVariantType;

private:
    static bool hAppend(size_t size, scope void* store, scope void* value) @trusted
    {
        auto v = hValuePointer(size, store);

        static if (!is(Unqual!(typeof((*v)[0])) == void)
                   && is(typeof((*v)[0])) && is(typeof((*v) ~= *v)))
        {
            alias E = typeof((*v)[0]);

            // Append one element to the array?
            if ((cast(Variant*)value)[0].canGet!E())
                (*v) ~= [(cast(Variant*)value).get!E()];
            else
                // append a whole array to the array
                (*v) ~= (cast(Variant*)value).get!T();

            return true;
        }
        else
            return false;
    }

    static void hAssignSelf(size_t srcSize, scope void* srcStore,
        size_t dstSize, scope void* dstStore) nothrow @trusted
    {
        // Should handle by the caller
        static if (is(T == void))
            assert(0);
        else
        {
            if (T.sizeof > dstSize)
                allocate(dstStore);

            tryPut(hValuePointer(srcSize, srcStore), T.sizeof, cast(void*)hValuePointer(dstSize, dstStore), typeid(T)) || assert(0);
        }
    }

    static bool hBoolCast(size_t size, scope void* store) nothrow pure @trusted
    {
        static if (is(T == void) || typeid(T) is typeid(null))
            return false;
        else static if (isArray!T || isAssociativeArray!T)
            return hValuePointer(size, store).length != 0;
        else static if (isIntegral!T)
            return *hValuePointer(size, store) != 0;
        else static if (isFloatingPoint!T)
            return *hValuePointer(size, store) != 0.0;
        else static if (is(T == bool))
            return *hValuePointer(size, store);
        else static if (isSomeChar!T)
        {
            auto v = hValuePointer(size, store);
            return !(*v == 0 || *v == T.init); // T.init = 0xFF... which is invalid
        }
        else static if (isPointer!T)
            return *hValuePointer(size, store) != null;
        else static if (__traits(compiles, { bool c = (*hValuePointer(size, store)).opCast!bool(); }))
            return (*hValuePointer(size, store)).opCast!bool();
        else
            return true;
    }

    static int hCall(size_t size, scope void* store,
        size_t pLength, scope void* pValues, scope void* result) @trusted
    {
        static if (!isFunctionPointer!T && !isDelegate!T)
            return -1;
        else
        {
            alias ParamTypes = Parameters!T;
            auto paramValues = cast(Variant*)pValues;

            // To assign the tuple we need to use the unqualified version,
            // otherwise we run into issues such as with const values.
            // We still get the actual type from the Variant though
            // to ensure that we retain const correctness.
            Tuple!(staticMap!(Unqual, ParamTypes)) argTuples;
            if (argTuples.length != pLength)
                return cast(int)argTuples.length;

            foreach (i, A; ParamTypes)
                argTuples[i] = cast()paramValues[i].get!A();

            auto v = hValuePointer(size, store);
            auto args = cast(Tuple!(ParamTypes))argTuples;
            static if (is(ReturnType!T == void))
                (*v)(args.expand);
            else
                *(cast(Variant*)result) = (*v)(args.expand);

            return 0;
        }
    }

    static float hCmp(size_t lhsSize, scope void* lhsStore,
        size_t rhsSize, scope void* rhsStore) nothrow @trusted
    {
        scope (failure)
            assert(0);

        static if (is(T == void))
        {
            return 0;
        }
        else
        {
            auto vlhs = hValuePointer(lhsSize, lhsStore);
            auto vrhs = hValuePointer(rhsSize, rhsStore);

            static if (is(typeof(*vlhs == *vrhs)))
            {
                if (*vlhs == *vrhs)
                    return 0;
            }

            static if (is(typeof(*vlhs < *vrhs)))
            {
                if (*vlhs < *vrhs)
                    return -1;
                else if (*vlhs > *vrhs)
                    return 1;
            }

            version (assert)
                assert(0, typeid(T).toString() ~ ".opCmp()?");
            else
                return float.nan;
        }
    }

    static void hConstruct(size_t size, scope void* store) nothrow @trusted
    {
        static if (hasElaborateCopyConstructor!T)
        {
            if (T.sizeof > size)
                (cast(RefCounted!(T*)*)store).__xpostblit();
            else
                hValuePointer(size, store).__xpostblit();
        }
    }

    static void hDestruct(size_t size, scope void* store) nothrow @trusted
    {
        static if (hasElaborateDestructor!T)
        {
            if (T.sizeof > size)
                (cast(RefCounted!(T*)*)store).__xdtor();
            else
                hValuePointer(size, store).__xdtor();
        }

        // Because of conservatively mark the storage as pointers
        // need to reset to help garbage collect avoid false positive
        () nothrow @trusted { memset(store, 0, size); } ();
    }

    static bool hEquals(size_t lhsSize, scope void* lhsStore,
        size_t rhsSize, scope void* rhsStore) nothrow @trusted
    {
        scope (failure)
            assert(0);

        static if (is(T == void))
        {
            return true;
        }
        else
        {
            auto vlhs = hValuePointer(lhsSize, lhsStore);
            auto vrhs = hValuePointer(rhsSize, rhsStore);

            static if (is(typeof(*vlhs == *vrhs)))
                return *vlhs == *vrhs;
            else
            {
                version (assert)
                    assert(0, typeid(T).toString() ~ ".opEquals()?");
                else
                    return false;
            }
        }
    }

    static bool hIndexAA(size_t size, scope void* store,
        scope void* key, scope TypeInfo keyTypeInfo, void* value) nothrow @trusted
    {
        static if (isAssociativeArray!T)
        {
            if (typeid(T).key is keyTypeInfo)
            {
                auto v = hValuePointer(size, store);
                *(cast(Variant*)value) = (*v)[*(cast(typeof(T.init.keys[0])*)key)];
                return true;
            }
            else
                return false;
        }
        else
            return false;
    }

    static bool hIndexAR(size_t size, scope void* store, size_t index,
        void* value) nothrow @trusted
    {
        static if (isArray!T && !is(Unqual!(typeof(T.init[0])) == void))
        {
            auto v = hValuePointer(size, store);
            *(cast(Variant*)value) = Variant((*v)[index]);
            return true;
        }
        else
            return false;
    }

    static bool hIndexAssignAA(size_t size, scope void* store,
        scope void* value, scope void* key) @trusted
    {
        static if (isAssociativeArray!T)
        {
            auto v = hValuePointer(size, store);
            (*v)[(cast(Variant*)key).get!(typeof(T.init.keys[0]))] = (cast(Variant*)value).get!(typeof(T.init.values[0]));
            return true;
        }
        else
            return false;
    }

    static bool hIndexAssignAR(size_t size, scope void* store,
        scope void* value, size_t index) @trusted
    {
        auto v = hValuePointer(size, store);
        static if (isArray!T && is(typeof((*v)[0] = (*v)[0])))
        {
            (*v)[index] = (cast(Variant*)value).get!(typeof((*v)[0]));
            return true;
        }
        else
            return false;
    }

    static bool hIsCompatibleArrayComparison(TypeInfo unqualifiedRhsValue) nothrow pure @safe
    {
        static if (isArray!T)
        {
            return typeid(Unqual!(ElementType!(T))) is unqualifiedRhsValue;
        }
        else
            return false;
    }

    static size_t hLength(size_t size, scope void* store) nothrow pure @safe
    {
        static if (isArray!T || isAssociativeArray!T)
            return hValuePointer(size, store).length;
        else
            return 0;
    }

    static NullType hNullType() nothrow pure @safe
    {
        static if (is(T == void))
            return NullType.voidType;
        else static if (typeid(T) is typeid(null))
            return NullType.nullType;
        else
            return NullType.no;
    }

    static size_t hToHash(size_t size, scope void* store) nothrow @safe
    {
        static if (is(T == void) || typeid(T) is typeid(null))
            return typeid(T).getHash(store);
        else
        {
            auto v = hValuePointer(size, store);

            static if (__traits(compiles, { size_t h = (*v).toHash(); }))
                return (*v).toHash();
            else
                return typeid(T).getHash(store);
        }
    }

    static string hToString(size_t size, scope void* store)
    {
        static if (is(T == void) || typeid(T) is typeid(null))
            return null;
        else
        {
            auto v = hValuePointer(size, store);

            static if (__traits(compiles, { string s = (*v).toString(); }))
                return (*v).toString();
            else static if (is(typeof(to!string(*v))))
                return to!string(*v);
            else
            {
                version (assert)
                    assert(0, typeid(T).toString() ~ ".toString()?");

                return null;
            }
        }
    }

    static bool hTryGet(size_t srcSize, scope void* srcStore,
        size_t dstSize, scope void* dst, scope TypeInfo dstTypeInfo) nothrow @trusted
    {
        static if (is(T == void))
            return false;
        else
            return tryPut(hValuePointer(srcSize, srcStore), dstSize, dst, dstTypeInfo);
    }

    static TypeInfo hTypeInfo(bool asIs) nothrow pure @safe
    {
        return asIs ? typeid(T) : typeid(Unqual!T);
    }

    static T* hValuePointer(size_t size, return void* store) nothrow pure @trusted
    {
        if (store)
        {
            if (T.sizeof <= size)
                return cast(T*)store;
            else
                return (cast(RefCounted!(T*)*)store).refCountedPayload;
        }
        else
            return null;
    }

    static VariantType hVariantType() nothrow pure @safe
    {
        static if (is(T == void) || typeid(T) is typeid(null))
            return VariantType.null_;
        else static if (is(T == enum))
            return VariantType.enum_;
        else static if (is(T == class))
            return VariantType.class_;
        else static if (is(T == interface))
            return VariantType.interface_;
        else static if (is(T == struct))
            return VariantType.struct_;
        else static if (is(T == union))
            return VariantType.union_;
        else static if (isFloatingPoint!T)
            return VariantType.float_;
        else static if (isIntegral!T)
            return VariantType.integer;
        else static if (isSomeChar!T)
            return VariantType.character;
        else static if (isBoolean!T)
            return VariantType.boolean;
        else static if (isSomeString!T)
            return VariantType.string;
        else static if (isAssociativeArray!T)
            return VariantType.associativeArray;
        else static if (isStaticArray!T)
            return VariantType.staticArray;
        else static if (isDynamicArray!T)
            return VariantType.dynamicArray;
        else static if (isDelegate!T)
            return VariantType.delegate_;
        else static if (isFunctionPointer!T)
            return VariantType.function_;
        else static if (isPointer!T) // Generic check must be last
            return VariantType.pointer;
        else
            return VariantType.unknown;
    }

private:
    static void allocate(scope void* dstStore) nothrow
    {
        //alias UT = Unqual!T;

        /*
        static if (__traits(compiles, { T* _ = new T(T.init); }))
        {
            T* prhs = new T(T.init);
            auto rrhs = RefCounted!(T*)(prhs);
        }
        else */
        static if (is(T == U[n], U, size_t n))
        {
            T* prhs = cast(T*)(new U[n]).ptr;
            auto rrhs = RefCounted!(T*)(prhs);
        }
        else static if (__traits(compiles, { T* _ = new T; }))
        {
            T* prhs = new T;
            auto rrhs = RefCounted!(T*)(prhs);
        }
        else
        {
            T* prhs = null;
            auto rrhs = null;
        }

        if (prhs !is null)
        {
            memcpy(dstStore, &rrhs, rrhs.sizeof);

            // PostBlit after copy to increase refcount
            (cast(RefCounted!(T*)*)dstStore).__xpostblit();
        }
    }

    static bool tryPut(scope T* src, size_t dstSize, scope void* dst, scope TypeInfo dstTypeInfo) nothrow
    {
        alias UT = Unqual!T;
        alias AllTypes = AssignableTypes!T;

        foreach (dstT; AllTypes)
        {
            if (typeid(dstT) !is dstTypeInfo)
                continue;

            // SPECIAL NOTE: variant only will ever create a new value with
            // tryPut (effectively), and T is always the same type of
            // dstType, but with different modifiers (and a limited set of
            // implicit targets). So this checks to see if we can construct
            // a T from dstType, knowing that prerequisite. This handles issues
            // where the type contains some constant data aside from the
            // modifiers on the type itself.
            static if (is(typeof(delegate dstT() { return *src; }))
                || is(dstT == const(U), U)
                || is(dstT == shared(U), U)
                || is(dstT == shared const(U), U)
                || is(dstT == immutable(U), U))
            {
                if (src)
                {
                    // Just checking if convertible?
                    if (dst is null)
                        return true;

                    auto emplaceDst = dst;
                    if (T.sizeof > dstSize)
                    {
                        allocate(dst);
                        emplaceDst = cast(void*)hValuePointer(dstSize, dst);
                    }

                    static if (isStaticArray!T && isDynamicArray!dstT)
                        emplace(cast(Unqual!dstT*)emplaceDst, cast(Unqual!dstT)((*src)[]));
                    else static if (!is(Unqual!dstT == void))
                        emplace(cast(Unqual!dstT*)emplaceDst, *cast(UT*)src);
                }

                return true;
            }
            else
            {
                // type T is not constructible from src
                assert(0, dstT.stringof);
            }
        }

        return false;
    }
}

__gshared Handler!void voidHandler;

// Avoid import std.complex
struct RealComplex
{
    real re, im;
}

template AssignableTypes(T)
{
    alias UT = Unqual!T;
    static if (isArray!T && is(typeof(UT.init[0])))
        alias MutableTypes = AliasSeq!(UT, typeof(UT.init[0])[], ImplicitConversionTargets!UT);
    else
        alias MutableTypes = AliasSeq!(UT, ImplicitConversionTargets!UT);
    alias ConstTypes = staticMap!(ConstOf, MutableTypes);
    alias SharedTypes = staticMap!(SharedOf, MutableTypes);
    alias SharedConstTypes = staticMap!(SharedConstOf, MutableTypes);
    alias ImmutableTypes = staticMap!(ImmutableOf, MutableTypes);

    // Basic value types can convert to all types
    static if (isBasicType!T && !isPointer!T)
    {
        alias AssignableTypes = AliasSeq!(ImmutableTypes, ConstTypes, SharedConstTypes, SharedTypes, MutableTypes);
    }
    else static if (is(T == immutable))
    {
        alias AssignableTypes = AliasSeq!(ImmutableTypes, ConstTypes, SharedConstTypes);
    }
    else static if (is(T == shared))
    {
        static if (is(T == const))
            alias AssignableTypes = SharedConstTypes;
        else
            alias AssignableTypes = AliasSeq!(SharedConstTypes, SharedTypes);
    }
    else
    {
        static if (is(T == const))
            alias AssignableTypes = ConstTypes;
        else
            alias AssignableTypes = AliasSeq!(ConstTypes, MutableTypes);
    }
}

template isAlgebraic(Type)
{
    static if (is(Type v == VariantN!T, T...))
        enum isAlgebraic = T.length >= 2;
    else
        enum isAlgebraic = false;
}

template MutableOf(T)
{
    alias MutableOf = Unqual!T;
}

auto visitImpl(bool Strict, VariantType, Handler...)(VariantType variant)
if (isAlgebraic!VariantType && Handler.length > 0)
{
    alias AllowedTypes = VariantType.AllowedTypes;

    /**
     * Returns: Struct where `indices` is an array which
     * contains at the n-th position the index in Handler which takes the
     * n-th type of AllowedTypes. If an Handler doesn't match an
     * AllowedType, -1 is set. If a function in the delegates doesn't
     * have parameters, the field `exceptionFuncIdx` is set;
     * otherwise it's -1.
     */
    auto visitGetOverloadMap()
    {
        struct Result
        {
            int[AllowedTypes.length] indices;
            int exceptionFuncIdx = -1;
            int generalFuncIdx = -1;
        }

        Result result;

        foreach (tidx, T; AllowedTypes)
        {
            bool added = false;
            foreach (dgidx, dg; Handler)
            {
                // Handle normal function objects
                static if (isSomeFunction!dg)
                {
                    alias Params = Parameters!dg;
                    static if (Params.length == 0)
                    {
                        // Just check exception functions in the first
                        // inner iteration (over delegates)
                        if (tidx > 0)
                            continue;
                        else if (result.exceptionFuncIdx >= 0)
                            assert(0, "Duplicate parameter-less (error-)function specified");
                        else
                            result.exceptionFuncIdx = dgidx;
                    }
                    else static if (is(Params[0] == T) || is(Unqual!(Params[0]) == T))
                    {
                        if (added)
                            assert(0, "Duplicate overload specified for type '" ~ T.stringof ~ "'");

                        added = true;
                        result.indices[tidx] = dgidx;
                    }
                }
                else static if (isSomeFunction!(dg!T))
                {
                    assert(result.generalFuncIdx < 0 || result.generalFuncIdx == dgidx,
                        "Only one generic visitor function is allowed");

                    result.generalFuncIdx = dgidx;
                }
                // Handle composite visitors with opCall overloads
                else
                {
                    static assert(0, dg.stringof ~ " is not a function or delegate");
                }
            }

            if (!added)
                result.indices[tidx] = -1;
        }

        return result;
    }

    enum overloadMap = visitGetOverloadMap();

    if (variant.isVoid)
    {
        // Call the exception function. The HandlerOverloadMap
        // will have its exceptionFuncIdx field set to value != -1 if an
        // exception function has been specified; otherwise we just through an exception.
        static if (overloadMap.exceptionFuncIdx >= 0)
            return Handler[overloadMap.exceptionFuncIdx]();
        else
            throw new VariantException(typeid(void), "Unable to call visit()");
    }

    foreach (idx, T; AllowedTypes)
    {
        if (auto pv = variant.peek!T)
        {
            enum dgIdx = overloadMap.indices[idx];

            static if (dgIdx >= 0)
            {
                return Handler[dgIdx](*pv);
            }
            else
            {
                static if (overloadMap.generalFuncIdx >= 0)
                    return Handler[overloadMap.generalFuncIdx](*pv);
                else static if (Strict)
                    static assert(0, "Overload for type '" ~ T.stringof ~ "' hasn't been specified");
                else static if (overloadMap.exceptionFuncIdx >= 0)
                    return Handler[overloadMap.exceptionFuncIdx]();
                else
                    throw new VariantException(typeid(T), "Unable to call visit()");
            }
        }
    }

    assert(0);
}

alias This2Variant(V, T...) = AliasSeq!(ReplaceTypeUnless!(isAlgebraic, This, V, T));

nothrow @safe unittest // maxAlignment
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.maxAlignment");

    static assert(maxAlignment!(int, long) == long.alignof);
    static assert(maxAlignment!(bool, byte) == 1);

    struct S { int a, b, c; }
    static assert(maxAlignment!(bool, long, S) == long.alignof);
}

nothrow @safe unittest // maxSize
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.maxSize");

    static assert(maxSize!(int, long) == long.sizeof);
    static assert(maxSize!(bool, byte) == 1);

    struct S { int a, b, c; }
    static assert(maxSize!(bool, long, S) == S.sizeof);
}

nothrow @safe version (unittest)
{
    auto globalHInt()
    {
        return Handler!int.getHandler();
    }

    auto globalHString()
    {
        return Handler!string.getHandler();
    }

    auto globalHVoid() @trusted
    {
        return &voidHandler;
    }
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Handler.getHandler");

    auto hVoid = Handler!void.getHandler();
    assert(hVoid is globalHVoid);
    assert(hVoid.typeInfo(true) is typeid(void));
    assert(hVoid.variantType() == VariantType.null_);

    auto hInt = Handler!int.getHandler();
    assert(hInt is globalHInt);
    assert(hInt.typeInfo(true) is typeid(int));
    assert(hInt.variantType() == VariantType.integer);

    auto hString = Handler!string.getHandler();
    assert(hString is globalHString);
    assert(hString.typeInfo(true) is typeid(string));
    assert(hString.variantType() == VariantType.string);

    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
    {
        {
            auto ht = Handler!T.getHandler();
            assert(ht.typeInfo(true) is typeid(T));
            assert(ht.variantType() == VariantType.integer);
        }

        // Static array
        {
            auto hsa = Handler!(T[1]).getHandler();
            assert(hsa.typeInfo(true) is typeid(T[1]));
            assert(hsa.variantType() == VariantType.staticArray);
        }

        // Dynamic array
        {
            auto hda = Handler!(T[]).getHandler();
            assert(hda.typeInfo(true) is typeid(T[]));
            assert(hda.variantType() == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            auto haa = Handler!(T[T]).getHandler();
            assert(haa.typeInfo(true) is typeid(T[T]));
            assert(haa.variantType() == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(float, double, real))
    {
        {
            auto ht = Handler!T.getHandler();
            assert(ht.typeInfo(true) is typeid(T));
            assert(ht.variantType() == VariantType.float_);
        }

        // Static array
        {
            auto hsa = Handler!(T[1]).getHandler();
            assert(hsa.typeInfo(true) is typeid(T[1]));
            assert(hsa.variantType() == VariantType.staticArray);
        }

        // Dynamic array
        {
            auto hda = Handler!(T[]).getHandler();
            assert(hda.typeInfo(true) is typeid(T[]));
            assert(hda.variantType() == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            auto haa = Handler!(T[T]).getHandler();
            assert(haa.typeInfo(true) is typeid(T[T]));
            assert(haa.variantType() == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(char, wchar, dchar))
    {
        {
            auto ht = Handler!T.getHandler();
            assert(ht.typeInfo(true) is typeid(T));
            assert(ht.variantType() == VariantType.character);
        }

        // Static array
        {
            auto hsa = Handler!(T[1]).getHandler();
            assert(hsa.typeInfo(true) is typeid(T[1]));
            assert(hsa.variantType() == VariantType.staticArray);
        }

        // Dynamic array - it is string type of char...
        {
            auto hda = Handler!(T[]).getHandler();
            assert(hda.typeInfo(true) is typeid(T[]));
            assert(hda.variantType() == VariantType.string);
        }

        // AssociativeArray
        {
            auto haa = Handler!(T[T]).getHandler();
            assert(haa.typeInfo(true) is typeid(T[T]));
            assert(haa.variantType() == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(string, wstring, dstring))
    {
        {
            auto ht = Handler!T.getHandler();
            assert(ht.typeInfo(true) is typeid(T));
            assert(ht.variantType() == VariantType.string);
        }

        // Static array
        {
            auto hsa = Handler!(T[1]).getHandler();
            assert(hsa.typeInfo(true) is typeid(T[1]));
            assert(hsa.variantType() == VariantType.staticArray);
        }

        // Dynamic array
        {
            auto hda = Handler!(T[]).getHandler();
            assert(hda.typeInfo(true) is typeid(T[]));
            assert(hda.variantType() == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            auto haa = Handler!(T[T]).getHandler();
            assert(haa.typeInfo(true) is typeid(T[T]));
            assert(haa.variantType() == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(bool))
    {
        {
            auto ht = Handler!T.getHandler();
            assert(ht.typeInfo(true) is typeid(T));
            assert(ht.variantType() == VariantType.boolean);
        }

        // Static array
        {
            auto hsa = Handler!(T[1]).getHandler();
            assert(hsa.typeInfo(true) is typeid(T[1]));
            assert(hsa.variantType() == VariantType.staticArray);
        }

        // Dynamic array
        {
            auto hda = Handler!(T[]).getHandler();
            assert(hda.typeInfo(true) is typeid(T[]));
            assert(hda.variantType() == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            auto haa = Handler!(T[T]).getHandler();
            assert(haa.typeInfo(true) is typeid(T[T]));
            assert(haa.variantType() == VariantType.associativeArray);
        }
    }

    enum E { a, b }
    auto hE = Handler!E.getHandler();
    assert(hE.typeInfo(true) is typeid(E));
    assert(hE.variantType() == VariantType.enum_);

    enum EI : int { a = 1, b = 100 }
    auto hEI = Handler!EI.getHandler();
    assert(hEI.typeInfo(true) is typeid(EI));
    assert(hEI.variantType() == VariantType.enum_);

    static struct S { int i; }
    auto hS = Handler!S.getHandler();
    assert(hS.typeInfo(true) is typeid(S));
    assert(hS.variantType() == VariantType.struct_);

    static union U { int i; string s; }
    auto hU = Handler!U.getHandler();
    assert(hU.typeInfo(true) is typeid(U));
    assert(hU.variantType() == VariantType.union_);

    static class C { long d; }
    auto hC = Handler!C.getHandler();
    assert(hC.typeInfo(true) is typeid(C));
    assert(hC.variantType() == VariantType.class_);

    interface I { void f(); }
    auto hI = Handler!I.getHandler();
    assert(hI.typeInfo(true) is typeid(I));
    assert(hI.variantType() == VariantType.interface_);

    auto hP = Handler!(void*).getHandler();
    assert(hP.typeInfo(true) is typeid(void*));
    assert(hP.variantType() == VariantType.pointer);

    int dlg() { return 2; }
    auto hDlg = Handler!(typeof(&dlg)).getHandler();
    assert(hDlg.typeInfo(true) is typeid(typeof(&dlg)));
    assert(hDlg.variantType() == VariantType.delegate_);

    static int fct() { return 1; }
    auto hFct = Handler!(typeof(&fct)).getHandler();
    assert(hFct.typeInfo(true) is typeid(typeof(&fct)));
    assert(hFct.variantType() == VariantType.function_);
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.typeInfo");

    //dgWriteln("Variant.sizeof: ", Variant.sizeof, ", ", Variant.size);
    //32 bits: 24, 20
    //64 bits: 32, 24

    Variant vVoid;
    assert(vVoid.typeInfo is typeid(void));
    assert(vVoid.variantType == VariantType.null_);

    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
    {
        {
            Variant vt = T.init;
            assert(vt.typeInfo is typeid(T));
            assert(vt.variantType == VariantType.integer);
        }

        // Static array
        {
            Variant vsa = T[1].init;
            assert(vsa.typeInfo() is typeid(T[1]));
            assert(vsa.variantType == VariantType.staticArray);
        }

        // Dynamic array
        {
            Variant vda = T[].init;
            assert(vda.typeInfo() is typeid(T[]));
            assert(vda.variantType == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            Variant vaa = T[T].init;
            assert(vaa.typeInfo() is typeid(T[T]));
            assert(vaa.variantType == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(float, double, real))
    {
        {
            Variant vt = T.init;
            assert(vt.typeInfo is typeid(T));
            assert(vt.variantType == VariantType.float_);
        }

        // Static array
        {
            Variant vsa = T[1].init;
            assert(vsa.typeInfo() is typeid(T[1]));
            assert(vsa.variantType == VariantType.staticArray);
        }

        // Dynamic array
        {
            Variant vda = T[].init;
            assert(vda.typeInfo() is typeid(T[]));
            assert(vda.variantType == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            Variant vaa = T[T].init;
            assert(vaa.typeInfo() is typeid(T[T]));
            assert(vaa.variantType == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(char, wchar, dchar))
    {
        {
            Variant vt = T.init;
            assert(vt.typeInfo is typeid(T));
            assert(vt.variantType == VariantType.character);
        }

        // Static array
        {
            Variant vsa = T[1].init;
            assert(vsa.typeInfo() is typeid(T[1]));
            assert(vsa.variantType == VariantType.staticArray);
        }

        // Dynamic array - it is string type of char...
        {
            Variant vda = T[].init;
            assert(vda.typeInfo() is typeid(T[]));
            assert(vda.variantType == VariantType.string);
        }

        // AssociativeArray
        {
            Variant vaa = T[T].init;
            assert(vaa.typeInfo() is typeid(T[T]));
            assert(vaa.variantType == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(string, wstring, dstring))
    {
        {
            Variant vt = T.init;
            assert(vt.typeInfo is typeid(T));
            assert(vt.variantType == VariantType.string);
        }

        // Static array
        {
            Variant vsa = T[1].init;
            assert(vsa.typeInfo() is typeid(T[1]));
            assert(vsa.variantType == VariantType.staticArray);
        }

        // Dynamic array
        {
            Variant vda = T[].init;
            assert(vda.typeInfo() is typeid(T[]));
            assert(vda.variantType == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            Variant vaa = T[T].init;
            assert(vaa.typeInfo() is typeid(T[T]));
            assert(vaa.variantType == VariantType.associativeArray);
        }
    }

    static foreach (T; AliasSeq!(bool))
    {
        {
            Variant vt = T.init;
            assert(vt.typeInfo is typeid(T));
            assert(vt.variantType == VariantType.boolean);
        }

        // Static array
        {
            Variant vsa = T[1].init;
            assert(vsa.typeInfo() is typeid(T[1]));
            assert(vsa.variantType == VariantType.staticArray);
        }

        // Dynamic array
        {
            Variant vda = T[].init;
            assert(vda.typeInfo() is typeid(T[]));
            assert(vda.variantType == VariantType.dynamicArray);
        }

        // AssociativeArray
        {
            Variant vaa = T[T].init;
            assert(vaa.typeInfo() is typeid(T[T]));
            assert(vaa.variantType == VariantType.associativeArray);
        }
    }

    enum E { a, b }
    Variant vE = E.a;
    assert(vE.typeInfo is typeid(E));
    assert(vE.variantType == VariantType.enum_);

    enum EI : int { a = 1, b = 100 }
    Variant vEI = EI.b;
    assert(vEI.typeInfo is typeid(EI));
    assert(vEI.variantType == VariantType.enum_);

    static struct S { int i; }
    Variant vS = S(1);
    assert(vS.typeInfo is typeid(S));
    assert(vS.variantType == VariantType.struct_);

    static union U { int i; string s; }
    Variant vU = U(1);
    assert(vU.typeInfo is typeid(U));
    assert(vU.variantType == VariantType.union_);

    static class C { long d; }
    Variant vC = new C();
    assert(vC.typeInfo is typeid(C));
    assert(vC.variantType == VariantType.class_);

    interface I { void f(); }
    I i;
    Variant vI = i;
    assert(vI.typeInfo is typeid(I));
    assert(vI.variantType == VariantType.interface_);

    Variant vP = cast(void*)null;
    assert(vP.typeInfo is typeid(void*));
    assert(vP.variantType == VariantType.pointer);

    int dlg() { return 2; }
    Variant vDlg = &dlg;
    assert(vDlg.typeInfo is typeid(typeof(&dlg)));
    assert(vDlg.variantType == VariantType.delegate_);

    static int fct() { return 1; }
    Variant vFct = &fct;
    assert(vFct.typeInfo is typeid(typeof(&fct)));
    assert(vFct.variantType == VariantType.function_);
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.length");

    Variant vVoid;
    assert(vVoid.length == 0);

    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
    {
        {
            Variant vt = T.init;
            assert(vt.length == 0);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(vsa.length == 1);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(vda.length == 1);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(vaa.length == 1);
        }
    }

    static foreach (T; AliasSeq!(float, double, real))
    {
        {
            Variant vt = T.init;
            assert(vt.length == 0);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(vsa.length == 1);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(vda.length == 1);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(vaa.length == 1);
        }
    }

    static foreach (T; AliasSeq!(char, wchar, dchar))
    {
        {
            Variant vt = T.init;
            assert(vt.length == 0);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(vsa.length == 1);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(vda.length == 1);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(vaa.length == 1);
        }
    }

    static foreach (T; AliasSeq!(string, wstring, dstring))
    {
        {
            Variant vt = T.init;
            assert(vt.length == 0);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(vsa.length == 1);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(vda.length == 1);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(vaa.length == 1);
        }

        {
            Variant vs = cast(T)"abc";
            assert(vs.length == 3);
        }
    }

    static foreach (T; AliasSeq!(bool))
    {
        {
            Variant vt = T.init;
            assert(vt.length == 0);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(vsa.length == 1);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(vda.length == 1);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(vaa.length == 1);
        }
    }

    enum E { a, b }
    Variant vE = E.a;
    assert(vE.length == 0);

    enum EI : int { a = 1, b = 100 }
    Variant vEI = EI.b;
    assert(vEI.length == 0);

    static struct S { int i; }
    Variant vS = S(1);
    assert(vS.length == 0);

    static union U { int i; string s; }
    Variant vU = U(1);
    assert(vU.length == 0);

    static class C { long d; }
    Variant vC = new C();
    assert(vC.length == 0);

    interface I { void f(); }
    I i;
    Variant vI = i;
    assert(vI.length == 0);

    Variant vP = cast(void*)null;
    assert(vP.length == 0);

    int dlg() { return 2; }
    Variant vDlg = &dlg;
    assert(vDlg.length == 0);

    static int fct() { return 1; }
    Variant vFct = &fct;
    assert(vFct.length == 0);
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.isNull & nullify");

    Variant vVoid;
    assert(vVoid.isNull);

    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
    {
        {
            Variant vt = T.init;
            assert(!vt.isNull);

            vt.nullify();
            assert(vt.isNull);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(!vsa.isNull);

            vsa.nullify();
            assert(vsa.isNull);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(!vda.isNull);

            vda.nullify();
            assert(vda.isNull);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(!vaa.isNull);

            vaa.nullify();
            assert(vaa.isNull);
        }
    }

    static foreach (T; AliasSeq!(float, double, real))
    {
        {
            Variant vt = T.init;
            assert(!vt.isNull);

            vt.nullify();
            assert(vt.isNull);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(!vsa.isNull);

            vsa.nullify();
            assert(vsa.isNull);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(!vda.isNull);

            vda.nullify();
            assert(vda.isNull);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(!vaa.isNull);

            vaa.nullify();
            assert(vaa.isNull);
        }
    }

    static foreach (T; AliasSeq!(char, wchar, dchar))
    {
        {
            Variant vt = T.init;
            assert(!vt.isNull);

            vt.nullify();
            assert(vt.isNull);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(!vsa.isNull);

            vsa.nullify();
            assert(vsa.isNull);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(!vda.isNull);

            vda.nullify();
            assert(vda.isNull);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(!vaa.isNull);

            vaa.nullify();
            assert(vaa.isNull);
        }
    }

    static foreach (T; AliasSeq!(string, wstring, dstring))
    {
        {
            Variant vt = T.init;
            assert(!vt.isNull);

            vt.nullify();
            assert(vt.isNull);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(!vsa.isNull);

            vsa.nullify();
            assert(vsa.isNull);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(!vda.isNull);

            vda.nullify();
            assert(vda.isNull);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(!vaa.isNull);

            vaa.nullify();
            assert(vaa.isNull);
        }

        {
            Variant vs = cast(T)"abc";
            assert(!vs.isNull);

            vs.nullify();
            assert(vs.isNull);
        }
    }

    static foreach (T; AliasSeq!(bool))
    {
        {
            Variant vt = T.init;
            assert(!vt.isNull);

            vt.nullify();
            assert(vt.isNull);
        }

        // Static array
        {
            T[1] tsa;
            Variant vsa = tsa;
            assert(!vsa.isNull);

            vsa.nullify();
            assert(vsa.isNull);
        }

        // Dynamic array
        {
            T[] dda = [T.init];
            Variant vda = dda;
            assert(!vda.isNull);

            vda.nullify();
            assert(vda.isNull);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[T.init] = T.init;
            Variant vaa = aaa;
            assert(!vaa.isNull);

            vaa.nullify();
            assert(vaa.isNull);
        }
    }

    enum E { a, b }
    Variant vE = E.a;
    assert(!vE.isNull);

    vE.nullify();
    assert(vE.isNull);

    enum EI : int { a = 1, b = 100 }
    Variant vEI = EI.b;
    assert(!vEI.isNull);

    vEI.nullify();
    assert(vEI.isNull);

    static struct S { int i; }
    Variant vS = S(1);
    assert(!vS.isNull);

    vS.nullify();
    assert(vS.isNull);

    static union U { int i; string s; }
    Variant vU = U(1);
    assert(!vU.isNull);

    vU.nullify();
    assert(vU.isNull);

    static class C { long d; }
    Variant vC = new C();
    assert(!vC.isNull);

    vC.nullify();
    assert(vC.isNull);

    interface I { void f(); }
    I i;
    Variant vI = i;
    assert(!vI.isNull);

    vI.nullify();
    assert(vI.isNull);

    Variant vP = cast(void*)null;
    assert(!vP.isNull);

    vP.nullify();
    assert(vP.isNull);

    int dlg() { return 2; }
    Variant vDlg = &dlg;
    assert(!vDlg.isNull);

    vDlg.nullify();
    assert(vDlg.isNull);

    static int fct() { return 1; }
    Variant vFct = &fct;
    assert(!vFct.isNull);

    vFct.nullify();
    assert(vFct.isNull);
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.peek");

    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
    {
        {
            Variant vt = cast(T)T.sizeof;
            assert(vt.peek!T && *vt.peek!T == T.sizeof);
            assert(!vt.peek!double);
            assert(!vt.peek!char);
            assert(!vt.peek!bool);
        }

        // Static array
        {
            T[1] tsa = [1];
            Variant vsa = tsa;
            assert(vsa.peek!(T[1]) && *vsa.peek!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [1];
            Variant vda = dda;
            assert(vda.peek!(T[]) && *vda.peek!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[1] = T.sizeof;
            Variant vaa = aaa;
            assert(vaa.peek!(T[T]) && *vaa.peek!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(float, double, real))
    {
        {
            T v = cast(T)T.sizeof + 0.1;
            Variant vt = v;
            assert(vt.peek!T && *vt.peek!T == v);
            assert(!vt.peek!long);
        }

        // Static array
        {
            T[1] tsa = [cast(T)T.sizeof + 0.1];
            Variant vsa = tsa;
            assert(vsa.peek!(T[1])&& *vsa.peek!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [cast(T)T.sizeof + 0.1];
            Variant vda = dda;
            assert(vda.peek!(T[]) && *vda.peek!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[1] = cast(T)T.sizeof + 0.1;
            Variant vaa = aaa;
            assert(vaa.peek!(T[T]) && *vaa.peek!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(char, wchar, dchar))
    {
        {
            Variant vt = cast(T)'a';
            assert(vt.peek!T && *vt.peek!T == cast(T)'a');
            assert(!vt.peek!int);
        }

        // Static array
        {
            T[1] tsa = [cast(T)'a'];
            Variant vsa = tsa;
            assert(vsa.peek!(T[1]) && *vsa.peek!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [cast(T)'a'];
            Variant vda = dda;
            assert(vda.peek!(T[]) && *vda.peek!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[cast(T)'a'] = cast(T)'z';
            Variant vaa = aaa;
            assert(vaa.peek!(T[T]) && *vaa.peek!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(string, wstring, dstring))
    {
        {
            Variant vt = cast(T)"abc";
            assert(vt.peek!T && *vt.peek!T == cast(T)"abc");
            assert(!vt.peek!char);
        }

        // Static array
        {
            T[1] tsa = [cast(T)"abc"];
            Variant vsa = tsa;
            assert(vsa.peek!(T[1]) && *vsa.peek!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [cast(T)"abc"];
            Variant vda = dda;
            assert(vda.peek!(T[]) && *vda.peek!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[cast(T)"abc"] = cast(T)"xyz";
            Variant vaa = aaa;
            assert(vaa.peek!(T[T]) && *vaa.peek!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(bool))
    {
        {
            Variant vt = true;
            assert(vt.peek!bool && *vt.peek!bool == true);
            assert(!vt.peek!byte);
        }

        // Static array
        {
            T[1] tsa = [true];
            Variant vsa = tsa;
            assert(vsa.peek!(T[1]) && *vsa.peek!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [true];
            Variant vda = dda;
            assert(vda.peek!(T[]) && *vda.peek!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[false] = true;
            Variant vaa = aaa;
            assert(vaa.peek!(T[T]) && *vaa.peek!(T[T]) == aaa);
        }
    }

    enum E { a, b }
    Variant vE = E.a;
    assert(vE.peek!E && *vE.peek!E == E.a);

    enum EI : int { a = 1, b = 100 }
    Variant vEI = EI.b;
    assert(vEI.peek!EI && *vEI.peek!EI == EI.b);
    assert(!vEI.peek!E);

    static struct S { int i; }
    S s = S(1);
    Variant vS = s;
    assert(vS.peek!S && *vS.peek!S == s);

    static union U { int i; string s; }
    U u = U(1);
    Variant vU = u;
    assert(vU.peek!U && *vU.peek!U == u);
    assert(!vU.peek!S);

    static class C { long d; }
    C c = new C();
    Variant vC = c;
    assert(vC.peek!C && (*vC.peek!C).d == c.d);

    interface I { void f(); }
    I i;
    Variant vI = i;
    assert(vI.peek!I);
    assert(!vI.peek!C);

    void* p = null;
    Variant vP = p;
    assert(vP.peek!(void*) && *vP.peek!(void*) is null);
    assert(!vP.peek!C);

    int dlg() { return 2; }
    int delegate() d = &dlg;
    Variant vDlg = d;
    assert(vDlg.peek!(int delegate()) && *vDlg.peek!(int delegate()) == d);

    static int fct() { return 1; }
    int function() f = &fct;
    Variant vFct = f;
    assert(vFct.peek!(int function()) && *vFct.peek!(int function()) == f);
    assert(!vFct.peek!(int delegate()));
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.get");

    static foreach (T; AliasSeq!(byte, ubyte, short, ushort, int, uint, long, ulong))
    {
        {
            Variant vt = cast(T)T.sizeof;
            assert(vt.get!T == T.sizeof);

            T tv;
            assert(vt.tryGet!T(tv));
            assert(tv == T.sizeof);

            // D rule - not implicitely convertible from long to ulong
            static if (!is(T == long) && !is(T == ulong))
            {
                ulong tvul;
                assert(vt.tryGet!ulong(tvul));
                assert(tvul == T.sizeof);
            }
        }

        // Static array
        {
            T[1] tsa = [1];
            Variant vsa = tsa;
            assert(vsa.get!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [1];
            Variant vda = dda;
            assert(vda.get!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[1] = T.sizeof;
            Variant vaa = aaa;
            assert(vaa.get!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(float, double, real))
    {
        {
            T v = cast(T)T.sizeof + 0.1;
            Variant vt = v;
            assert(vt.get!T == v);

            T tv;
            assert(vt.tryGet!T(tv));
            assert(tv == v);

            real tvr;
            assert(vt.tryGet!real(tvr));
            assert(tvr == v);
        }

        // Static array
        {
            T[1] tsa = [cast(T)T.sizeof + 0.1];
            Variant vsa = tsa;
            assert(vsa.get!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [cast(T)T.sizeof + 0.1];
            Variant vda = dda;
            assert(vda.get!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[1] = cast(T)T.sizeof + 0.1;
            Variant vaa = aaa;
            assert(vaa.get!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(char, wchar, dchar))
    {
        {
            Variant vt = cast(T)'a';
            assert(vt.get!T == cast(T)'a');
        }

        // Static array
        {
            T[1] tsa = [cast(T)'a'];
            Variant vsa = tsa;
            assert(vsa.get!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [cast(T)'a'];
            Variant vda = dda;
            assert(vda.get!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[cast(T)'a'] = cast(T)'z';
            Variant vaa = aaa;
            assert(vaa.get!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(string, wstring, dstring))
    {
        {
            Variant vt = cast(T)"abc";
            assert(vt.get!T == cast(T)"abc");
        }

        // Static array
        {
            T[1] tsa = [cast(T)"abc"];
            Variant vsa = tsa;
            assert(vsa.get!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [cast(T)"abc"];
            Variant vda = dda;
            assert(vda.get!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[cast(T)"abc"] = cast(T)"xyz";
            Variant vaa = aaa;
            assert(vaa.get!(T[T]) == aaa);
        }
    }

    static foreach (T; AliasSeq!(bool))
    {
        {
            Variant vt = true;
            assert(vt.get!bool == true);
        }

        // Static array
        {
            T[1] tsa = [true];
            Variant vsa = tsa;
            assert(vsa.get!(T[1]) == tsa);
        }

        // Dynamic array
        {
            T[] dda = [true];
            Variant vda = dda;
            assert(vda.get!(T[]) == dda);
        }

        // AssociativeArray
        {
            T[T] aaa;
            aaa[false] = true;
            Variant vaa = aaa;
            assert(vaa.get!(T[T]) == aaa);
        }
    }

    enum E { a, b }
    Variant vE = E.a;
    assert(vE.get!E == E.a);

    enum EI : int { a = 1, b = 100 }
    Variant vEI = EI.b;
    assert(vEI.get!EI == EI.b);

    static struct S { int i; }
    S s = S(1);
    Variant vS = s;
    assert(vS.get!S == s);

    static union U { int i; string s; }
    U u = U(1);
    Variant vU = u;
    assert(vU.get!U == u);

    static class C { long d; }
    C c = new C();
    Variant vC = c;
    assert(vC.get!C.d == c.d);

    interface I { void f(); }
    I i;
    Variant vI = i;
    assert(vI.get!I is i);

    void* p = null;
    Variant vP = p;
    assert(vP.get!(void*) is null);

    int dlg() { return 2; }
    int delegate() d = &dlg;
    Variant vDlg = d;
    assert(vDlg.get!(int delegate()) == d);

    static int fct() { return 1; }
    int function() f = &fct;
    Variant vFct = f;
    assert(vFct.get!(int function()) == f);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.get");

    // Primarily test that we can assign a void[] to a Variant.
    void[] elements = cast(void[])[1, 2, 3];
    Variant v = elements;
    void[] returned = v.get!(void[]);
    assert(returned == elements);
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.get & peek - conversion");

    // Automatically convert per language rules
    {
        Variant v = 100;
        assert(v.canGet!double);
        auto vg = v.get!double;
        assert(vg == 100.0);
    }

    {
        void[] o = cast(void[])[1, 2, 3];
        Variant v = o;
        assert(v.canGet!(void[]));
        auto vg = v.get!(void[]);
        assert(vg == o);
    }

    {
        static struct SDestruct
        {
            int x = 42;
            ~this()
            {
                assert(x == 42);
            }
        }
        Variant(SDestruct()).get!SDestruct;

        SDestruct s;
        assert(Variant(SDestruct()).tryGet!SDestruct(s));
    }

    {
        const Variant v = new immutable Object;
        v.get!(immutable Object);
    }

    {
        static struct SCast
        {
            T opCast(T)()
            {
                assert(false);
            }
        }
        Variant v = SCast();
        v.get!SCast;
    }

    {
        static void fun(T)(Variant v)
        {
            T x;
            v = x;
            auto r = v.get!(T);
        }

        Variant v;
        fun!(shared(int))(v);
        fun!(shared(int)[])(v);

        static struct S1
        {
            int c;
            string a;
        }

        static struct S2
        {
            string a;
            shared int[] b;
        }

        static struct S3
        {
            string a;
            shared int[] b;
            int c;
        }

        // ensure structs that are shared, but don't have shared postblits
        // can't be used.
        static struct S4
        {
            int x;
            this(this)
            {
                x = 0;
            }
        }

        fun!(S1)(v);
        fun!(shared(S1))(v);
        fun!(S2)(v);
        fun!(shared(S2))(v);
        fun!(S3)(v);
        fun!(shared(S3))(v);

        fun!(S4)(v);
        static assert(!is(typeof(fun!(shared(S4))(v))));
    }

    {
        Variant v;

        v = 42;
        assert(v.get!(int) == 42);
        assert(v.get!(long) == 42L);
        assert(v.get!(ulong) == 42uL);
    }

    {
        static struct SHuge
        {
            real a, b, c, d, e, f, g;
        }

        SHuge o;
        o.e = 42;
        Variant v;
        v = o;
        assert(v.get!SHuge.e == 42);

        SHuge o2;
        assert(v.tryGet!SHuge(o2));
        assert(o2.e == 42);
    }

    {
        const v = Variant(42);

        assert(v.canGet!(const int));
        const y1 = v.get!(const int);
        assert(y1 == 42);

        assert(v.canGet!(immutable int));
        immutable y2 = v.get!(immutable int);
        assert(y2 == 42);
    }

    {
        static struct SPad(bool pad)
        {
            int val1;
            static if (pad)
            ubyte[Variant.size] padding;
            int val2;
        }

        void testPad(T)()
        {
            T inst;
            inst.val1 = 3;
            inst.val2 = 4;
            Variant v = inst;

            T* original = v.peek!T;
            assert(original.val1 == 3);
            assert(original.val2 == 4);
            assert(v.get!T.val1 == 3);
            assert(v.get!T.val2 == 4);

            original.val1 = 6;
            original.val2 = 8;
            T modified = v.get!T;
            assert(modified.val1 == 6);
            assert(modified.val2 == 8);
        }

        testPad!(SPad!false)();
        testPad!(SPad!true)();
    }

    {
        Variant v;

        int i = 10;
        v = i;
        static foreach (qual; AliasSeq!(MutableOf, ConstOf))
        {
            assert(v.canGet!(qual!int));
            assert(v.get!(qual!int) == 10);

            assert(v.canGet!(qual!float));
            assert(v.get!(qual!float) == 10.0f);
        }

        const(int) ci = 20;
        v = ci;
        static foreach (qual; AliasSeq!(ConstOf))
        {
            assert(v.canGet!(qual!int));
            assert(v.get!(qual!int) == 20);

            assert(v.canGet!(qual!float));
            assert(v.get!(qual!float) == 20.0f);
        }

        immutable(int) ii = ci;
        v = ii;
        static foreach (qual; AliasSeq!(ImmutableOf, ConstOf, SharedConstOf))
        {
            assert(v.canGet!(qual!int));
            assert(v.get!(qual!int) == 20);

            assert(v.canGet!(qual!float));
            assert(v.get!(qual!float) == 20.0f);
        }

        int[] ai = [1,2,3];
        v = ai;
        static foreach (qual; AliasSeq!(MutableOf, ConstOf))
        {
            assert(v.canGet!(qual!(int[])));
            assert(v.get!(qual!(int[])) == [1,2,3]);

            assert(v.canGet!(qual!(int)[]));
            assert(v.get!(qual!(int)[]) == [1,2,3]);
        }

        const(int[]) cai = [4,5,6];
        v = cai;
        static foreach (qual; AliasSeq!(ConstOf))
        {
            assert(v.canGet!(qual!(int[])));
            assert(v.get!(qual!(int[])) == [4,5,6]);

            assert(v.canGet!(qual!(int)[]));
            assert(v.get!(qual!(int)[]) == [4,5,6]);
        }

        immutable(int[]) iai = [7,8,9];
        v = iai;
        version (BUG) assert(v.get!(immutable(int[])) == [7,8,9]);   // Bug ??? runtime error
        assert(v.get!(immutable(int)[]) == [7,8,9]);
        assert(v.get!(const(int[])) == [7,8,9]);
        assert(v.get!(const(int)[]) == [7,8,9]);

        static class A {}
        static class B : A {}
        B b = new B();
        v = b;
        static foreach (qual; AliasSeq!(MutableOf, ConstOf))
        {
            assert(v.canGet!(qual!B));
            assert(v.get!(qual!B) is b);

            assert(v.canGet!(qual!A));
            assert(v.get!(qual!A) is b);

            assert(v.canGet!(qual!Object));
            assert(v.get!(qual!Object) is b);
        }

        const(B) cb = new B();
        v = cb;
        static foreach (qual; AliasSeq!(ConstOf))
        {
            assert(v.canGet!(qual!B));
            assert(v.get!(qual!B) is cb);

            assert(v.canGet!(qual!A));
            assert(v.get!(qual!A) is cb);

            assert(v.canGet!(qual!Object));
            assert(v.get!(qual!Object) is cb);
        }

        immutable(B) ib = new immutable(B)();
        v = ib;
        static foreach (qual; AliasSeq!(ImmutableOf, ConstOf, SharedConstOf))
        {
            assert(v.canGet!(qual!B));
            assert(v.get!(qual!B) is ib);

            assert(v.canGet!(qual!A));
            assert(v.get!(qual!A) is ib);

            assert(v.canGet!(qual!Object));
            assert(v.get!(qual!Object) is ib);
        }

        shared(B) sb = new shared B();
        v = sb;
        static foreach (qual; AliasSeq!(SharedOf, SharedConstOf))
        {
            assert(v.canGet!(qual!B));
            assert(v.get!(qual!B) is sb);

            assert(v.canGet!(qual!A));
            assert(v.get!(qual!A) is sb);

            assert(v.canGet!(qual!Object));
            assert(v.get!(qual!Object) is sb);
        }

        shared(const(B)) scb = new shared const B();
        v = scb;
        static foreach (qual; AliasSeq!(SharedConstOf))
        {
            assert(v.canGet!(qual!B));
            assert(v.get!(qual!B) is scb);

            assert(v.canGet!(qual!A));
            assert(v.get!(qual!A) is scb);

            assert(v.canGet!(qual!Object));
            assert(v.get!(qual!Object) is scb);
        }
    }
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.get & peek - conversion");

    {
        static class EmptyClass { }
        static struct EmptyStruct { }
        alias EmptyArray = void[0];

        Variant testEmpty(T)()
        {
            T inst;
            Variant v = inst;
            assert(v.get!T == inst);
            assert(v.peek!T !is null);
            assert(*v.peek!T == inst);
            return v;
        }

        testEmpty!EmptyClass();
        testEmpty!EmptyStruct();
        testEmpty!EmptyArray();

        // EmptyClass/EmptyStruct sizeof is 1, so we have this to test just size 0.
        EmptyArray arr = EmptyArray.init;
        Variant a = arr;
        assert(a.length == 0);
        assert(a.canGet!EmptyArray);
        assert(a.get!EmptyArray == arr);
    }

    {
        Variant v;

        immutable(int[]) iai = [7,8,9];
        v = iai;
        version (BUG) assert(v.get!(shared(const(int[]))) == cast(shared const)[7,8,9]);    // Bug ??? runtime error
        version (BUG) assert(v.get!(shared(const(int))[]) == cast(shared const)[7,8,9]);    // Bug ??? runtime error
    }
}

@safe unittest
{
    import std.exception : assertThrown;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.get - incompatible conversion");

    assertThrown!VariantException(Variant("a").get!int);

    {
        Variant v;

        // For basic types, immutable/const protection is useless since they are copied value
        version (FIXED)
        {
            int i = 10;
            v = i;
            static foreach (qual; AliasSeq!(ImmutableOf, SharedOf, SharedConstOf))
            {
                assertThrown!VariantException(v.get!(qual!int));
            }

            const(int) ci = 20;
            v = ci;
            static foreach (qual; AliasSeq!(MutableOf, ImmutableOf, SharedOf, SharedConstOf))
            {
                assertThrown!VariantException(v.get!(qual!int));
                assertThrown!VariantException(v.get!(qual!float));
            }

            immutable(int) ii = 20;
            v = ii;
            static foreach (qual; AliasSeq!(MutableOf, SharedOf))
            {
                assertThrown!VariantException(v.get!(qual!int));
                assertThrown!VariantException(v.get!(qual!float));
            }
        }

        int[] ai = [1,2,3];
        v = ai;
        static foreach (qual; AliasSeq!(ImmutableOf, SharedOf, SharedConstOf))
        {
            assert(!v.canGet!(qual!(int[])));
            assertThrown!VariantException(v.get!(qual!(int[])));

            assert(!v.canGet!(qual!(int)[]));
            assertThrown!VariantException(v.get!(qual!(int)[]));
        }

        const(int[]) cai = [4,5,6];
        v = cai;
        static foreach (qual; AliasSeq!(MutableOf, ImmutableOf, SharedOf, SharedConstOf))
        {
            assert(!v.canGet!(qual!(int[])));
            assertThrown!VariantException(v.get!(qual!(int[])));

            assert(!v.canGet!(qual!(int)[]));
            assertThrown!VariantException(v.get!(qual!(int)[]));
        }

        immutable(int[]) iai = [7,8,9];
        v = iai;
        static foreach (qual; AliasSeq!(MutableOf))
        {
            assert(!v.canGet!(qual!(int[])));
            assertThrown!VariantException(v.get!(qual!(int[])));

            assert(!v.canGet!(qual!(int)[]));
            assertThrown!VariantException(v.get!(qual!(int)[]));
        }

        static class A {}
        static class B : A {}
        B b = new B();
        v = b;
        static foreach (qual; AliasSeq!(ImmutableOf, SharedOf, SharedConstOf))
        {
            assert(!v.canGet!(qual!B));
            assertThrown!VariantException(v.get!(qual!B));

            assert(!v.canGet!(qual!A));
            assertThrown!VariantException(v.get!(qual!A));

            assert(!v.canGet!(qual!Object));
            assertThrown!VariantException(v.get!(qual!Object));
        }

        const(B) cb = new B();
        v = cb;
        static foreach (qual; AliasSeq!(MutableOf, ImmutableOf, SharedOf, SharedConstOf))
        {
            assert(!v.canGet!(qual!B));
            assertThrown!VariantException(v.get!(qual!B));

            assert(!v.canGet!(qual!A));
            assertThrown!VariantException(v.get!(qual!A));

            assert(!v.canGet!(qual!Object));
            assertThrown!VariantException(v.get!(qual!Object));
        }

        immutable(B) ib = new immutable(B)();
        v = ib;
        static foreach (qual; AliasSeq!(MutableOf, SharedOf))
        {
            assert(!v.canGet!(qual!B));
            assertThrown!VariantException(v.get!(qual!B));

            assert(!v.canGet!(qual!A));
            assertThrown!VariantException(v.get!(qual!A));

            assert(!v.canGet!(qual!Object));
            assertThrown!VariantException(v.get!(qual!Object));
        }

        shared(B) sb = new shared B();
        v = sb;
        static foreach (qual; AliasSeq!(MutableOf, ImmutableOf, ConstOf))
        {
            assert(!v.canGet!(qual!B));
            assertThrown!VariantException(v.get!(qual!B));

            assert(!v.canGet!(qual!A));
            assertThrown!VariantException(v.get!(qual!A));

            assert(!v.canGet!(qual!Object));
            assertThrown!VariantException(v.get!(qual!Object));
        }

        shared(const(B)) scb = new shared const B();
        v = scb;
        static foreach (qual; AliasSeq!(MutableOf, ConstOf, ImmutableOf, SharedOf))
        {
            assert(!v.canGet!(qual!B));
            assertThrown!VariantException(v.get!(qual!B));

            assert(!v.canGet!(qual!A));
            assertThrown!VariantException(v.get!(qual!A));

            assert(!v.canGet!(qual!Object));
            assertThrown!VariantException(v.get!(qual!Object));
        }
    }
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - Aggregate with pointer fit in Variant.size");

    static int counter;

    static struct S
    {
        int* p;

        this(int a) nothrow
        {
            counter++;
            p = new int(a);
        }

        this(this) nothrow @trusted
        {
            counter++;
            p = new int(v);
        }

        ~this() nothrow @safe
        {
            counter--;
            p = null;
        }

        ref typeof(this) opAssign(S source) nothrow return
        {
            if (p is null)
                p = new int(source.v);
            else
                *p = source.v;
            return this;
        }

        private int v() nothrow
        {
            assert(p !is null);
            return *p;
        }
    }

    static void refCheck(ref Variant v)
    {
        assert(v.peek!S.p !is null);
        assert(*v.get!S.p == 4);
        assert(*v.peek!S.p == 4);
    }

    static void copyCheck(Variant v)
    {
        assert(v.peek!S.p !is null);
        assert(*v.get!S.p == 4);
        assert(*v.peek!S.p == 4);
    }

    Variant v = S(4);
    refCheck(v);
    copyCheck(v);

    {
        Variant v2 = v;
        refCheck(v2);
        copyCheck(v2);
    }

    {
        Variant v3;
        v3 = v;
        refCheck(v3);
        copyCheck(v3);
    }

    {
        Variant v4 = Variant(v);
        refCheck(v4);
        copyCheck(v4);
    }
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.canGet");

    Variant v;

    v = cast(float)3.14;
    assert(v.canGet!float());
    assert(v.canGet!double());
    assert(v.canGet!real());
    assert(!v.canGet!int());
    assert(!v.canGet!uint());
    assert(!v.canGet!long());
    assert(!v.canGet!ulong());

    v = cast(int)42;
    assert(v.canGet!int());
    assert(v.canGet!long());
    assert(v.canGet!float());
    assert(v.canGet!double());
    assert(v.canGet!real());

    v = cast(uint)42;
    assert(!v.canGet!int());
    assert(v.canGet!uint());
    assert(v.canGet!long());
    assert(v.canGet!ulong());
    assert(v.canGet!float());
    assert(v.canGet!double());
    assert(v.canGet!real());

    v = "Hello, World!";
    assert(!v.canGet!(wchar[])());

    v = Variant("abc".dup);
    assert(v.canGet!(char[])());
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.operator");

    {
        Variant a = 1;
        Variant b = -2;
        assert(*(a + b).peek!int() == -1);
        assert(*(a - b).peek!int() == 3);
    }

    {
        Variant v;

        v = 38;
        assert(*(v + 4).peek!int() == 42);
        assert(*(4 + v).peek!int() == 42);
        assert(*(v - 4).peek!int() == 34);
        assert(*(Variant(4) - v).peek!int() == -34);
        assert(*(v * 2).peek!int() == 76);
        assert(*(2 * v).peek!int() == 76);
        assert(*(v / 2).peek!int() == 19);
        assert(*(Variant(2) / v).peek!int() == 0);
        assert(*(v % 2).peek!int() == 0);
        assert(*(Variant(2) % v).peek!int() == 2);
        assert(*(v & 6).peek!int() == 6);
        assert(*(6 & v).peek!int() == 6);
        assert(*(v | 9).peek!int() == 47);
        assert(*(9 | v).peek!int() == 47);
        assert(*(v ^ 5).peek!int() == 35);
        assert(*(5 ^ v).peek!int() == 35);
        assert(*(v << 1).peek!int() == 76);
        assert(*(Variant(1) << Variant(2)).peek!int() == 4);
        assert(*(v >> 1).peek!int() == 19);
        assert(*(Variant(4) >> Variant(2)).peek!int() == 1);

        v = 38; v += 4; assert(*v.peek!int() == 42);
        v = 38; v -= 4; assert(*v.peek!int() == 34);
        v = 38; v *= 2; assert(*v.peek!int() == 76);
        v = 38; v /= 2; assert(*v.peek!int() == 19);
        v = 38; v %= 2; assert(*v.peek!int() == 0);
        v = 38; v &= 6; assert(*v.peek!int() == 6);
        v = 38; v |= 9; assert(*v.peek!int() == 47);
        v = 38; v ^= 5; assert(*v.peek!int() == 35);
        v = 38; v <<= 1; assert(*v.peek!int() == 76);
        v = 38; v >>= 1; assert(*v.peek!int() == 19);
        v = 38; v += 1; assert(*v.peek!int() < 40);
    }

    {
        Variant v;

        v = 38;
        assert(v + 4 == 42);
        assert(4 + v == 42);
        assert(v - 4 == 34);
        assert(Variant(4) - v == -34);
        assert(v * 2 == 76);
        assert(2 * v == 76);
        assert(v / 2 == 19);
        assert(Variant(2) / v == 0);
        assert(v % 2 == 0);
        assert(Variant(2) % v == 2);
        assert((v & 6) == 6);
        assert((6 & v) == 6);
        assert((v | 9) == 47);
        assert((9 | v) == 47);
        assert((v ^ 5) == 35);
        assert((5 ^ v) == 35);
        assert(v << 1 == 76);
        assert(Variant(1) << Variant(2) == 4);
        assert(v >> 1 == 19 );
        assert(Variant(4) >> Variant(2) == 1);

        v = 38; v += 4; assert(v == 42);
        v = 38; v -= 4; assert(v == 34);
        v = 38; v *= 2; assert(v == 76);
        v = 38; v /= 2; assert(v == 19);
        v = 38; v %= 2; assert(v == 0);
        v = 38; v &= 6; assert(v == 6);
        v = 38; v |= 9; assert(v == 47);
        v = 38; v ^= 5; assert(v == 35);
        v = 38; v <<= 1; assert(v == 76);
        v = 38; v >>= 1; assert(v == 19);
        v = 38; v += 1; assert(v < 40);
    }

    assert(Variant(0) < Variant(42));
    assert(Variant(42) > Variant(0));
    assert(Variant(42) > Variant(0.1));
    assert(Variant(42.1) > Variant(1));
    assert(Variant(21) == Variant(21));
    assert(Variant(0) != Variant(42));
    assert(Variant("bar") == Variant("bar"));
    assert(Variant("foo") != Variant("bar"));

    {
        static struct S1
        {
            ubyte a;
            ubyte[100] u;
        }

        Variant var1 = Variant(S1(1));
        Variant var2 = Variant(const S1(1));
        assert(var1 == var2);

        var2 = Variant(const S1(2));
        assert(var1 != var2);
    }
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.operator");

    assert(Variant("abc") ~ "def" == "abcdef");
    assert(Variant("abc") ~ Variant("def") == "abcdef");

    Variant v;
    v = "abc";
    v ~= "def";
    assert(v == "abcdef");

    version (none)
    {
        char[] charArray = ['a', 'b', 'c'];
        v = charArray;
        assert(v == "abc");
    }
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.isValue");

    Variant v; assert(!v);
    v = null; assert(!v);

    v = false; assert(!v);
    v = true; assert(v);

    v = 0; assert(!v);
    v = 10; assert(v);

    v = 0.0; assert(!v);
    v = 2.5; assert(v);
    v = float.nan; assert(!v);

    v = "abc"; assert(v);
    v = ""; assert(!v);

    int[] darr = [1];
    v = darr; assert(v);
    darr = [];
    v = darr; assert(!v);

    int[1] sarr = [1];
    v = sarr; assert(v);

    int[string] aa;
    aa["a"] = 1;
    v = aa; assert(v);
    aa.remove("a");
    v = aa; assert(!v);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.toString");

    static struct S
    {
        string toString() { return "Hello World!"; }
    }

    static class C
    {
        override string toString() { return "Hello World!"; }
    }

    Variant v; assert(v.toString() is null);
    v = Variant(42); assert(v.toString() == "42");
    v = Variant(42.22); assert(v.toString() == "42.22");
    v = "Hello World!"; assert(v.toString() == "Hello World!");
    v = S(); assert(v.toString() == "Hello World!");
    v = new C(); assert(v.toString() == "Hello World!");
    v = 'c'; assert(v.toString() == "c");
    v = true; assert(v.toString() == "true");
}

@system unittest
{
    import std.exception : assertThrown;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.opIndex & opIndexAssign");

    Variant v;

    {
        v = new int[42];
        assert(v.length == 42);
        assert(v[0] == 0);

        v[5] = 7;
        assert(v[5] == 7);

        v[4] = ubyte.max;
        assert(v[4] == ubyte.max);

        v[3] = short.max;
        assert(v[3] == short.max);

        assertThrown!VariantException(v[0] = long.max);
    }

    {
        v = new double[42];
        assert(v.length == 42);

        v[5] = 7.0;
        assert(v[5] == 7.0);

        v[4] = float.max;
        assert(v[4] == float.max);

        v[3] = int.max;
        assert(v[3] == int.max);

        assertThrown!VariantException(v[0] = real.max);
    }

    {
        int[int] aa = [42:24];
        v = aa;
        assert(v[42] == 24);
        v[42] = 5;
        assert(v[42] == 5);
    }

    {
        int[4] ar = [0, 1, 2, 3];
        v = ar;
        assert(v == ar);
        assert(v[2] == 2);
        assert(v[3] == 3);
        v[2] = 6;
        assert(v[2] == 6);
        assert(v != ar);
    }

    {
        auto v1 = Variant(42);
        auto v2 = Variant("foo");

        int[Variant] aa;
        aa[v1] = 0;
        aa[v2] = 1;

        assert(aa[v1] == 0);
        assert(aa[v2] == 1);
    }

    {
        int[char[]] aa;
        aa["a"] = 1;
        aa["b"] = 2;
        aa["c"] = 3;

        Variant vaa = aa;
        assert(vaa.get!(int[char[]])["a"] == 1);
        assert(vaa.get!(int[char[]])["b"] == 2);
        assert(vaa.get!(int[char[]])["c"] == 3);
    }
}

@system unittest
{
    import std.exception : assertThrown;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.opOpAssign(~)");

    auto arr = Variant([1.2].dup);
    auto e = arr[0];
    assert(e == 1.2);
    arr[0] = 2.0;
    arr ~= 4.5;
    assert(arr[0] == 2);
    assert(arr[1] == 4.5);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.delegate & function");

    Variant v;

    // delegate
    int foo() { return 42; }
    v = &foo;
    assert(v() == 42);

    // function
    static int bar(string s) { return to!int(s); }
    v = &bar;
    assert(v("43") == 43);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.variantArray");

    auto a = variantArray(1, 3.14, "Hi!");
    assert(a.length == 3);
    assert(a[1] == 3.14);
    auto b = Variant(a); // variant array as variant
    assert(b[1] == 3.14);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.opApply - Static array");

    // static array - unchange
    {
        int[10] arr = [1,2,3,4,5,6,7,8,9,10];
        Variant v1 = arr;
        Variant v2;
        v2 = arr;
        assert(v1 == arr);
        assert(v2 == arr);
        foreach (i, e; arr)
        {
            assert(v1[i] == e);
            assert(v2[i] == e);
        }
    }

    // static array - change
    {
        int[5] arr = [1,2,3,4,5];
        Variant v = arr;
        int j = 0;
        foreach (ref int i; v)
        {
            assert(i == ++j);
            i = i * 2;
        }
        assert(j == 5);
        assert(v[0] == 2);
        assert(v[4] == 10);
    }
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.opApply - Dynamic array");

    // dynamic array - unchange
    {
        int[] arr = [1,2,3,4];
        Variant v = arr;
        auto j = 0;
        foreach (ref int i; v)
        {
            assert(i == ++j);
        }
        assert(j == 4);
        assert(v[0] == 1);
        assert(v[3] == 4);
    }

    // dynamic array - change
    {
        int[] arr = [1,2,3,4];
        Variant v = arr;
        auto j = 0;
        foreach (ref int i; v)
        {
            assert(i == ++j);
            i = i * 2;
        }
        assert(j == 4);
        assert(v[0] == 2);
        assert(v[3] == 8);
    }
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant.opApply - Associative array");

    double[string] aa; // key type is string, value type is double
    aa["a"] = 1;
    aa["b"] = 1.4;

    int count = 0;
    Variant va = aa;
    foreach (string k, double v; va)
    {
        count++;
        assert(k == "a" || k == "b");
        if (k == "a")
            assert(v == 1);
        else if (k == "b")
            assert(v == 1.4);
    }
    assert(count == 2);
}

@system unittest
{
    import std.exception : assertThrown;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic");

    {
        Algebraic!(int[]) v = [2, 2];

        assert(v == [2, 2]);
        v[0] = 1;
        assert(v[0] == 1);
        assert(v != [2, 2]);

        // opIndexAssign from Variant
        v[1] = v[0];
        assert(v[1] == 1);

        static assert(!__traits(compiles, (v[1] = null)));
        assertThrown!VariantException(v[1] = Variant(null));
    }

    {
        alias W1 = This2Variant!(char, int, This[int]);
        alias W2 = AliasSeq!(int, char[int]);
        static assert(is(W1 == W2));

        alias var_t = Algebraic!(void, string);
        var_t foo = "quux";
    }

    {
         alias A = Algebraic!(real, This[], This[int], This[This]);
         A v1, v2, v3;
         v2 = 5.0L;
         v3 = 42.0L;
         auto v = v1.peek!(A[]);
         v1 = [9 : v3];
         v1 = [v3 : v3];
    }

    {
        // check comparisons incompatible with AllowedTypes
        Algebraic!int v = 2;

        assert(v == 2);
        assert(v < 3);
        static assert(!__traits(compiles, {v == long.max;}));
        static assert(!__traits(compiles, {v == null;}));
        static assert(!__traits(compiles, {v < long.max;}));
        static assert(!__traits(compiles, {v > null;}));
    }

    {
        Algebraic!(int, double) a;
        a = 100;
        a = 1.0;
    }
}

nothrow @safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic");

    {
        Algebraic!(int, double) a;
        a = 100;
        a = 1.0;
    }

    {
        Algebraic!int x;

        static struct SafeS
        {
            @safe ~this() {}
        }

        Algebraic!(SafeS) y;
        y.nullify();
    }

    {
        auto v = Algebraic!(int, double, string)(5);
        assert(v.peek!int());
        v = 3.14;
        assert(v.peek!double());
    }
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.visit");

    // validate that visit can be called with a const type
    struct Foo { int depth = 1; }
    struct Bar { int depth = 2; }
    alias FooBar = Algebraic!(Foo, Bar);

    int depth(in FooBar fb)
    {
        return fb.visit!((Foo foo) => foo.depth,
                         (Bar bar) => bar.depth);
    }

    FooBar fb = Foo(3);
    assert(depth(fb) == 3);

    {
        Algebraic!(int, string) variant;

        variant = 10;
        assert(variant.visit!((string s) => cast(int)s.length,
                              (int i)    => i)()
                              == 10);
        variant = "string";
        assert(variant.visit!((int i) => i,
                              (string s) => cast(int)s.length)()
                              == 6);

        // Error function usage
        Algebraic!(int, string) emptyVar;
        auto rslt = emptyVar.visit!((string s) => cast(int)s.length,
                              (int i)    => i,
                              () => -1)();
        assert(rslt == -1);

        // Generic function usage
        Algebraic!(int, float, real) number = 2;
        assert(number.visit!(x => x += 1) == 3);

        // Generic function for int/float with separate behavior for string
        Algebraic!(int, float, string) something = 2;
        assert(something.visit!((string s) => s.length, x => x) == 2); // generic
        something = "asdf";
        assert(something.visit!((string s) => s.length, x => x) == 4); // string

        // Generic handler and empty handler
        Algebraic!(int, float, real) empty2;
        assert(empty2.visit!(x => x + 1, () => -1) == -1);
    }

    {
        Algebraic!(size_t, string) variant;

        // not all handled check
        static assert(!__traits(compiles, variant.visit!((size_t i){ })() ));

        variant = cast(size_t)10;
        auto which = 0;
        variant.visit!( (string s) => which = 1,
                        (size_t i) => which = 0
                        )();

        // integer overload was called
        assert(which == 0);

        // mustn't compile as generic Variant not supported
        Variant v;
        static assert(!__traits(compiles, v.visit!((string s) => which = 1,
                                                   (size_t i) => which = 0
                                                    )()
                                                    ));

        static size_t func(string s) { return s.length; }

        variant = "test";
        assert( 4 == variant.visit!(func,
                                    (size_t i) => i
                                    )());

        Algebraic!(int, float, string) variant2 = 5.0f;
        // Shouldn' t compile as float not handled by visitor.
        static assert(!__traits(compiles, variant2.visit!(
                            (int _) {},
                            (string _) {})()));

        Algebraic!(size_t, string, float) variant3;
        variant3 = 10.0f;
        auto floatVisited = false;

        assert(variant3.visit!(
                     (float f) { floatVisited = true; return cast(size_t)f; },
                     func,
                     (size_t i) { return i; }
                     )() == 10);
        assert(floatVisited == true);

        Algebraic!(float, string) variant4;

        assert(variant4.visit!(func, (float f) => cast(size_t)f, () => size_t.max)() == size_t.max);

        // double error func check
        static assert(!__traits(compiles,
                                visit!(() => size_t.max, func, (float f) => cast(size_t)f, () => size_t.max)(variant4))
                     );
    }

    {
        Algebraic!(int, float) number = 2;
        // ok, x + 1 valid for int and float
        static assert( __traits(compiles, number.visit!(x => x + 1)));
        // bad, two generic handlers
        static assert(!__traits(compiles, number.visit!(x => x + 1, x => x + 2)));
        // bad, x ~ "a" does not apply to int or float
        static assert(!__traits(compiles, number.visit!(x => x ~ "a")));
        // bad, x ~ "a" does not apply to int or float
        static assert(!__traits(compiles, number.visit!(x => x + 1, x => x ~ "a")));

        Algebraic!(int, string) maybenumber = 2;
        // ok, x ~ "a" valid for string, x + 1 valid for int, only 1 generic
        static assert( __traits(compiles, number.visit!((string x) => x ~ "a", x => x + 1)));
        // bad, x ~ "a" valid for string but not int
        static assert(!__traits(compiles, number.visit!(x => x ~ "a")));
        // bad, two generics, each only applies in one case
        static assert(!__traits(compiles, number.visit!(x => x + 1, x => x ~ "a")));
    }
}

@safe unittest
{
    import std.exception : assertThrown;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.tryVisit");

    {
        Algebraic!(int, string) variant;

        variant = 10;
        auto which = -1;
        variant.tryVisit!((int i) { which = 0; })();
        assert(which == 0);

        // Error function usage
        variant = "test";
        variant.tryVisit!((int i) { which = 0; },
                          ()      { which = -100; })();
        assert(which == -100);
    }

    {
        Algebraic!(int, string) variant;

        variant = 10;
        auto which = -1;
        variant.tryVisit!((int i){ which = 0; })();
        assert(which == 0);

        variant = "test";
        assertThrown!VariantException(variant.tryVisit!((int i) { which = 0; })());

        void errorfunc() { which = -1; }
        variant.tryVisit!((int i) { which = 0; }, errorfunc)();
        assert(which == -1);
    }
}

@system unittest // opCmp & opEquals for unqualified array element
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.opCmp & opEquals for unqualified array element");

    char[] abc = ['a','b','c'];
    char[] xyz = ['x','y','z'];

    Variant v = "abc";
    // immutable(char)[] vs char[]
    assert(v == abc);
    assert(v < xyz);
}

// Extra unittests from D std

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=10194");

    // Also test for elaborate copying
    static struct S
    {
        @disable this();

        this(int dummy)
        {
            ++cnt;
        }

        this(this)
        {
            ++cnt;
        }

        @disable S opAssign();

        ~this()
        {
            --cnt;
            assert(cnt >= 0);
        }

        static int cnt = 0;
    }

    {
        Variant v;
        {
            v = S(0);
            assert(S.cnt == 1);
        }
        assert(S.cnt == 1);

        // assigning a new value should destroy the existing one
        v = 0;
        assert(S.cnt == 0);

        // destroying the variant should destroy it's current value
        v = S(0);
        assert(S.cnt == 1);
    }

    assert(S.cnt == 0);
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=18934");

    static struct S
    {
        const int x;
    }

    auto s = S(42);
    Variant v = s;
    auto s2 = v.get!S;
    assert(s2.x == 42);
    Variant v2 = v; // support copying from one variant to the other
    v2 = S(2);
    v = v2;
    assert(v.get!S.x == 2);
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=15940");

    static class C { }
    static struct S
    {
        C a;
        alias a this;
    }
    S s = S(new C());
    auto v = Variant(s); // compile error
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=20666");

    static struct S(int padding)
    {
        byte[padding] _;
        int* p;
    }

    const S!0 s0;
    Variant a0 = s0;

    const S!1 s1;
    Variant a1 = s1;

    const S!63 s63;
    Variant a63 = s63;

    const S!64 s64;
    Variant a64 = s64;
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=20360");

    static int counter;

    static struct S
    {
        int* p;
        ubyte[100] u;

        this(int a) nothrow
        {
            counter++;
            p = new int(a);
        }

        this(this) nothrow @trusted
        {
            counter++;
            p = new int(v);
        }

        ~this() nothrow @safe
        {
            counter--;
            p = null;
        }

        ref typeof(this) opAssign(S source) nothrow return
        {
            if (p is null)
                p = new int(source.v);
            else
                *p = source.v;
            return this;
        }

        private int v() nothrow
        {
            assert(p !is null);
            return *p;
        }
    }

    static void refCheck(ref Variant v)
    {
        assert(v.peek!S.p !is null);
        assert(*v.get!S.p == 4);
        assert(*v.peek!S.p == 4);
    }

    static void copyCheck(Variant v)
    {
        assert(v.peek!S.p !is null);
        assert(*v.get!S.p == 4);
        assert(*v.peek!S.p == 4);
    }

    Variant v = S(4);
    refCheck(v);
    copyCheck(v);

    {
        Variant v2 = v;
        refCheck(v2);
        copyCheck(v2);
    }

    {
        Variant v3;
        v3 = v;
        refCheck(v3);
        copyCheck(v3);
    }

    {
        Variant v4 = Variant(v);
        refCheck(v4);
        copyCheck(v4);
    }
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=13262");

    static void fun(T)(Variant v)
    {
        T x;
        v = x;
        auto r = v.get!(T);
    }

    Variant v;

    fun!(shared(int))(v);
    fun!(shared(int)[])(v);

    static struct S1
    {
        int c;
        string a;
    }

    static struct S2
    {
        string a;
        shared int[] b;
    }

    static struct S3
    {
        string a;
        shared int[] b;
        int c;
    }

    fun!(S1)(v);
    fun!(shared(S1))(v);
    fun!(S2)(v);
    fun!(shared(S2))(v);
    fun!(S3)(v);
    fun!(shared(S3))(v);

    // ensure structs that are shared, but don't have shared postblits can't be used.
    static struct S4
    {
        int x;
        this(this) nothrow { x = 0; }
    }

    fun!(S4)(v);
    static assert(!is(typeof(fun!(shared(S4))(v))));
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=19986");

    VariantN!32 v;
    v = const(ubyte[33]).init;

    static struct S
    {
        ubyte[33] s;
    }

    VariantN!32 v2;
    v2 = const(S).init;
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=5424");

    interface A { void func1(); }

    static class AC: A { void func1() {} }

    A a = new AC();
    a.func1();
    Variant b = Variant(a);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Variant - https://issues.dlang.org/show_bug.cgi?id=15791");

    int n = 3;
    struct NS1 { int foo() { return n + 10; } }
    struct NS2 { int foo() { return n * 10; } }

    Variant v;

    v = NS1();
    assert(v.get!NS1.foo() == 13);

    v = NS2();
    assert(v.get!NS2.foo() == 30);
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=12071");

    static struct Structure { int data; }
    alias VariantTest = Algebraic!(Structure delegate() pure nothrow @nogc @safe);

    bool called = false;
    Structure example() pure nothrow @nogc @safe
    {
        called = true;
        return Structure.init;
    }
    auto m = VariantTest(&example);
    m();
    assert(called);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=14233");

    alias Atom = Algebraic!(string, This[]);
    Atom[] values = [];
    auto a = Atom(values);
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=14198");

    Variant a = true;
    assert(a.typeInfo is typeid(bool));
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=13354");

    {
        alias A = Algebraic!(string[]);
        A a = ["a", "b"];
        assert(a[0] == "a");
        assert(a[1] == "b");
        a[1] = "c";
        assert(a[1] == "c");
    }

    {
        alias AA = Algebraic!(int[string]);
        AA aa = ["a": 1, "b": 2];
        assert(aa["a"] == 1);
        assert(aa["b"] == 2);
        aa["b"] = 3;
        assert(aa["b"] == 3);
    }
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=13352");

    alias TP = Algebraic!(long);
    assert(!TP.allowed!ulong);
    auto a = TP(1L);
    auto b = TP(2L);
    assert(a + b == 3L);
    assert(a + 2 == 3L);
    assert(1 + b == 3L);

    alias TP2 = Algebraic!(long, string);
    auto c = TP2(3L);
    assert(a + c == 4L);
}

@system unittest
{
    import std.array;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=13300");

    static struct S
    {
        this(this) {}
        ~this() {}
    }

    static assert(hasElaborateCopyConstructor!(Variant));
    static assert(!hasElaborateCopyConstructor!(Algebraic!bool));
    static assert(hasElaborateCopyConstructor!(Algebraic!S));
    static assert(hasElaborateCopyConstructor!(Algebraic!(bool, S)));

    static assert(hasElaborateDestructor!(Variant));
    static assert(!hasElaborateDestructor!(Algebraic!bool));
    static assert(hasElaborateDestructor!(Algebraic!S));
    static assert(hasElaborateDestructor!(Algebraic!(bool, S)));

    alias Value = Algebraic!bool;

    static struct T
    {
        Value value;
        @disable this();
    }
    auto a = appender!(T[]);
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=13871");

    alias A = Algebraic!(int, typeof(null));
    static struct B { A value; }
    alias C = Algebraic!B;

    C var;
    var = C(B());
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=19994");

    alias Inner = Algebraic!(This*);
    alias Outer = Algebraic!(Inner, This*);

    static assert(is(Outer.AllowedTypes == AliasSeq!(Inner, Outer*)));
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=15615");

    alias Value = Algebraic!(long, double);

    const long foo = 123L;
	long bar = foo;
	Value baz = Value(foo);
    assert(baz == 123L);

    // Should not allow for const transitive violation
    static struct Wrapper
    {
        long* ptr;
    }

    alias VariantWrapper = Algebraic!(Wrapper, double);

    long l = 2;
    const cw = Wrapper(&l);
    static assert(!__traits(compiles, VariantWrapper(cw)), "Stripping `const` from type with indirection!");
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.Algebraic - https://issues.dlang.org/show_bug.cgi?id=14457");

    {
        alias A = Algebraic!(int, float, double);
        alias B = Algebraic!(int, float);

        A a = 1;
        B b = 6f;
        a = b;

        assert(a.typeInfo is typeid(float));
        assert(*a.peek!float() == 6f);
        assert(a.get!1() == 6f);
    }
}

@safe unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant.visit - https://issues.dlang.org/show_bug.cgi?id=16383");

    class Foo { this() immutable {} }
    alias V = Algebraic!(immutable Foo);

    auto x = V(new immutable Foo).visit!(
        (immutable(Foo) _) => 3
    );
    assert(x == 3);
}

@safe unittest
{
    import std.typecons;
    import pham.utl_test;
    dgWriteln("unittest utl_variant.visit - https://issues.dlang.org/show_bug.cgi?id=15039");

    alias IntTypedef = Typedef!int;
    alias V = Algebraic!(int, IntTypedef, This[]);

    V obj = 1;
    obj.visit!(
        (int x) {},
        (IntTypedef x) {},
        (V[] x) {},
    );
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant - https://issues.dlang.org/show_bug.cgi?id=21021");

    static struct S
    {
        int i;
        alias i this;
        string s;
    }

    S s = S(3, "Foo");
    Variant s1 = s;
    auto s2 = s1.get!S;
    assert(s.s == "Foo");
    assert(s2.s == "Foo");

    static struct A
    {
        int h;
        int[5] array;
        alias h this;
    }

    A a;
    a.array[] = 3;
    Variant a1 = a;
    auto a2 = a1.get!A;
    assert(a.array[0] == 3);
    assert(a2.array[0] == 3);
}

@system unittest
{
    import pham.utl_test;
    dgWriteln("unittest utl_variant - https://issues.dlang.org/show_bug.cgi?id=21069");

    Variant v = 1;
    auto y = v.get!Variant; // segfault ?
    assert(y == v);
}
