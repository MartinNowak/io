/**
   Files

   License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0).
   Authors: Martin Nowak
   Source: $(PHOBOSSRC std/io/net/_package.d)
*/
module std.io.file;

import std.io.exception : enforce;
import std.io.internal.string;

version (Posix)
{
    import core.sys.posix.sys.uio : readv, writev;
    import core.sys.posix.unistd : close, read, write;
    import core.sys.posix.fcntl;
    import std.io.internal.iovec : tempIOVecs;

    enum O_BINARY = 0;
}
else version (Windows)
{
    import core.sys.windows.windef;
    import core.sys.windows.winbase;
    import core.stdc.stdio : O_RDONLY, O_WRONLY, O_RDWR, O_APPEND, O_CREAT,
        O_TRUNC, O_BINARY;
}
else
    static assert(0, "unimplemented");

/// File open mode
enum Mode
{
    read = O_RDONLY, /// open for reading only
    write = O_WRONLY, /// open for writing only
    readWrite = O_RDWR, /// open for reading and writing
    append = O_APPEND, /// open in append mode
    create = O_CREAT, /// create file if missing
    truncate = O_TRUNC, /// truncate existing file
    binary = O_BINARY, /// open in binary mode
}

/**
   Convert `fopen` string modes to `Mode` enum values.
   The mode `m` can be one of the following strings.

   $(TABLE
     $(THEAD mode, meaning)
     $(TROW `"r"`, open for reading)
     $(TROW `"r+"`, open for reading)
     $(TROW `"w"`, create or truncate and open for writing)
     $(TROW `"w+"`, create or truncate and open for reading and writing)
     $(TROW `"a"`, create or truncate and open for appending)
     $(TROW `"a+"`, create or truncate and open for reading and appending)
   )

   The mode string can be followed by a `"b"` flag to open files in
   binary mode. This only has an effect on Windows.

   Params:
     m = fopen mode to convert to `Mode` enum

   Macros:
     THEAD=$(TR $(THX $1, $+))
     THX=$(TH $1)$(THX $+)
     TROW=$(TR $(TDX $1, $+))
     TDX=$(TD $1)$(TDX $+)
 */
enum Mode mode(string m) = getMode(m);

///
unittest
{
    assert(mode!"r" == Mode.read);
    assert(mode!"r+" == Mode.readWrite);
    assert(mode!"w" == (Mode.create | Mode.truncate | Mode.write));
    assert(mode!"w+" == (Mode.create | Mode.truncate | Mode.readWrite));
    assert(mode!"a" == (Mode.create | Mode.write | Mode.append));
    assert(mode!"a+" == (Mode.create | Mode.readWrite | Mode.append));
    assert(mode!"rb" == (Mode.read | Mode.binary));
    assert(mode!"r+b" == (Mode.readWrite | Mode.binary));
    assert(mode!"wb" == (Mode.create | Mode.truncate | Mode.write | Mode.binary));
    assert(mode!"w+b" == (Mode.create | Mode.truncate | Mode.readWrite | Mode.binary));
    assert(mode!"ab" == (Mode.create | Mode.write | Mode.append | Mode.binary));
    assert(mode!"a+b" == (Mode.create | Mode.readWrite | Mode.append | Mode.binary));
    static assert(!__traits(compiles, mode!"xyz"));
}

private Mode getMode(string m)
{
    switch (m) with (Mode)
    {
    case "r":
        return read;
    case "r+":
        return readWrite;
    case "w":
        return write | create | truncate;
    case "w+":
        return readWrite | create | truncate;
    case "a":
        return write | create | append;
    case "a+":
        return readWrite | create | append;
    case "rb":
        return read | binary;
    case "r+b":
        return readWrite | binary;
    case "wb":
        return write | create | truncate | binary;
    case "w+b":
        return readWrite | create | truncate | binary;
    case "ab":
        return write | create | append | binary;
    case "a+b":
        return readWrite | create | append | binary;
    default:
        assert(0, "Unknown open mode '" ~ m ~ "'.");
    }
}

/**
 */
