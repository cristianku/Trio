#!/usr/bin/env python3
"""Print the independent Trio AI source version without modifying the checkout."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def fork_version(repo, committed=False):
    def git(*args):
        return subprocess.check_output(
            ["git", "-C", str(repo), *args], text=True, stderr=subprocess.PIPE
        ).strip()

    committed_config_exists = bool(git("ls-tree", "--name-only", "HEAD", "--", "ForkVersion.json"))
    if committed and committed_config_exists:
        config = json.loads(git("show", "HEAD:ForkVersion.json"))
    else:
        config = json.loads((repo / "ForkVersion.json").read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("ForkVersion.json must contain a version configuration object")
    series = config.get("series", "")
    base = config.get("base_commit", "")
    if not isinstance(series, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", series):
        raise ValueError("ForkVersion.json series must be major.minor (for example 0.1)")
    if not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("ForkVersion.json base_commit must be a full commit SHA")
    if git("rev-parse", "--is-shallow-repository") == "true":
        raise ValueError("Full Git history required: use fetch-depth: 0 in Actions or git fetch --unshallow")

    # Following only first parents counts an upstream merge once. Its imported
    # commits must not suddenly inflate this fork's revision number.
    history = git("rev-list", "--first-parent", "HEAD").splitlines()
    if base not in history:
        raise ValueError("base_commit is not on HEAD's first-parent history; check the branch and version base")
    revision = history.index(base)
    version = f"{series}.{revision}+{history[0][:10]}"
    # Before the first versioning commit, even a CI build uses an uncommitted
    # manifest. Never present that bootstrap value as a clean source version.
    if not committed_config_exists or (
        not committed and git("status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none")
    ):
        version += ".dirty"
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument(
        "--committed", action="store_true",
        help="Identify committed source only; ignore signing/generated worktree changes in CI"
    )
    args = parser.parse_args()
    try:
        print(fork_version(args.repo, args.committed))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"fork-version: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
