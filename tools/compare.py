# Checks that the Swift fish matches the Python original while it draws itself: renders the same
# frames with both and compares them cell by cell (letters, and colours).
#
#   swift build -c release
#   python tools/compare.py               (needs numpy and pygame-ce: pip install numpy pygame-ce)

import subprocess
import os
import sys
import tempfile
import warnings
from pathlib import Path

import numpy as np

warnings.filterwarnings("ignore")
HERE = Path(__file__).resolve().parent
# the original, betta_fish.py, from github.com/dwcminh/ascii-art: cloned beside this repository, or
# wherever BETTA_FISH_PY says
ORIGINAL = Path(os.environ.get("BETTA_FISH_PY", HERE.parent.parent / "ascii-art" / "BETTA-FISH" / "betta_fish.py"))
if not ORIGINAL.exists():
    sys.exit(f"betta_fish.py isn't at {ORIGINAL}: clone https://github.com/dwcminh/ascii-art beside this repository, "
             "or set BETTA_FISH_PY to where it is")
sys.path.insert(0, str(ORIGINAL.parent))
import betta_fish as b  # noqa: E402

# the particles of the original are left out of the Swift one
b.motes = lambda t: []
b.fin_motes = lambda t: []
b.glints = lambda t: []
b.sparks = lambda t: []
b.BURSTS = []
b.BUBBLE_AT = np.zeros((0, 5))

BIN = HERE.parent / ".build" / "release" / "BettaLite"
rows, cols = b.ROWS, b.COLS
worst = 100.0
print(f"{'t':>6} {'lit cells':>9} {'same letter':>11} {'same lit/unlit':>14} {'colour diff (mean, cells > 0.1)':>32}")
with tempfile.TemporaryDirectory() as tmp:
    for t in [0.5, 1.5, 2.7, 3.3, 3.9, 4.1]:
        out = Path(tmp) / f"{t}.bin"
        subprocess.run([str(BIN), "--dump", str(t), str(out)], check=True)
        raw = out.read_bytes()
        sc = np.frombuffer(raw[: rows * cols * 2], np.int16).reshape(rows, cols)
        scol = np.frombuffer(raw[rows * cols * 2:], np.float32).reshape(rows, cols, 3)
        pc, pcol, _ = b.frame(t, cols, rows, b.W / b.H)
        lit = (pc > 0) | (sc > 0)
        same = (pc == sc)[lit].mean() * 100
        occ = ((pc > 0) == (sc > 0))[lit].mean() * 100
        d = np.abs(np.clip(pcol, 0, 1) - np.clip(scol, 0, 1)).max(-1)
        worst = min(worst, same)
        print(f"{t:6.1f} {lit.sum():9d} {same:10.1f}% {occ:13.1f}% {d[lit].mean():20.4f} {(d[lit] > 0.1).sum():8d}")
print("the same, cell for cell" if worst == 100 else "they differ")
