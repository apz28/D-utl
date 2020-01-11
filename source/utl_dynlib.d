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

module pham.utl_dynlib;

import std.format : format;
import std.string : toStringz;
import std.typecons : Flag, No, Yes;

alias DllHandle = void*;
alias DllProc = void*;

string concateLineIf(string lines, string addedLine)
{
    if (addedLine.length == 0)
        return lines;
    else if (lines.length == 0)
        return addedLine;
    else
        return lines ~ "\n" ~ addedLine;
}

struct DllMessage
{
    static immutable eLoadFunction = "Unknown procedure name: %s.%s";
    static immutable eLoadLibrary = "Unable to load library: %s";
    static immutable eUnknownError = "Unknown error.";
    static immutable notLoadedLibrary = "Library is not loaded: %s";
}

class DllException : Exception
{
    string libName;
    uint errorCode;

    this(string message, string libName,
        Exception next = null)
    {
        this(message, getLastErrorString(), getLastErrorCode(), libName, next);
    }

    this(string message, string lastErrorMessage, uint lastErrorCode, string libName,
        Exception next = null)
    {
        this.errorCode = lastErrorCode;
        this.libName = libName;
        super(concateLineIf(message, lastErrorMessage), next);
    }

    /** Platform/OS specific last error code & last error message
    */
    version (Windows)
    {
        import core.sys.windows.windows;
        import std.windows.syserror;

        static uint getLastErrorCode()
        {
            return GetLastError();
        }

        static string getLastErrorString()
        {
            return sysErrorString(GetLastError());
        }
    }
    else version(Posix)
    {
        import core.sys.posix.dlfcn;

        static uint getLastErrorCode()
        {
            return 0;
        }

        static string getLastErrorString()
        {
            import std.conv : to;

            auto errorText = dlerror();
            if (errorText is null)
                return DllMessage.eUnknownError;

            return to!string(errorText);
        }
    }
    else
    {
        static assert(0, "Unsupport platform.");
    }
}

class DllLibrary
{
public:
    this(string libName)
    {
        this._libName = libName;
    }

    ~this()
    {
        unload();
    }

    /** Load library if it is not loaded yet
    */
    final bool load(Flag!"throwIfError" throwIfError = Yes.throwIfError)()
    {
        if (!isLoaded)
        {
            _libHandle = loadLib(_libName);

            static if (throwIfError)
            if (!isLoaded)
            {
                string err = format(DllMessage.eLoadLibrary, _libName);
                throw new DllException(err, _libName);
            }

            if (isLoaded)
                loaded();
        }
        return isLoaded;
    }

    /** Load the function address using procName
        Params:
            procName = Name of the function

        Throws:
            DllException if loadProc fails if throwIfError is true

        Returns:
            Pointer to the function

        Example:
            fct = loadProc("AFunctionNameToBeLoaded...")

    */
    final DllProc loadProc(Flag!"throwIfError" throwIfError = Yes.throwIfError)(string procName)
    {
        DllProc res;
        if (isLoaded)
            res = loadProc(_libHandle, procName);

        static if (throwIfError)
        if (res is null)
        {
            if (!isLoaded)
            {
                string err = format(DllMessage.notLoadedLibrary, _libName);
                throw new DllException(err, null, 0, _libName);
            }
            else
            {
                string err = format(DllMessage.eLoadFunction, _libName, procName);
                throw new DllException(err, null, 0, _libName);
            }
        }

        return res;
    }

    /** Unload the library if it is loaded
    */
    final void unload()
    {
        if (isLoaded)
        {
            unloadLib(_libHandle);
            _libHandle = null;

            unloaded();
        }
    }

    /** Platform/OS specific load function
    */
    version (Windows)
    {
        import core.sys.windows.windows;

        DllHandle loadLib(string libName)
        {
            return LoadLibraryA(libName.toStringz());
        }

        DllProc loadProc(DllHandle libHandle, string procName)
        {
            return GetProcAddress(libHandle, procName.toStringz());
        }

        void unloadLib(DllHandle libHandle)
        {
            FreeLibrary(libHandle);
        }
    }
    else version(Posix)
    {
        import core.sys.posix.dlfcn;

        DllHandle loadLib(string libName)
        {
            return dlopen(libName.toStringz(), RTLD_NOW);
        }

        DllProc loadProc(DllHandle libHandle, string procName)
        {
            return dlsym(libHandle, procName.toStringz());
        }

        void unloadLib(DllHandle libHandle)
        {
            dlclose(libHandle);
        }
    }
    else
    {
        static assert(0, "Unsupport platform.");
    }

    /** Returns true if library was loaded
    */
    @property bool isLoaded() const nothrow
    {
        return (_libHandle !is null);
    }

    /** Returns native handle of the loaded library; otherwise null
    */
    @property DllHandle libHandle() nothrow
    {
        return _libHandle;
    }

    /** Name of the library
    */
    @property string libName() const nothrow
    {
        return _libName;
    }

protected:
    /** Let the derived class to perform further action when library is loaded
    */
    void loaded()
    {}

    /** Let the derived class to perform further action when library is unloaded
    */
    void unloaded()
    {}

private:
    string _libName;
    DllHandle _libHandle;
}

unittest // DllLibrary
{
    import std.stdio : writeln;
    writeln("unittest utl_dynlib.DllLibrary");

    version (Windows)
    {
        // Use any library that is always installed
        auto lib = new DllLibrary("Ws2_32.dll");

        lib.load();
        assert(lib.isLoaded);
        assert(lib.libHandle !is null);

        assert(lib.loadProc("connect") !is null);

        lib.unload();
        assert(!lib.isLoaded);
        assert(lib.libHandle is null);

        assert(lib.loadProc!(No.throwIfError)("connect") is null);
    }
}
