#!/usr/bin/env python3
"""Generate an elide-toolchain manifest.json or CycloneDX 1.6 SBOM on stdout.

Usage: gen-manifest.py manifest|sbom

Reads versions.env and .gitmodules from $ROOT_DIR, and bundle facts from the environment
exported by scripts/lib/env.sh (HOST_OS, HOST_ARCH, ALL_TARGETS, TOOLCHAIN_VERSION) plus
ENABLED_COMPONENTS (space-separated).
"""
import datetime
import json
import os
import re
import subprocess
import sys
import uuid

ROOT = os.environ["ROOT_DIR"]


def read_env_file(path):
    out = {}
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            m = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
            if not m:
                continue
            key, val = m.groups()
            val = re.split(r"\s+#", val, maxsplit=1)[0].strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            out[key] = val
    return out


def submodules():
    """{path: url} for every submodule."""
    def regexp(pattern):
        res = subprocess.run(
            ["git", "config", "-f", os.path.join(ROOT, ".gitmodules"), "--get-regexp", pattern],
            capture_output=True, text=True, check=True)
        return dict(line.split(None, 1) for line in res.stdout.splitlines())
    paths = regexp(r"^submodule\..*\.path$")
    urls = regexp(r"^submodule\..*\.url$")
    return {path: urls[key[: -len(".path")] + ".url"] for key, path in paths.items()}


def var_of(path):
    return path.upper().replace("-", "_")


def component_info(env, path):
    v = var_of(path)
    return {"version": env.get(v + "_VERSION") or env.get(v + "_REF", ""), "revision": env.get(v + "_REV", "")}


def libc_of(triple):
    if triple.endswith("-linux-musl"):
        return "musl"
    if triple.endswith("-linux-gnu"):
        return "glibc"
    return "darwin"


def target_entry(env, triple):
    libc = libc_of(triple)
    entry = {"triple": triple, "libc": libc}
    if libc == "musl":
        entry.update(libcVersion=env["MUSL_VERSION"], libcRevision=env.get("MUSL_REV", ""))
    elif libc == "glibc":
        entry.update(libcVersion=env["GLIBC_FLOOR"], libcRevision=env.get("GLIBC_REV", ""))
    else:
        entry["macosMin"] = env["MACOS_MIN"]
    if libc != "darwin":
        key = "AMD64" if triple.startswith("x86_64") else "ARM64"
        entry.update(march=env["MARCH_" + key], mtune=env["MTUNE_" + key])
    return entry


def core_components(host_os):
    return ["llvm", "mimalloc"] + (["musl", "glibc"] if host_os == "linux" else [])


def git_revision():
    res = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True)
    return res.stdout.strip()


def manifest(env):
    host_os, host_arch = os.environ["HOST_OS"], os.environ["HOST_ARCH"]
    triples = os.environ["ALL_TARGETS"].split()
    host = {"os": host_os, "arch": host_arch}
    if host_os == "linux":
        key = "AMD64" if host_arch == "amd64" else "ARM64"
        host.update(glibcFloor=env["GLIBC_FLOOR"], march=env["MARCH_" + key])
    else:
        host["macosMin"] = env["MACOS_MIN"]
    return {
        "name": env["TOOLCHAIN_NAME"],
        "version": os.environ.get("TOOLCHAIN_VERSION") or env["TOOLCHAIN_VERSION"],
        "revision": git_revision(),
        "host": host,
        "llvmMajor": env["LLVM_VERSION"].split(".")[0],
        "targets": [target_entry(env, t) for t in triples],
        "enabledComponents": os.environ.get("ENABLED_COMPONENTS", "").split(),
        "components": {p: component_info(env, p) for p in sorted(submodules())},
        "cflagsProfile": f"{host_os}-{host_arch}",
    }


def purl(url, name, version, rev):
    m = re.match(r"https://github\.com/([^/]+)/([^/.]+)(\.git)?$", url)
    if m:
        return f"pkg:github/{m.group(1)}/{m.group(2)}@{rev or version}"
    return f"pkg:generic/{name}@{version}?vcs_url=git%2B{url}%40{rev}"


def sbom(env):
    m = manifest(env)
    urls = submodules()
    wanted = core_components(m["host"]["os"]) + m["enabledComponents"]
    comps = []
    for name in sorted(set(wanted)):
        info = m["components"].get(name, {"version": "", "revision": ""})
        url = urls.get(name, "")
        comps.append({
            "type": "library",
            "name": name,
            "version": info["version"],
            "purl": purl(url, name, info["version"], info["revision"]),
            "externalReferences": [{"type": "vcs", "url": url}] if url else [],
        })
    return {
        "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {
                "type": "application",
                "name": m["name"],
                "version": m["version"],
                "purl": f"pkg:generic/elide/{m['name']}@{m['version']}",
                "supplier": {"name": "Elide", "url": ["https://elide.dev"]},
            },
        },
        "components": comps,
    }


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("manifest", "sbom"):
        print(__doc__, file=sys.stderr)
        return 2
    env = read_env_file(os.path.join(ROOT, "versions.env"))
    doc = manifest(env) if sys.argv[1] == "manifest" else sbom(env)
    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
