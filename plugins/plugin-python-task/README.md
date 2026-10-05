# Kestra Python Task

A standalone Apache-2.0 Kestra plugin that runs a worker-local Python file with structured
arguments. Tested against Kestra **1.3.39**; Java bytecode targets **21**.

Interpolating input into a shell command can turn data into executable shell syntax.
This task renders each YAML argument and passes the resulting string directly to
`ProcessBuilder`. There is no shell, command concatenation, or shell escaping to get wrong.
Quotes, substitutions, semicolons, whitespace, newlines, and empty strings remain literal data.

## Usage

Install the main JAR into the Kestra plugin directory (normally `/app/plugins`) on each
worker and restart Kestra. Python and the script must be installed on the worker.
For a virtual environment, use an absolute interpreter path.

```yaml
id: run_report
namespace: company.team
inputs:
  - id: customer
    type: STRING
tasks:
  - id: report
    type: io.kestra.plugin.pythontask.PythonTask
    cwd: /opt/batches
    cmd: report.py
    pythonPath: /opt/batches/.venv/bin/python
    options:
      customer: "{{ inputs.customer }}"
      output: report.csv
    flags:
      - verbose
      - dry-run
    processTimeout: PT10M
```

| Property | Required | Meaning |
|----------|----------|---------|
| `cwd` | Yes | Existing absolute worker-local directory |
| `cmd` | Yes | Python script path, relative to `cwd` or absolute |
| `pythonPath` | No | Executable name on PATH or absolute path; default `python3` |
| `args` | No | Ordered literal arguments; default empty list |
| `options` | No | Map of bare option names to string values; default empty map |
| `flags` | No | Ordered bare option names without values; default empty list |
| `processTimeout` | No | Positive duration of at least 1 ms; default `PT10M` |

Properties support Kestra expressions. `args` accepts a YAML list or an expression returning a
list of strings. Arguments are rendered using Kestra's normal nonrecursive property rendering.
`options` accepts a YAML map or a map expression; `flags` accepts a YAML list or a list
expression. Each option becomes a single `--name=value` argument. Even a value starting with
`--` stays that option's value (for example when parsed with Python argparse).
An empty string produces `--name=`; null values omit that option. Use `flags` for valueless
options: `verbose` becomes `--verbose`. Names must match `[A-Za-z0-9][A-Za-z0-9_-]*`;
write `customer`, not `--customer`.

The process argv is `[pythonPath, "-u", "--", absoluteScriptPath, ...args, ...options, ...flags]`.
Options are sorted by name for deterministic ordering; args and flags retain their list order.
Use `args` for repeated options, short options, or positional arguments, including an explicit
`--` separator when your Python program requires one. When using that separator, put the
whole argument sequence in `args`, since mapped options and flags would otherwise follow it.
Python flags and inline Python code are not part of the `cmd` contract.

Outputs are `exitCode`, `stdout`, `stderr`, `stdoutUri`, and `stderrUri`. Text previews read
up to 64 KiB per stream as UTF-8; full streams are uploaded to Kestra internal storage.
Use `{{ outputs.report.stdout }}` in subsequent tasks. Output is captured to disk so large
streams do not block the process or grow JVM memory without limit. Size disk capacity for batch output.
A nonzero exit fails the task and logs a bounded stderr preview. The plugin does not parse
the official scripts plugin's output protocol. Stdin is closed.

On process timeout or thread interruption, the plugin terminates the process and its currently
known descendants. This runs with the worker's permissions; it is not a sandbox. Keep executable
and script selection under trusted flow author control. The Python program must also treat its
arguments as data when invoking subprocesses or handling application options.

## Build and local verification

This directory can be copied into a separate repository without the parent playground.

Prerequisites: JDK 25 (Gradle 9.1 supports it), Python 3.12+, and Docker Compose.
The Gradle wrapper checksum pins the downloaded distribution. Kestra dependencies are compile-only,
so the installable JAR contains this plugin rather than duplicate Kestra classes.

```bash
./gradlew test assemble publishToMavenLocal
docker compose -f local/compose.yaml up -d --build
python3 local/verify.py
```

The local API/UI is at `http://127.0.0.1:18080`, with development-only credentials
`local@example.com` / `LocalPythonTask123!`. Set `PYTHON_TASK_PORT` to change the host port;
the verifier also honors `PYTHON_TASK_URL`.
Compose uses an isolated project and volumes; it does not alter the playground stack.

The verifier registers the example flow and negative test flows, sends shell-injection payloads
through real Kestra inputs, checks default and explicit Python paths, verifies exact argv
and cwd for lists, maps, and expressions, checks argparse receives option values and valueless flags,
downloads full stored stdout, checks omitted arguments, and asserts failed task states
for nonzero exit, timeout, missing cwd/script, missing template input, and invalid option/flag names. It also checks that
no injection marker exists and that timeout parent/child processes stopped.
Execution IDs are saved in ignored `local/results/executions.json`.

Stop the local test services with:

```bash
docker compose -f local/compose.yaml down
```

Volumes remain available for inspection and subsequent verification.

## Release and publication

Coordinates: `io.github.tacogips:plugin-python-task:<version>`.
The repository and developer metadata assume a standalone repository at
`https://github.com/tacogips/plugin-python-task`; update them if using another destination.

Build a release and a reviewable Maven repository locally:

```bash
./gradlew clean test assemble publish -Pversion=0.1.0
docker compose -f local/compose.yaml build --build-arg PLUGIN_VERSION=0.1.0
docker compose -f local/compose.yaml up -d
python3 local/verify.py
```

Install only `build/libs/plugin-python-task-0.1.0.jar` into Kestra. The sources/Javadoc JARs
are publication artifacts. Maven layout, POM, and checksums are generated under `build/repository`.

To publish to an authenticated Maven repository, set `MAVEN_USERNAME` and `MAVEN_PASSWORD`
and run:

```bash
./gradlew publish -Pversion=0.1.0 -PpublishUrl=https://your-maven-repository/releases
```

Optional `SIGNING_KEY` (ASCII-armored private key) and `SIGNING_PASSWORD` enable in-memory
PGP signing. Maven Central requires verified namespace ownership and its publication onboarding;
the generic Maven upload command alone does not complete Central onboarding.

The standalone `.github/workflows/ci.yml` verifies tests, packaging, and Compose.
`release.yml` takes a release version, packages and verifies it, uploads release artifacts,
and optionally publishes using repository secrets `MAVEN_REPOSITORY_URL`,
`MAVEN_USERNAME`, `MAVEN_PASSWORD`, `SIGNING_KEY`, and `SIGNING_PASSWORD`.
The parent playground has a separate path-filtered CI workflow for this directory.
