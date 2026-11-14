package io.kestra.plugin.pythontask;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Direct argv execution: never concatenate, quote, or evaluate a shell command. */
final class PythonProcess {
    private PythonProcess() { }

    record Result(int exitCode, Path stdout, Path stderr) { }

    static List<String> command(String cwd, String cmd, String python, List<String> args) {
        requireText(cwd, "cwd");
        requireText(cmd, "cmd");
        requireText(python, "pythonPath");
        Path directory = Path.of(cwd);
        if (!directory.isAbsolute() || !Files.isDirectory(directory)) {
            throw new IllegalArgumentException("cwd must be an existing absolute directory");
        }
        Path script = directory.resolve(cmd).normalize().toAbsolutePath();
        if (!Files.isRegularFile(script)) {
            throw new IllegalArgumentException("cmd must identify an existing Python file");
        }
        // Reject relative executable paths: their resolution varies between platforms.
        Path executable = Path.of(python);
        if (executable.getNameCount() > 1 && !executable.isAbsolute()) {
            throw new IllegalArgumentException("pythonPath must be a PATH name or absolute path");
        }
        var command = new ArrayList<String>();
        command.add(python);
        command.add("-u");
        command.add("--");
        command.add(script.toString());
        if (args == null) {
            throw new IllegalArgumentException("args must be a list of strings");
        }
        for (String argument : args) {
            if (argument == null || argument.indexOf('\0') >= 0) {
                throw new IllegalArgumentException("args must contain non-null strings without NUL bytes");
            }
            command.add(argument);
        }
        return List.copyOf(command);
    }

    static Result execute(String cwd, String cmd, String python, List<String> args,
                          Duration timeout, Path capture) throws IOException, InterruptedException, TimeoutException {
        if (timeout == null || timeout.isNegative() || timeout.isZero() || timeout.toMillis() < 1) {
            throw new IllegalArgumentException("processTimeout must be at least one millisecond");
        }
        var command = command(cwd, cmd, python, args);
        Path stdout = capture.resolve("stdout.txt");
        Path stderr = capture.resolve("stderr.txt");
        Process process = new ProcessBuilder(command)
            .directory(Path.of(cwd).toFile())
            .redirectOutput(stdout.toFile())
            .redirectError(stderr.toFile())
            .start();
        try {
            // No interactive input; otherwise a script reading stdin can hang indefinitely.
            process.getOutputStream().close();
            if (!process.waitFor(timeout.toMillis(), TimeUnit.MILLISECONDS)) {
                throw new TimeoutException("Python process exceeded processTimeout");
            }
            return new Result(process.exitValue(), stdout, stderr);
        } finally {
            if (process.isAlive()) {
                terminate(process);
            }
        }
    }

    private static void terminate(Process process) {
        // Snapshot before killing the parent so descendants are not lost to reparenting.
        var children = process.descendants().toList();
        for (var child : children) {
            child.destroyForcibly();
        }
        process.destroyForcibly();
        boolean interrupted = false;
        while (process.isAlive()) {
            try {
                process.waitFor();
            } catch (InterruptedException e) {
                interrupted = true;
            }
        }
        if (interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    static String preview(Path path) throws IOException {
        try (var input = Files.newInputStream(path)) {
            return new String(input.readNBytes(65536), StandardCharsets.UTF_8);
        }
    }

    private static void requireText(String value, String field) {
        if (value == null || value.isBlank() || value.indexOf('\0') >= 0) {
            throw new IllegalArgumentException(field + " must be non-blank and contain no NUL bytes");
        }
    }
}
