#!/usr/bin/env bash
# Run all khwan.glass tests: block generation/parsing + CLI smoke suite.
set -e
cd "$(dirname "$0")/.."
python3 tests/test_blockgen.py
python3 tests/test_smoke.py
