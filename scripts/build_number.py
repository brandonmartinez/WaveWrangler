#!/usr/bin/env python3
"""Generate the app's per-build Info.plist preprocessor definition."""

import argparse
from datetime import datetime, timezone
from pathlib import Path
import re
from typing import Optional


def write_build_number(path: Path, now: Optional[datetime] = None) -> str:
    number = int((now or datetime.now(timezone.utc)).strftime("%Y%m%d%H%M%S%f")[:17])
    if path.exists():
        previous = re.fullmatch(r"#define WW_BUILD_NUMBER ([0-9]{17})\n", path.read_text(encoding="ascii"))
        if previous is None:
            raise ValueError(f"Invalid generated build-number header: {path}")
        number = max(number, int(previous.group(1)) + 1)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#define WW_BUILD_NUMBER {number}\n", encoding="ascii")
    return str(number)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("header", type=Path)
    arguments = parser.parse_args()
    print(f"WaveWrangler build {write_build_number(arguments.header)}")
