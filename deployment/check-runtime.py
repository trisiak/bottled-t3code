"""Read-only dependency checks plus a temporary executable shared-memory mapping.

Starts no Wine processes and never opens a project or game directory.
"""

import ctypes
import mmap
import os
import shutil
import subprocess
import tempfile


def main() -> int:
    failures = []
    for command in ("wine", "i686-w64-mingw32-gcc", "uv", "unzip"):
        if shutil.which(command) is None:
            failures.append(f"missing command: {command}")
    result = subprocess.run(
        ["dpkg-query", "-W", "-f=${Status}", "wine32:i386"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode or result.stdout != "install ok installed":
        failures.append("wine32:i386 is not installed")
    try:
        ctypes.CDLL("libGL.so.1")
    except OSError as error:
        failures.append(f"libGL.so.1: {error}")
    try:
        stat = os.statvfs("/dev/shm")
        capacity = stat.f_blocks * stat.f_frsize
        print(f"Shared memory: {capacity:,} bytes total; {stat.f_bavail * stat.f_frsize:,} available")
        if capacity < 1024**3:
            failures.append("shared-memory capacity is below 1 GiB")
        # Some Windows mappings request executable pages even for data buffers.
        # Allocate one page, request the same access, but never execute its contents.
        with tempfile.TemporaryFile(prefix="bottle-runtime-check-", dir="/dev/shm") as file:
            file.truncate(mmap.PAGESIZE)
            with mmap.mmap(
                file.fileno(),
                mmap.PAGESIZE,
                flags=mmap.MAP_SHARED,
                prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC,
            ) as buffer:
                buffer[0] = 1
    except OSError as error:
        failures.append(f"executable shared-memory mapping: {error}")
    for failure in failures:
        print(f"FAIL: {failure}")
    if not failures:
        print("PASS: native dependencies and shared-memory mapping; run the workload smoke test next")
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
