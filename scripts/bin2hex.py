#!/usr/bin/env python3
"""Convert a flat binary (riscv objcopy -O binary) to $readmemh format:
one 32-bit little-endian word per line, hex, no addresses."""
import struct
import sys


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input.bin> <output.hex>")

    with open(sys.argv[1], "rb") as f:
        data = f.read()
    data += b"\x00" * ((4 - len(data) % 4) % 4)  # pad to word boundary

    with open(sys.argv[2], "w") as out:
        for i in range(0, len(data), 4):
            (word,) = struct.unpack("<I", data[i : i + 4])
            out.write(f"{word:08x}\n")


if __name__ == "__main__":
    main()
