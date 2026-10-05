package io.kestra.plugin.pythontask;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.*;

class PythonProcessTest {
    @TempDir
    Path directory;

    private Path script(String name, String source) throws Exception {
        return Files.writeString(directory.resolve(name), source);
    }

    @Test
    void preservesHostileArgumentsAndPathsLiterally() throws Exception {
        Path file = script("-script with 'quotes'.py", """
            import sys
            from pathlib import Path
            Path("received.txt").write_text("\\0".join(sys.argv[1:]))
            print(Path.cwd())
            """);
        var arguments = List.of(
            "", "two words", "'\"quoted'", "; touch injected",
            "$(touch injected)", "`touch injected`", "a\nb", "x && touch injected",
            "--flag=value", "{{ inputs.other }}", "日本語", "\\path\\*");
        var result = PythonProcess.execute(directory.toString(), file.getFileName().toString(),
            "python3", arguments, Duration.ofSeconds(10), directory);
        assertEquals(0, result.exitCode());
        assertEquals(String.join("\0", arguments), Files.readString(directory.resolve("received.txt")));
        assertEquals(directory.toRealPath().toString(), PythonProcess.preview(result.stdout()).strip());
        assertFalse(Files.exists(directory.resolve("injected")));
    }

    @Test
    void reportsFailureAndDrainsLargeStdoutAndStderr() throws Exception {
        script("fail.py", """
            import sys
            sys.stdout.write("o" * 200000)
            sys.stderr.write("e" * 200000)
            sys.exit(7)
            """);
        var result = PythonProcess.execute(directory.toString(), "fail.py", "python3",
            List.of(), Duration.ofSeconds(10), directory);
        assertEquals(7, result.exitCode());
        assertEquals(200000, Files.size(result.stdout()));
        assertEquals(200000, Files.size(result.stderr()));
        assertEquals(65536, PythonProcess.preview(result.stdout()).length());
    }

    @Test
    void timesOutAndTerminatesChildren() throws Exception {
        script("wait.py", """
            import subprocess
            import time
            from pathlib import Path
            child = subprocess.Popen(["python3", "-c", "import time; time.sleep(30)"])
            Path("child.pid").write_text(str(child.pid))
            time.sleep(30)
            """);
        assertThrows(TimeoutException.class, () -> PythonProcess.execute(directory.toString(),
            "wait.py", "python3", List.of(), Duration.ofSeconds(2), directory));
        long pid = Long.parseLong(Files.readString(directory.resolve("child.pid")));
        // Wait briefly for OS reaping after SIGKILL.
        for (int i = 0; i < 50 && ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false); i++) {
            Thread.sleep(20);
        }
        assertFalse(ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false));
    }

    @Test
    void interruptStopsTheProcess() throws Exception {
        script("wait.py", """
            import os
            import time
            from pathlib import Path
            Path("parent.pid").write_text(str(os.getpid()))
            time.sleep(30)
            """);
        var thrown = new java.util.concurrent.atomic.AtomicReference<Throwable>();
        Thread thread = new Thread(() -> {
            try {
                PythonProcess.execute(directory.toString(), "wait.py", "python3", List.of(),
                    Duration.ofSeconds(30), directory);
            } catch (Throwable e) {
                thrown.set(e);
            }
        });
        thread.start();
        for (int i = 0; i < 100 && !Files.exists(directory.resolve("parent.pid")); i++) {
            Thread.sleep(20);
        }
        assertTrue(Files.exists(directory.resolve("parent.pid")));
        long pid = Long.parseLong(Files.readString(directory.resolve("parent.pid")));
        thread.interrupt();
        thread.join(5000);
        assertFalse(thread.isAlive());
        assertInstanceOf(InterruptedException.class, thrown.get());
        assertFalse(ProcessHandle.of(pid).map(ProcessHandle::isAlive).orElse(false));
    }

    @Test
    void rejectsInvalidConfigurationBeforeLaunching() throws Exception {
        script("ok.py", "print('ok')");
        assertThrows(IllegalArgumentException.class, () -> PythonProcess.command(".", "ok.py", "python3", List.of()));
        assertThrows(IllegalArgumentException.class, () -> PythonProcess.command(directory.toString(), "missing.py", "python3", List.of()));
        assertThrows(IllegalArgumentException.class, () -> PythonProcess.command(directory.toString(), "ok.py", "", List.of()));
        assertThrows(IllegalArgumentException.class, () -> PythonProcess.command(directory.toString(), "ok.py", "venv/bin/python", List.of()));
        assertThrows(IllegalArgumentException.class, () -> PythonProcess.command(directory.toString(), "ok.py", "python3", List.of("nul\0value")));
        assertThrows(IllegalArgumentException.class, () -> PythonProcess.execute(directory.toString(), "ok.py", "python3", List.of(), Duration.ZERO, directory));
    }

    @Test
    void closesStdinAndAcceptsAbsoluteInterpreterAndScript() throws Exception {
        Path file = script("stdin.py", "import sys; print(repr(sys.stdin.read()))");
        Process lookup = new ProcessBuilder("python3", "-c", "import sys; print(sys.executable)").start();
        String python = new String(lookup.getInputStream().readAllBytes()).strip();
        assertEquals(0, lookup.waitFor());
        var result = PythonProcess.execute(directory.toString(), file.toString(), python,
            List.of(), Duration.ofSeconds(10), directory);
        assertEquals(0, result.exitCode());
        assertEquals("''", PythonProcess.preview(result.stdout()).strip());
    }
}
