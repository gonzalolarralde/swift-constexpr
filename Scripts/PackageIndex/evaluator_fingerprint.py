"""Stable evaluator identities for resumable Package Index scans."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess


EVALUATOR_FINGERPRINT_SCHEMA = 1
SWIFTPM_EVALUATOR_PATHS = (
    "Package.swift",
    "Package.resolved",
    "Sources",
    "Tests/PackageLoadingTests/ConstExprManifestCorpusTests.swift",
    "Tests/PackageLoadingTests/ConstExprManifestTestSupport.swift",
)
CONSTEXPR_EVALUATOR_PATHS = ("Package.swift", "Package.resolved", "Sources")


def command_output(command: list[str]) -> str:
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()


def git_output(repository: Path, arguments: list[str]) -> bytes:
    return subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        capture_output=True,
    ).stdout


def repository_state(repository: Path, paths: tuple[str, ...]) -> dict[str, object]:
    """Fingerprint a Git HEAD plus relevant tracked and untracked source changes."""
    head = git_output(repository, ["rev-parse", "HEAD"]).decode().strip()
    tracked_diff = git_output(repository, ["diff", "--binary", "HEAD", "--", *paths])
    untracked_names = sorted(
        name
        for name in git_output(
            repository,
            ["ls-files", "--others", "--exclude-standard", "-z", "--", *paths],
        ).split(b"\0")
        if name
    )
    untracked_digest = hashlib.sha256()
    for encoded_name in untracked_names:
        source = repository / os.fsdecode(encoded_name)
        untracked_digest.update(len(encoded_name).to_bytes(8, "big"))
        untracked_digest.update(encoded_name)
        if source.is_symlink():
            contents = os.fsencode(os.readlink(source))
            kind = b"symlink"
        else:
            contents = source.read_bytes()
            kind = b"file"
        untracked_digest.update(kind)
        untracked_digest.update((source.lstat().st_mode & 0o777).to_bytes(4, "big"))
        untracked_digest.update(len(contents).to_bytes(8, "big"))
        untracked_digest.update(contents)
    tracked_hash = hashlib.sha256(tracked_diff).hexdigest()
    untracked_hash = untracked_digest.hexdigest()
    dirty_hash = hashlib.sha256(
        f"tracked:{tracked_hash}\nuntracked:{untracked_hash}\n".encode()
    ).hexdigest()
    return {
        "head": head,
        "paths": list(paths),
        "dirty": bool(tracked_diff or untracked_names),
        "trackedDiffSha256": tracked_hash,
        "untrackedFilesSha256": untracked_hash,
        "dirtyStateSha256": dirty_hash,
    }


def evaluator_identity(
    repository_root: Path,
    swiftpm: Path,
    configuration: str,
    override: str | None,
) -> dict[str, object]:
    """Return a stable cache identity for the exact evaluator implementation."""
    if override is not None and not override:
        raise ValueError("--evaluator-fingerprint must not be empty")
    payload: dict[str, object] = {
        "schema": EVALUATOR_FINGERPRINT_SCHEMA,
        "configuration": configuration,
    }
    if override is not None:
        payload.update({"kind": "explicit", "override": override})
    else:
        payload.update(
            {
                "kind": "automatic",
                "swiftVersion": command_output(["swift", "--version"]),
                "swiftpm": repository_state(swiftpm, SWIFTPM_EVALUATOR_PATHS),
                "swiftConstExpr": repository_state(
                    repository_root, CONSTEXPR_EVALUATOR_PATHS
                ),
            }
        )
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return {**payload, "fingerprint": hashlib.sha256(encoded).hexdigest()}


def read_json_object(path: Path) -> dict[str, object]:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


def write_json_object(path: Path, value: dict[str, object]) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)