struct File
{
@safe @nogc:
    /**
       Open a file at `path` with the options specified in `mode`.

       Params:
         path = filesystem path
         mode = file open flags
    */
    this(S)(S path, Mode mode = mode!"r") @trusted if (isStringLike!S)
    {
        version (Posix)
        {
            import std.internal.cstring : tempCString;

            fd = .open(tempCString(path), mode);
        }
        else
        {
            import std.internal.cstring : tempCString;

            // FIXME: tempCStringW produces corrupted string
            fd = .CreateFileA(tempCString(path), accessMask(mode), shareMode(mode),
                    null, creationDisposition(mode), FILE_ATTRIBUTE_NORMAL, null);
        }
        enforce(fd != INVALID_HANDLE_VALUE, {
            auto s = String("opening ");
            s ~= path;
            s ~= " failed";
            return s.move;
        });
    }

    /// take ownership of an existing file handle
    version (Posix)
        this(int fd) pure nothrow
    {
        this.fd = fd;
    }
    else version (Windows)
        this(HANDLE h) pure nothrow
    {
        this.fd = h;
    }

    ///
    ~this() scope
    {
        close();
    }

    /// close the file
    void close() scope @trusted
    {
        if (fd == INVALID_HANDLE_VALUE)
            return;
        version (Posix) enforce(!.close(fd), "close failed".String);
        else
            enforce(CloseHandle(fd), "close failed".String);
        fd = INVALID_HANDLE_VALUE;
    }

    /// return whether file is open
    bool isOpen() const scope
    {
        return fd != INVALID_HANDLE_VALUE;
    }

    ///
    unittest
    {
        File f;
        assert(!f.isOpen);
        f = File("LICENSE.txt");
        assert(f.isOpen);
        f.close;
        assert(!f.isOpen);
    }

    /**
       Read from file into buffer.

       Params:
         buf = buffer to read into
       Returns:
         number of bytes read
    */
    size_t read(scope ubyte[] buf) @trusted scope
    {
        version (Posix)
        {
            immutable ret = .read(fd,  & buf[0], buf.length);
            enforce(ret !=  - 1, "read failed".String);
            return ret;
        }
        else version (Windows)
        {
            assert(buf.length <= uint.max);
            DWORD n;
            immutable ret = ReadFile(fd, &buf[0], cast(uint) buf.length, &n, null);
            enforce(ret, "read failed".String);
            return n;
        }
    }

    ///
    unittest
    {
        auto f = File("LICENSE.txt");
        ubyte[256] buf = void;
        assert(f.read(buf[]) == buf.length);
    }

    /**
       Read from file into multiple buffers.
       The read will be atomic on Posix platforms.

       Params:
         bufs = buffers to read into
       Returns:
         total number of bytes read
    */
    size_t read(scope ubyte[][] bufs...) @trusted scope
    {
        version (Posix)
        {
            auto vecs = tempIOVecs(bufs);
            immutable ret = .readv(fd, vecs.ptr, cast(int) vecs.length);
            enforce(ret !=  - 1, "read failed".String);
            return ret;
        }
        else
        {
            size_t total;
            foreach (b; bufs)
                total += read(b);
            return total;
        }
    }

    ///
    unittest
    {
        auto f = File("LICENSE.txt");
        ubyte[256] buf = void;
        assert(f.read(buf[$ / 2 .. $], buf[0 .. $ / 2]) == buf.length);
    }

    /**
       Write buffer content to file.

       Params:
         buf = buffer to write
       Returns:
         number of bytes written
    */
    size_t write( /*in*/ const scope ubyte[] buf) @trusted scope
    {
        version (Posix)
        {
            immutable ret = .write(fd,  & buf[0], buf.length);
            enforce(ret !=  - 1, "write failed".String);
            return ret;
        }
        else version (Windows)
        {
            assert(buf.length <= uint.max);
            DWORD n;
            immutable ret = WriteFile(fd, &buf[0], cast(uint) buf.length, &n, null);
            enforce(ret, "write failed".String);
            return n;
        }
    }

