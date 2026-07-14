#!/usr/bin/env python3
"""Compare two reportable CoreMark logs from the same benchmark image.

The Makefile's ``coremark-compare`` target builds one 720-iteration image,
runs it on the in-order and OoO models, then calls this parser.  It refuses
logs that CoreMark itself did not validate or whose iteration/CRC/compiler
profiles differ, so the printed delta is an apples-to-apples result.
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Result:
    path: Path
    iterations: int
    iterations_per_sec: float
    cycles: int
    instret: int
    ipc: float
    lockstep: int
    compiler: str
    flags: str
    crcs: tuple[str, str, str]


def require(pattern: str, text: str, path: Path, *, flags: int = 0) -> str:
    match = re.search(pattern, text, flags)
    if not match:
        raise ValueError(f"{path}: missing expected pattern: {pattern}")
    return match.group(1)


def parse(path: Path) -> Result:
    data = path.read_bytes()
    # MSYS `tee` writes UTF-8; PowerShell's legacy Tee-Object writes UTF-16LE.
    # Accept both so independently captured evidence is still comparable.
    encoding = (
        "utf-16"
        if data.startswith((b"\xff\xfe", b"\xfe\xff"))
        else "utf-8-sig"
    )
    text = data.decode(encoding).replace("\r\n", "\n").replace("\r", "\n")
    if "Correct operation validated" not in text:
        raise ValueError(f"{path}: CoreMark did not validate this run")
    if "no divergence" not in text:
        raise ValueError(f"{path}: lockstep success line is missing")

    perf = re.search(
        r"\[sim\] perf: cycles=(\d+) instret=(\d+) ipc=([0-9.]+)", text
    )
    if not perf:
        raise ValueError(f"{path}: simulator performance counters are missing")

    return Result(
        path=path,
        iterations=int(
            require(r"^Iterations\s*:\s*(\d+)$", text, path, flags=re.M)
        ),
        iterations_per_sec=float(
            require(r"^CoreMark 1\.0\s*:\s*([0-9.]+)\s*/", text, path, flags=re.M)
        ),
        cycles=int(perf.group(1)),
        instret=int(perf.group(2)),
        ipc=float(perf.group(3)),
        lockstep=int(
            require(
                r"^\[lockstep\]\s+(\d+) instructions compared",
                text,
                path,
                flags=re.M,
            )
        ),
        compiler=require(r"^Compiler version\s*:\s*(.+)$", text, path, flags=re.M),
        flags=require(r"^Compiler flags\s*:\s*(.+)$", text, path, flags=re.M),
        crcs=(
            require(r"^\[0\]crclist\s*:\s*(0x[0-9a-f]+)$", text, path, flags=re.M),
            require(
                r"^\[0\]crcmatrix\s*:\s*(0x[0-9a-f]+)$",
                text,
                path,
                flags=re.M,
            ),
            require(r"^\[0\]crcstate\s*:\s*(0x[0-9a-f]+)$", text, path, flags=re.M),
        ),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("in_order_log", type=Path)
    parser.add_argument("ooo_log", type=Path)
    parser.add_argument(
        "--reference-mhz",
        type=float,
        default=50.0,
        help="clock reference used by the CoreMark port (default: 50)",
    )
    args = parser.parse_args()

    in_order = parse(args.in_order_log)
    ooo = parse(args.ooo_log)
    for field in ("iterations", "compiler", "flags", "crcs"):
        if getattr(in_order, field) != getattr(ooo, field):
            raise ValueError(
                f"logs are not comparable: {field} differs "
                f"({getattr(in_order, field)!r} != {getattr(ooo, field)!r})"
            )

    io_cm_mhz = in_order.iterations_per_sec / args.reference_mhz
    oo_cm_mhz = ooo.iterations_per_sec / args.reference_mhz
    improvement = 100.0 * (ooo.iterations_per_sec / in_order.iterations_per_sec - 1.0)
    cycle_reduction = 100.0 * (1.0 - ooo.cycles / in_order.cycles)

    print("CoreMark same-image comparison")
    print(f"  iterations       : {in_order.iterations}")
    print(f"  compiler         : {in_order.compiler} {in_order.flags}")
    print(
        f"  in-order         : {io_cm_mhz:.6f} CoreMark/MHz, "
        f"{in_order.cycles:,} cycles, IPC {in_order.ipc:.3f}"
    )
    print(
        f"  OoO              : {oo_cm_mhz:.6f} CoreMark/MHz, "
        f"{ooo.cycles:,} cycles, IPC {ooo.ipc:.3f}"
    )
    print(
        f"  improvement      : {improvement:.2f}% CoreMark/MHz, "
        f"{cycle_reduction:.2f}% fewer cycles"
    )
    print(
        f"  lockstep checked : {in_order.lockstep:,} / "
        f"{ooo.lockstep:,} instructions"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
