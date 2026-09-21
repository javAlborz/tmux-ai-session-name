#!/usr/bin/env python3
"""Build a deterministic, product-neutral distribution from upstream sources."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0"


def contents():
    names = ["scripts/rename-windows.sh", "scripts/rename-daemon.sh",
             "scripts/manual-name.sh", "scripts/name-audit.py",
             "scripts/session-dir-session-name.sh", "shared/integration.py",
             "pi/tmux-session-status.ts"]
    names += [str(p.relative_to(ROOT)) for p in sorted((ROOT / "status").glob("*")) if p.is_file()]
    result = {name: (ROOT / name).read_bytes() for name in names}
    result["scripts/session-name-for-pane.sh"] = (ROOT / "shared/session-name-for-pane.sh").read_bytes()
    for name, data in result.items():
        if re.search(rb"codex|claude|ufst|ccta", name.encode() + data, re.I):
            raise ValueError("Non-generic content in " + name)
    return result


def build(output):
    files = contents()
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=str(ROOT)).decode().strip()
    manifest = {"schema": 1, "name": "tmux-ai-session-generic", "version": VERSION,
                "repository": "https://github.com/javAlborz/tmux-ai-session-name",
                "source_commit": source,
                "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())}}
    files["manifest.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ("tmux-ai-session-generic-" + VERSION + ".tar.gz")
    with archive.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as tar:
            for name, data in sorted(files.items()):
                info = tarfile.TarInfo("tmux-ai-session/" + name)
                info.size = len(data)
                info.mode = 0o755 if name.endswith((".sh", ".py")) else 0o644
                tar.addfile(info, io.BytesIO(data))
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(checksum + "  " + archive.name + "\n")
    print(json.dumps({"archive": str(archive), "sha256": checksum, "source_commit": source}))
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    build(parser.parse_args().out)
