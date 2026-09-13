#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'Stage_3_Variant_Discovery_Engine' / 'tests' / 'fmea' / 'run_stage3_fmea_suite.py'


def main() -> int:
    proc = subprocess.run([sys.executable, str(TARGET)], cwd=ROOT)
    return proc.returncode


if __name__ == '__main__':
    raise SystemExit(main())