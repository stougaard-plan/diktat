#!/bin/zsh
# Tester D1 og D2 i scripts/transcribe uden rigtig lyd (se transcribe_python_test.py). Kør med: scripts/tests/transcribe-python-test.sh [python3]
ROOT="${0:A:h:h:h}"
PY="${1:-/usr/bin/python3}"
"$PY" "$ROOT/scripts/tests/transcribe_python_test.py"