    ///
    unittest
    {
        auto f = File("temp.txt", mode!"w");
        scope (exit)
            remove("temp.txt");
        ubyte[256] buf = 42;
        assert(f.write(buf[]) == buf.length);
    }

    /**
       Write multiple buffers to file.
       The writes will be atomic on Posix platforms.

       Params:
         bufs = buffers to write
       Returns:
         total number of bytes written
    */
    size_t write( /*in*/ const scope ubyte[][] bufs...) @trusted scope
    {
        version (Posix)
        {
            auto vecs = tempIOVecs(bufs);
            immutable ret = .writev(fd, vecs.ptr, cast(int) vecs.length);
            enforce(ret !=  - 1, "write failed".String);
            return ret;
        }
        else
        {
            size_t total;
            foreach (b; bufs)
                total += write(b);
            return total;
        }
    }

    ///
    unittest
    {
        auto f = File("temp.txt", mode!"w");
        scope (exit)
            remove("temp.txt");
        ubyte[256] buf = 42;
        assert(f.write(buf[$ / 2 .. $], buf[0 .. $ / 2]) == buf.length);
    }

    /// move operator for file
    File move() /*FIXME pure nothrow*/
    {
        auto fd = this.fd;
        this.fd = INVALID_HANDLE_VALUE;
        return File(fd);
    }

    /// not copyable
    @disable this(this);

private:

    version (Posix) enum int INVALID_HANDLE_VALUE = -1;
    version (Posix) int fd = INVALID_HANDLE_VALUE;
    version (Windows) HANDLE fd = INVALID_HANDLE_VALUE;
}

///
unittest
{
    auto f = File("temp.txt", mode!"a+");
    scope (exit)
        remove("temp.txt");
    f.write([0, 1]);
}

private:

version (Windows)
{
@safe @nogc:
    DWORD accessMask(Mode mode)
    {
        switch (mode & (Mode.read | Mode.write | Mode.readWrite | Mode.append))
        {
        case Mode.read:
            return GENERIC_READ;
        case Mode.write:
            return GENERIC_WRITE;
        case Mode.readWrite:
            return GENERIC_READ | GENERIC_WRITE;
        case Mode.write | Mode.append:
            return FILE_GENERIC_WRITE & ~FILE_WRITE_DATA;
        case Mode.readWrite | Mode.append:
            return GENERIC_READ | (FILE_GENERIC_WRITE & ~FILE_WRITE_DATA);
        default:
            enforce(0, "invalid mode for access mask".String);
            assert(0);
        }
    }

    DWORD shareMode(Mode mode)
    {
        // do not lock files
        return FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    }

    DWORD creationDisposition(Mode mode)
    {
        switch (mode & (Mode.create | Mode.truncate))
        {
        case cast(Mode) 0:
            return OPEN_EXISTING;
        case Mode.create:
            return OPEN_ALWAYS;
        case Mode.truncate:
            return TRUNCATE_EXISTING;
        case Mode.create | Mode.truncate:
            return CREATE_ALWAYS;
        default:
            assert(0);
        }
    }
}

@safe unittest
{
    import std.io : isIO;

    static assert(isIO!File);

    static File use(File f)
    {
        ubyte[4] buf = [0, 1, 2, 3];
        f.write(buf);
        f.write([4, 5], [6, 7]);
        return f.move;
    }

    auto f = File("temp.txt", mode!"w");
    f = use(f.move);
    f = File("temp.txt", Mode.read);
    ubyte[4] buf;
    f.read(buf[]);
    assert(buf[] == [0, 1, 2, 3]);
    ubyte[2] a, b;
    f.read(a[], b[]);
    assert(a[] == [4, 5]);
    assert(b[] == [6, 7]);
    remove("temp.txt");
}

version (unittest) private void remove(in char[] path) @trusted @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : unlink;
        import std.internal.cstring : tempCString;

        enforce(unlink(tempCString(path)) != -1, "unlink failed".String);
    }
    else version (Windows)
    {
        import std.internal.cstring : tempCString;

        // FIXME: tempCStringW produces corrupted string
        enforce(DeleteFileA(tempCString(path)), "DeleteFile failed".String);
    }
}
