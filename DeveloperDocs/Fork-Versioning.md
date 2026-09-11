# Trio AI versioning

This fork has its own source version, for example **Trio AI 0.1.12+abc1234567**.
It appears in Settings above the original Trio version, in copied version information,
in the Build Trio workflow summary, and in TestFlight's build notes.

`0.1` is our version series. `12` is the number of first-parent commits after the
base in `ForkVersion.json`; the suffix identifies the exact Git commit. The first
commit after introducing this system's base is `0.1.1`. Each subsequent commit
advances the revision. An upstream merge counts once, regardless of how many
commits it imports. Separate branches can have the same revision number, so keep
the SHA suffix when reporting a version. Rebasing/amending changes commit identity.

A push publishes the versions of its commits; pushing or rebuilding the same
commit does not allocate another source version. If a push contains several
commits, the Actions summary reports the tip's version. The lightweight **Trio AI
Version** workflow runs the versioning tests and reports that version on every
push. It has read-only repository permissions and creates no commits, tags or
releases. There is no bump commit, Git hook or counter to synchronize.

The existing Trio marketing/dev versions, bundle identifiers, update checker and
TestFlight build-number increment remain unchanged. TestFlight's numeric app/build
fields still use Trio's existing scheme; its notes carry the additional Trio AI
identifier. This source version does not affect therapy, stored settings or dosing.

## Local use and builds

```sh
python3 scripts/fork-version.py
python3 scripts/tests/test_fork_version.py
```

Local output appends `.dirty` when Git sees modified/staged files, untracked files
or changed submodules. This indicates uncommitted work, not a unique fingerprint
of that work. Ignored files (including `ConfigOverride.xcconfig`) are not included.
Use `--committed` to report only the committed source version.
That mode reads the version configuration from the commit as well. Before the
first commit containing `ForkVersion.json`, it uses the local configuration and
always appends `.dirty`, including in CI mode.

The existing Capture Build Details phase writes the identifier into the built
app's `BuildDetails.plist`; it never changes the repository's version file.
With `CI=true`, it uses committed mode because Fastlane changes signing and build
settings in the worktree. CI identifiers therefore describe the checked-out
source, not a fingerprint of generated settings or patches applied during the
build. Commit source changes to get a new source version; the existing TestFlight
build number distinguishes repeated archives of the same commit.

Builds need full Git history. Build Trio and the simulator-test workflow check out
with `fetch-depth: 0`. For a local shallow clone, fetch the missing history using
`git fetch --unshallow`. The helper fails explicitly on shallow history or a base
outside the first-parent history instead of silently restarting the counter.

`ForkVersion.json` holds our independent major/minor series and base commit.
Leave it alone for ordinary commits and upstream merges. Changing the series or
resetting the base is a deliberate release decision. Before committing this work,
the current base is displayed as `0.1.0` (plus `.dirty` locally).

The version tests use disposable local Git repositories, including merge, branch,
detached-checkout, dirty-tree and shallow-clone cases. They use no network and do
not modify the Trio repository.

Verified on 2026-09-11: all **11 versioning tests** passed with both the local
Python installation and Apple's Python. The simulator build succeeded and all
**33 selected app tests** (27 AI and 6 settings-search tests) passed. Capture Build
Details was also exercised on temporary product copies with CI both enabled and
disabled; the fork identifier matched the helper and existing commit/submodule
metadata was preserved. Ruby/shell syntax, workflow YAML and whitespace checks
passed. The GitHub workflows and TestFlight upload have not been run remotely.
