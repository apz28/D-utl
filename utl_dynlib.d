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

module pham.utl_dynlib;

import std.exception : Exception;
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

    this(string aMessage, string aLibName, Exception aNext = null)
    {
        this(aMessage, getLastErrorString(), getLastErrorCode(), aLibName, aNext);
    }

    this(string aMessage, string aLastErrorMessage, uint aLastErrorCode, string aLibName,
        Exception aNext = null)
    {
        errorCode = aLastErrorCode;
        libName = aLibName;
        super(concateLineIf(aMessage, aLastErrorMessage), aNext);
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
private:
    string _libName;
    DllHandle _libHandle;

protected:
    /** Let the derived class to perform further action when library is loaded
    */
    void loaded()
    {}

    /** Let the derived class to perform further action when library is unloaded
    */
    void unloaded()
    {}

public:
    this(string aLibName)
    {
        _libName = aLibName;
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

    /** Load the function address using aProcName
        Params:
            aProcName = Name of the function
    
        Throws:
            DllException if loadProc fails if throwIfError is true
    
        Returns: 
            Pointer to the function
    
        Example:
            fct = loadProc("AFunctionNameToBeLoaded...")

    */
    final DllProc loadProc(Flag!"throwIfError" throwIfError = Yes.throwIfError)(string aProcName)
    {
        DllProc res;
        if (isLoaded)
            res = loadProc(_libHandle, aProcName);

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
                    string err = format(DllMessage.eLoadFunction, _libName, aProcName);
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

        DllHandle loadLib(string aLibName)
        {
            return LoadLibraryA(aLibName.toStringz());
        }

        DllProc loadProc(DllHandle aLibHandle, string aProcName)
        {
            return GetProcAddress(aLibHandle, aProcName.toStringz());
        }

        void unloadLib(DllHandle aLibHandle)
        {
            FreeLibrary(aLibHandle);
        }
    }
    else version(Posix)
    {
        import core.sys.posix.dlfcn;

        DllHandle loadLib(string aLibName)
        {
            return dlopen(aLibName.toStringz(), RTLD_NOW);
        }

        DllProc loadProc(DllHandle aLibHandle, string aProcName)
        {
            return dlsym(aLibHandle, aProcName.toStringz());
        }

        void unloadLib(DllHandle aLibHandle)
        {
            dlclose(aLibHandle);
        }
    }
    else
    {
        static assert(0, "Unsupport platform.");
    }

@property:
    /** Returns true if library was loaded
    */
    bool isLoaded() const nothrow
    { 
        return (_libHandle !is null); 
    }

    /** Returns native handle of the loaded library; otherwise null
    */
    DllHandle libHandle() nothrow
    {
        return _libHandle;
    }

    /** Name of the library
    */
    string libName() const nothrow
    {
        return _libName;
    }
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
