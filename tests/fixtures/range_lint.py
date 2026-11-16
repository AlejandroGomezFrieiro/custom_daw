"""A small language server of MIDI LSP's protocol, for the tests of daw.lsp.

It marks notes outside a pitch range (initializationOptions `lo` and `hi`,
then `settings`), offers to move each an octave into it, says what a note is
on `midi/hover`, and suggests one note after the cursor on `midi/completion`.
It speaks newline-delimited JSON on stdio, or LSP's Content-Length headers
with `--headers`. `--crash` makes it exit at the first document.

    python3 range_lint.py [--headers] [--crash]
"""

import json
import sys

HEADERS = "--headers" in sys.argv
CRASH = "--crash" in sys.argv
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

opts = {"lo": 48, "hi": 84}
docs = {}


def name(pitch):
    return NAMES[pitch % 12] + str(pitch // 12 - 1)


def read():
    if not HEADERS:
        line = sys.stdin.readline()
        return None if line == "" else (json.loads(line) if line.strip() else {})
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if line == b"":
            return None
        line = line.strip()
        if not line:
            break
        key, _, value = line.decode().partition(":")
        if key.lower() == "content-length":
            length = int(value)
    return json.loads(sys.stdin.buffer.read(length))


def send(message):
    text = json.dumps(message)
    if HEADERS:
        data = text.encode()
        sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
    else:
        sys.stdout.write(text + "\n")
    sys.stdout.flush()


def publish(doc):
    diagnostics = []
    for n in doc["notes"]:
        p = n["pitch"]
        if p < opts["lo"] or p > opts["hi"]:
            to = p + 12 if p < opts["lo"] else p - 12
            diagnostics.append({
                "rule": "range", "code": "range", "severity": "warning", "source": "range-lint",
                "message": f"{name(p)} is outside {name(opts['lo'])}-{name(opts['hi'])}",
                "start": n["start"], "end": n["end"], "notes": [n["id"]],
                "fixes": [{"title": f"Move {name(p)} to {name(to)}", "edits": [{"note": n["id"], "pitch": to}]}],
            })
    send({"jsonrpc": "2.0", "method": "midi/publishDiagnostics",
          "params": {"uri": doc["uri"], "hash": doc["hash"], "diagnostics": diagnostics}})


def answer(method, params):
    if method == "initialize":
        opts.update(params.get("initializationOptions") or {})
        opts.update(params.get("configuration") or {})
        return {"protocolVersion": 2, "serverInfo": {"name": "range-lint", "version": "0.1"},
                "capabilities": {"documents": ["take"], "diagnosticProvider": {"fixes": True},
                                 "hoverProvider": True, "completionProvider": {"lanes": ["notes"]}}}
    if method in ("midi/didOpen", "midi/didChange"):
        if CRASH:
            sys.exit(3)
        docs[params["uri"]] = params
        return {"uri": params["uri"], "hash": params["hash"], "notes": len(params["notes"])}
    if method == "midi/hover":
        doc = docs[params["uri"]]
        if params.get("hash") != doc["hash"]:
            raise ValueError("document changed")
        return {"contents": {"kind": "plaintext", "value": f"{name(params['pitch'])} in range-lint's eyes"}}
    if method == "midi/completion":
        doc = docs[params["uri"]]
        start = params["position"]
        return {"uri": doc["uri"], "hash": doc["hash"], "position": start, "mode": "melody",
                "items": [{"kind": "melody", "label": "middle C", "score": 1.0,
                           "notes": [{"pitch": 60, "start": start, "end": start + doc["ppq"], "vel": 90, "chan": 0}]}]}
    if method == "shutdown":
        return None
    raise KeyError(method)


def main():
    while True:
        message = read()
        if message is None:
            return
        method, params = message.get("method"), message.get("params") or {}
        if method == "exit":
            return
        if method == "workspace/didChangeConfiguration":
            opts.update(params.get("settings") or {})
            for doc in docs.values():
                publish(doc)
            continue
        if "id" not in message:
            continue
        try:
            send({"jsonrpc": "2.0", "id": message["id"], "result": answer(method, params)})
        except KeyError as e:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": f"unknown {e}"}})
        except ValueError as e:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32801, "message": str(e)}})
        if method in ("midi/didOpen", "midi/didChange"):
            publish(params)


main()
