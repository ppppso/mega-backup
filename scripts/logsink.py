#!/usr/bin/python3 -I
"""Copy stdin to stdout and to a log file, rotating it at 1 MB (keeps 3 old files)."""
import os
import sys

MAX_BYTES = 1_000_000
KEEP = 3


def rotate(path):
    for i in range(KEEP - 1, 0, -1):
        if os.path.exists(f"{path}.{i}"):
            os.replace(f"{path}.{i}", f"{path}.{i + 1}")
    os.replace(path, f"{path}.1")


def main():
    path = sys.argv[1]
    out = sys.stdout.buffer
    f = open(path, "ab")
    for line in sys.stdin.buffer:
        out.write(line)
        out.flush()
        f.write(line)
        f.flush()
        if f.tell() > MAX_BYTES:
            f.close()
            rotate(path)
            f = open(path, "ab")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
