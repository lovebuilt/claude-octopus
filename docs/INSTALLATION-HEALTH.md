# Installation health

Claude Octopus can inspect its installation without contacting a model
provider or changing a host-managed plugin cache.

## Start with Doctor

```bash
octopus doctor installation
```

This checks the plugin root loaded by the current host, the stable Octopus
root, the saved install metadata, and the active context profile. Claude Code
and Codex have separate saved entries because they can load different plugin
versions. It is read-only. A missing or mismatched stable root is reported for
repair; Doctor does not create or replace it.

Octopus stores this non-secret metadata in
`~/.claude-octopus/install-state.json`. SessionStart refreshes the current
host entry when the loaded root, plugin version, install scope, or profile has
changed. To refresh it manually, run:

```bash
octopus install-state record
```

`install-state record` writes metadata. It is separate from the read-only
health checks.

## Inspect provider readiness

```bash
octopus capabilities
octopus capabilities --json
```

The report uses the same static readiness contract as setup and Doctor. It
does not send prompts or make provider requests. A provider can be installed
but `degraded` when authentication is missing or cannot be confirmed safely.

## Check dispatched Claude seats

Workflow preflight can run a provider smoke test. It sends a trivial prompt
through the same `claude --print` command used by Claude seats, with the selected
binary and model. This checks the subprocess login separately from the host
session. `OCTOPUS_CLAUDE_SMOKE_TIMEOUT` sets the wait, with a default of 60 seconds.
An authentication error fails preflight with login guidance. A timeout reports
degraded readiness and lets the workflow continue, including for a Claude-only
fleet. Excluding Claude with `OCTO_ALLOWED_PROVIDERS` skips its smoke check.

The smoke cache includes whether Claude is checked, its binary, and its model.
Changing any of these requires a new check. Static Doctor and capability reports
remain local-only; they do not run this prompt.

## Check cached installations

```bash
octopus cache-check
octopus cache-check --json
```

The cache check validates each Claude Code and Codex cache version it finds,
including the active and newest entries. Invalid stale versions are warnings;
an invalid active or newest version is a failure. The command never removes a
cache directory.

## Repair the stable root

Use a dry run first:

```bash
octopus repair --dry-run
```

Repair can create or replace the Octopus-owned stable link at
`~/.claude-octopus/plugin` and refresh the current host's install metadata. It
refuses to replace an unowned regular file or directory. It does not alter the
Claude Code or Codex cache. Treat `--apply` as a write: review the dry-run
output and authorize the exact repair first. Then, and only then, run:

```bash
octopus repair --apply
```

## Choose a context profile

```bash
octopus profile                 # show the current profile
octopus profile core
octopus profile orchestration
octopus profile full
```

`core` keeps optional context hooks off. `orchestration` enables context
reinforcement and post-tool coordination during active Octopus workflows.
`full` allows every profile-managed context hook defined by the installed
release. `OCTOPUS_CONTEXT_PROFILE` selects this setting and
`OCTOPUS_HOOK_PROFILE` can override the optional hook profile. These settings
never disable safety or lifecycle hooks. `OCTO_PROFILE` is the separate legacy
workflow-intensity setting, not a context-hook switch.

## Export a portable checkpoint

```bash
octopus handoff export
octopus handoff export --json
octopus handoff show --json
```

The export contains a small allowlisted workflow summary and redacts common
credential patterns. It omits the local project path and writes with mode
`0600` under `~/.claude-octopus/handoffs/` by default. Redaction is pattern-based,
not a guarantee that every secret is removed. An arbitrary input or output
failure can also prevent the command from producing valid JSON. Review any
checkpoint before sharing it.

The file is a summary for inspection or manual transfer, not imported runtime
state. `/octo:resume` resumes local state; it does not import this JSON.

## Run the local plugin audit

```bash
octopus security-audit
octopus security-audit --json
```

This offline check validates shell syntax and plugin manifests, then reports
high-risk shell patterns for review. It audits the installed Octopus files,
not the user's project. Use `/octo:security` for a project security review.

## Setup behavior

`/octo:setup` runs the installation Doctor category and cache check as a safe,
read-only health pass when setup is used for troubleshooting and again during
completion verification. It reports the evidence without applying repairs,
cleaning caches, logging in, or contacting a provider service. If the report
calls for a change, review `octopus repair --dry-run` and authorize
`octopus repair --apply` separately.

## Exit codes

The diagnostic commands use these exit codes:

| Code | Meaning |
|---:|---|
| `0` | Checks passed, with informational results or warnings allowed where documented |
| `1` | A required check failed, a repair was blocked, or state could not be written |
| `2` | Invalid command or arguments |

JSON output remains valid when a check exits with code `1`, so automation can
read the evidence before deciding what to do.

## Windows host acceptance

Octopus workflows run on Linux and macOS. Windows users can run the Claude Code
CLI inside WSL, with a separate Linux plugin installation, or use Claude Code
Desktop over SSH to a Linux or macOS host. The desktop app's built-in WSL sessions
[do not load plugins](https://code.claude.com/docs/en/desktop-wsl).

On native Git Bash, MSYS2, and Cygwin, every registered Claude Code hook exits
before reading input or writing state. The SessionStart root helper creates no
stable-root copy. Codex uses the existing native Windows no-op hook commands.
Run `bash tests/unit/test-native-windows-hook-inert.sh` and
`bash tests/unit/test-windows-doctor-compat.sh` to check simulated Windows hosts,
WSL identification, and the documented entry points. Actual Windows desktop
installation requires a Windows host; simulation does not establish host discovery.
