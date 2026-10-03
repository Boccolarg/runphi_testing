#!/usr/bin/env python3
"""mkcpio.py <dir> - write <dir> as a newc cpio archive (an initramfs) to stdout.

The board's busybox cpio can only extract. Entries keep mode, owner, mtime,
symlink targets and device numbers; hard links become separate copies.
"""
import os
import stat
import sys


def header(ino, st, size, name):
    rdev = st.st_rdev if stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode) else 0
    fields = (ino, st.st_mode, st.st_uid, st.st_gid, 1, int(st.st_mtime), size,
              0, 0, os.major(rdev), os.minor(rdev), len(name) + 1, 0)
    return b"070701" + b"".join(b"%08X" % f for f in fields) + name + b"\0"


def pad(n):
    return b"\0" * (-n % 4)


def main():
    root = sys.argv[1]
    out = sys.stdout.buffer
    ino = 1
    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames) + sorted(filenames):
            entries.append(os.path.join(dirpath, name))
    for path in entries:
        st = os.lstat(path)
        name = os.path.relpath(path, root).encode()
        if stat.S_ISLNK(st.st_mode):
            data = os.readlink(path).encode()
        elif stat.S_ISREG(st.st_mode):
            with open(path, "rb") as f:
                data = f.read()
        else:
            data = b""
        h = header(ino, st, len(data), name)
        out.write(h + pad(len(h)) + data + pad(len(data)))
        ino += 1
    trailer = header(0, os.stat_result((0,) * 10), 0, b"TRAILER!!!")
    out.write(trailer + pad(len(trailer)))


if __name__ == "__main__":
    main()
