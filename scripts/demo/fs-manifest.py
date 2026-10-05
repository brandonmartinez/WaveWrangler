#!/usr/bin/env python3
"""Metadata-only file-system manifest for proving a folder was not written to.

    fs-manifest.py snapshot ROOT OUT.json   record every entry under ROOT
    fs-manifest.py compare  BEFORE.json AFTER.json

Each entry stores (SHA-256 of the relative path, type, size, mtime_ns, ctime_ns, inode) from lstat.
File contents are never opened, read or hashed, symbolic links are not followed, and real paths
are not stored. Only aggregate counts are printed, so the output is safe to quote in evidence.
Write OUT.json outside every repository/worktree (for example under $TMPDIR).
"""
import hashlib
import json
import os
import stat
import subprocess
import sys


def refuse_repo_path(path):
    folder = os.path.dirname(os.path.abspath(path)) or "."
    probe = subprocess.run(
        ["git", "-C", folder, "rev-parse", "--is-inside-work-tree"],
        capture_output=True, text=True,
    )
    if probe.returncode == 0 and probe.stdout.strip() == "true":
        sys.exit("error: refusing to write a manifest inside a Git working tree")


def path_key(relative):
    return hashlib.sha256(relative.encode("utf-8", "surrogateescape")).hexdigest()


def entry(st):
    return {
        "type": kind_of(st),
        "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
        "ctime_ns": st.st_ctime_ns,
        "inode": st.st_ino,
    }


def kind_of(st):
    if stat.S_ISLNK(st.st_mode):
        return "symlink"
    if stat.S_ISDIR(st.st_mode):
        return "dir"
    if stat.S_ISREG(st.st_mode):
        return "file"
    return "other"


def snapshot(root, out):
    refuse_repo_path(out)
    root = os.path.abspath(root)
    entries = {path_key("."): entry(os.lstat(root))}
    counts = {"file": 0, "dir": 0, "symlink": 0, "other": 0, "file_bytes": 0}
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            full = os.path.join(current, name)
            st = os.lstat(full)
            item = entry(st)
            counts[item["type"]] += 1
            if item["type"] == "file":
                counts["file_bytes"] += st.st_size
            entries[path_key(os.path.relpath(full, root))] = item
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"entries": entries, "counts": counts}, handle, sort_keys=True)
    print(json.dumps(counts, sort_keys=True))


def compare(before_path, after_path):
    with open(before_path, encoding="utf-8") as handle:
        before = json.load(handle)["entries"]
    with open(after_path, encoding="utf-8") as handle:
        after = json.load(handle)["entries"]
    primary = {"type", "size", "mtime_ns", "inode"}
    changed = 0
    ctime_only = 0
    for key in set(before) & set(after):
        diff = {field for field in before[key] if before[key][field] != after[key].get(field)}
        if diff & primary:
            changed += 1
        elif "ctime_ns" in diff:
            ctime_only += 1
    result = {
        "entries_before": len(before),
        "entries_after": len(after),
        "added": len(set(after) - set(before)),
        "removed": len(set(before) - set(after)),
        "changed_type_size_mtime_or_inode": changed,
        "changed_ctime_only": ctime_only,
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not (result["added"] or result["removed"] or changed or ctime_only) else 1


def main(argv):
    if len(argv) == 4 and argv[1] == "snapshot":
        snapshot(argv[2], argv[3])
        return 0
    if len(argv) == 4 and argv[1] == "compare":
        return compare(argv[2], argv[3])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
