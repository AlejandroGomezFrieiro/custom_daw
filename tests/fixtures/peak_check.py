"""A one-shot check for the tests of paw.lsp: given a render subject (a JSON
file, as `{input}` names it), it prints a finding when the render's peak is
over `--over` dBFS, as MIDI LSP's one-shot servers print theirs.
`--garbage` prints something that is not JSON.

    python3 peak_check.py [--over DB] [--garbage] FILE
"""

import json
import math
import sys

args = sys.argv[1:]
if "--garbage" in args:
    print("this is not JSON")
    sys.exit(0)
over = float(args[args.index("--over") + 1]) if "--over" in args else 0.0
doc = json.load(open(args[-1]))
peak = 20 * math.log10(max(doc.get("peak") or 0, 1e-9))
findings = []
if peak > over:
    findings.append({"rule": "peak", "severity": "warning", "time_s": 0.5,
                     "message": f"{doc['path'].rsplit('/', 1)[-1]} peaks at {peak:.1f} dBFS, over {over:.1f}"})
findings.append({"rule": "quiet", "severity": "off", "message": "left out"})
print(json.dumps({"findings": findings}))
