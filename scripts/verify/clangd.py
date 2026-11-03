#!/usr/bin/env python3
"""Exercise the packaged clangd over LSP, using only the bundle's compiler driver."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading


def check(root, target):
    root = Path(root).resolve()
    with tempfile.TemporaryDirectory(prefix="clangd smoke ") as directory:
        # clangd canonicalizes definition/rename URIs. macOS's temporary
        # directory can use /var while its canonical path starts with /private/var.
        # Use the same physical path for the compilation database and all LSP URIs.
        work = Path(directory).resolve()
        directory = str(work)
        source = work / "main.cpp"
        code = ("#include <vector>\n#include <stddef.h>\n"
                "#ifndef _LIBCPP_VERSION\n#error expected libc++ from the target toolchain\n#endif\n"
                "int value = 7;\n"
                "int main() { std::vector<int> v{value}; return v[0] + missing; }\n")
        source.write_text(code)
        driver = str(root / "bin" / (target + "-clang++"))
        (work / "compile_commands.json").write_text(json.dumps([{
            "directory": directory, "file": str(source),
            "arguments": [driver, "-std=c++17", "-c", str(source)],
        }]))
        messages = queue.Queue()
        with (work / "clangd.log").open("w+") as log:
            # Absolute executable and query-driver allowlist: no system clangd or download.
            proc = subprocess.Popen([str(root / "bin/clangd"), "--background-index=false",
                                     "--clang-tidy=false", "--enable-config=false",
                                     "--query-driver=" + driver,
                                     "--compile-commands-dir=" + directory],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)

            def reader():
                try:
                    while True:
                        headers = {}
                        while True:
                            line = proc.stdout.readline()
                            if not line:
                                raise EOFError("clangd closed stdout")
                            if line == b"\r\n":
                                break
                            key, value = line.decode().split(":", 1)
                            headers[key.lower()] = value.strip()
                        messages.put(json.loads(proc.stdout.read(int(headers["content-length"]))))
                except Exception as error:
                    messages.put(error)

            threading.Thread(target=reader, daemon=True).start()

            def send(method, params, ident=None):
                message = dict(jsonrpc="2.0", method=method, params=params)
                if ident is not None:
                    message["id"] = ident
                data = json.dumps(message).encode()
                proc.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
                proc.stdin.flush()

            def receive(predicate):
                import time
                deadline = time.monotonic() + 45
                while True:
                    message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
                    if isinstance(message, Exception):
                        raise message
                    if predicate(message):
                        if "error" in message:
                            raise RuntimeError(message["error"])
                        return message
                    if time.monotonic() >= deadline:
                        raise TimeoutError("LSP response timed out")

            try:
                send("initialize", {"processId": os.getpid(), "rootUri": work.as_uri(),
                                    "capabilities": {}}, 1)
                assert receive(lambda m: m.get("id") == 1)["result"]["capabilities"]
                send("initialized", {})
                send("textDocument/didOpen", {"textDocument": {
                    "uri": source.as_uri(), "languageId": "cpp", "version": 1, "text": code}})
                diagnostics = receive(lambda m: m.get("method") == "textDocument/publishDiagnostics"
                                      and m["params"]["uri"] == source.as_uri())["params"]["diagnostics"]
                errors = [d for d in diagnostics if d.get("severity") == 1]
                assert len(errors) == 1 and "missing" in errors[0]["message"], diagnostics
                position = {"line": 6, "character": code.splitlines()[6].index("value") + 1}
                params = {"textDocument": {"uri": source.as_uri()}, "position": position}
                send("textDocument/definition", params, 2)
                locations = receive(lambda m: m.get("id") == 2)["result"]
                assert locations and locations[0]["uri"] == source.as_uri(), locations
                assert locations[0]["range"]["start"]["line"] == 5, locations
                send("textDocument/rename", dict(params, newName="renamed_value"), 3)
                changes = receive(lambda m: m.get("id") == 3)["result"]["changes"]
                edits = changes[source.as_uri()]
                assert len(edits) == 2 and all(e["newText"] == "renamed_value" for e in edits), changes
                send("shutdown", None, 4)
                receive(lambda m: m.get("id") == 4)
                send("exit", None)
                assert proc.wait(timeout=10) == 0
            except Exception:
                log.flush()
                log.seek(0)
                sys.stderr.write(log.read())
                raise
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait()


if __name__ == "__main__":
    check(*sys.argv[1:])
