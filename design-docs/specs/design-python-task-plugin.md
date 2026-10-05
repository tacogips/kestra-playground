# Python Task Plugin

The standalone `plugins/plugin-python-task` package implements
`io.kestra.plugin.pythontask.PythonTask` for worker-local Python batch execution.

## Contract and execution boundary

The user requested an independently publishable plugin with a required cwd, optional interpreter,
YAML-defined arguments, mitigation for input-driven shell command injection, and local Compose proof.

The plugin models `cmd` as one Python file path, `cwd` as an existing absolute directory,
`pythonPath` as an executable name or absolute path (default `python3`), and `args` as a
list of strings. Optional `options` maps bare names to values and `flags` lists valueless
long-option names. Options become single `--name=value` elements; flags become `--name`.
Options sort by name and follow args; flags follow options in list order. Empty values produce
`--name=`; null option values are omitted. Kestra renders the properties once. A direct Java `ProcessBuilder` invocation
passes each rendered string as one argv element. Eliminating the shell satisfies the injection
mitigation without platform-specific quoting. Resolving the script to an absolute path and inserting
Python's `--` prevents a script filename from being interpreted as a Python option.

The task executes on the Kestra worker with its filesystem and permissions.
Trusted flow authors own interpreter/script selection. Shell-free argument delivery does not
protect a Python script that itself evaluates user input or constructs unsafe subprocess commands.

## Runtime and packaging

The Gradle wrapper pins version 9.1.0 and its distribution checksum. Java classes target 21.
Kestra core/platform/processor are pinned to 1.3.39. Kestra runtime classes are compile-only;
the processor generates plugin discovery metadata. Maven publication includes the main JAR,
sources, Javadoc, POM, and repository metadata, with optional in-memory signing.

The child process has closed stdin. Stdout and stderr redirect to files to avoid pipe deadlocks;
64 KiB previews are read before storage upload because Kestra storage can move the local source.
Full streams are retained in internal storage on completed processes. Nonzero exit fails the task.
Timeouts and interruptions kill the process and known descendants. Capture files are cleaned afterward.
Disk output capacity and worker isolation remain operator responsibilities.

Compose runs a pinned Kestra 1.3.39 image and PostgreSQL in its own project, with loopback port 18080.
There is no Docker socket mount. Existing playground Compose configuration is unchanged.

## Verification

Java regression tests cover literal hostile argv and filenames, absolute interpreter/script paths,
cwd, invalid configuration, EOF on stdin, large simultaneous stdout/stderr, exit code 7,
timeout descendant cleanup, and thread interruption.

The Compose verifier proves real Kestra input rendering, YAML lists/maps and expressions,
default and explicit interpreter selection, exact argv/cwd, empty and Unicode arguments, internal
storage output retrieval, omitted args/options/flags, null option omission, and failure propagation.
An argparse example verifies mapped values starting with `--`, including equals signs, remain
values, and that valueless flags parse as booleans. Invalid option/flag names fail before launch. Shell payloads include quote
breakouts, semicolons, command substitutions, backticks, and newlines, with a checked marker path.

See the operation commands in `command.md` and primary-source references in
`../references/README.md`.

### Verified release evidence (2026-10-05)

Release `0.1.0` passed all 16 Compose cases on Kestra 1.3.39: seven payload round trips
(each executing legacy args, mapped options/flags, and argparse tasks), omitted fields,
null option omission, and seven expected failure cases. Full stored stdout matched the
observed JSON in every argv round trip. The injection marker was absent and timeout
parent/child inspection found no running process.

| Case | Execution | Observed state |
|------|-----------|----------------|
| ordinary input with spaces | `3oZUUapmzFDamDgJknUpRD` | SUCCESS |
| --another-option=a=b | `5VsCrsl6lKRtOZCCpKq4W4` | SUCCESS |
| Literal shell payload / template-looking data | `2hDAgyAbJCQtSXT9nyvO5W` | SUCCESS |
| Literal shell payload / template-looking data | `1w5b3swvUuPc8v2Y30miG5` | SUCCESS |
| Literal shell payload / template-looking data | `62a1Tpqf0A6wK9DXuu0Iec` | SUCCESS |
| Literal shell payload / template-looking data | `ZggWPU9933ertLmZhrUTH` | SUCCESS |
| Literal shell payload / template-looking data | `2RwvZEAFXykVZXUM1hOEYN` | SUCCESS |
| omitted args | `5E5Wn3uUX2CszMuO4pcoq` | SUCCESS |
| null option omitted | `45KJh8OW4yLE048IoxOcDr` | SUCCESS |
| python_task_invalid_option | `71tXQnnkuIHMagGpGafGEc` | FAILED |
| python_task_invalid_flag | `6tN3pL87dX0v4XZTkyTdlV` | FAILED |
| python_task_failure | `61M8IhSdrzyiAAWNXUEFb3` | FAILED |
| python_task_timeout | `7IXcN0Fle9xc30jCxQWGOE` | FAILED |
| python_task_invalid_cwd | `6fsSyhuMlHTcTR8YbGwwsz` | FAILED |
| python_task_missing_script | `4G1X71JcSb5XUYevmwHsWq` | FAILED |
| python_task_render_failure | `214QVXd0MCLGXbgWaQUA0Y` | FAILED |

Main JAR SHA-256: `44aa5955f50725138e145371ff792e29906d2777a9eb30ba50404325f244bdbb`.
The installed Compose JAR matched the built artifact. The manifest identifies version 0.1.0
and the service descriptor names PythonTask. Local Maven publication produced the main,
sources, Javadoc, POM, module metadata, and checksums. No external registry publication was performed.

All nine Java regression tests and 124 playground tests passed. Repository-wide Ruff lint,
format checks and ty static checks passed. Compose configuration validation passed.
The CI and standalone release workflows use SHA-pinned actions, minimal permissions,
checkout without persistent credentials, job timeouts, and concurrency controls.

The release Compose services remain running at loopback port 18080 for inspection.
