package io.kestra.plugin.pythontask;

import io.kestra.core.models.annotations.Example;
import io.kestra.core.models.annotations.Plugin;
import io.kestra.core.models.property.Property;
import io.kestra.core.models.tasks.RunnableTask;
import io.kestra.core.models.tasks.Task;
import io.kestra.core.runners.RunContext;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotNull;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.experimental.SuperBuilder;

import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.Map;

@Getter
@SuperBuilder
@NoArgsConstructor
@Schema(title = "Run a Python file with shell-free arguments.",
    description = "Each rendered argument is passed verbatim as one argv element. Runs on the Kestra worker.")
@Plugin(examples = @Example(title = "Pass an input as one literal argument", full = true, code = """
    id: python_task
    namespace: company.team
    inputs:
      - id: message
        type: STRING
    tasks:
      - id: run
        type: io.kestra.plugin.pythontask.PythonTask
        cwd: /opt/batches
        cmd: report.py
        options:
          message: "{{ inputs.message }}"
        flags:
          - verbose
    """))
public class PythonTask extends Task implements RunnableTask<PythonTask.Output> {
    @NotNull
    @Schema(title = "Working directory.", description = "Existing absolute directory on the worker.")
    private Property<String> cwd;

    @NotNull
    @Schema(title = "Python file.", description = "File path, absolute or relative to cwd. No command string or inline code.")
    private Property<String> cmd;

    @Builder.Default
    @Schema(title = "Python executable.", description = "Executable name on PATH or absolute path; defaults to python3.")
    private Property<String> pythonPath = Property.ofValue("python3");

    @Builder.Default
    @Schema(title = "Arguments.", description = "Ordered strings, individually rendered once and preserved as literal argv elements.")
    private Property<List<String>> args = Property.ofValue(List.of());

    @Builder.Default
    @Schema(title = "Options.", description = "Map of bare long-option names to values. Rendered as one literal --name=value argument, sorted by name. Empty values are allowed; null values are omitted.")
    private Property<Map<String, String>> options = Property.ofValue(Map.of());

    @Builder.Default
    @Schema(title = "Flags.", description = "Ordered bare long-option names without values, for example verbose or dry-run. Each becomes --name.")
    private Property<List<String>> flags = Property.ofValue(List.of());

    @Builder.Default
    @Schema(title = "Process timeout.", description = "Positive duration; on expiry the process and known descendants are terminated.")
    private Property<Duration> processTimeout = Property.ofValue(Duration.ofMinutes(10));

    @Override
    public Output run(RunContext context) throws Exception {
        String directory = context.render(cwd).as(String.class).orElseThrow();
        String script = context.render(cmd).as(String.class).orElseThrow();
        String python = context.render(pythonPath).as(String.class).orElseThrow();
        List<String> arguments = PythonArguments.build(
            context.render(args).asList(String.class),
            context.render(options).asMap(String.class, String.class),
            context.render(flags).asList(String.class));
        Duration limit = context.render(processTimeout).as(Duration.class).orElseThrow();
        Path capture = Files.createTempDirectory("kestra-python-task-");
        try {
            var result = PythonProcess.execute(directory, script, python, arguments, limit, capture);
            // Kestra storage may move/delete source files during upload.
            String stdout = PythonProcess.preview(result.stdout());
            String stderr = PythonProcess.preview(result.stderr());
            URI stdoutUri = context.storage().putFile(result.stdout().toFile());
            URI stderrUri = context.storage().putFile(result.stderr().toFile());
            context.logger().info("Python process exited with code {}", result.exitCode());
            if (result.exitCode() != 0) {
                context.logger().error("Python stderr (bounded preview): {}", stderr);
                throw new IllegalStateException("Python process exited with code " + result.exitCode());
            }
            return Output.builder()
                .exitCode(result.exitCode())
                .stdout(stdout)
                .stderr(stderr)
                .stdoutUri(stdoutUri)
                .stderrUri(stderrUri)
                .build();
        } finally {
            Files.deleteIfExists(capture.resolve("stdout.txt"));
            Files.deleteIfExists(capture.resolve("stderr.txt"));
            Files.deleteIfExists(capture);
        }
    }

    @Builder
    @Getter
    public static class Output implements io.kestra.core.models.tasks.Output {
        @Schema(title = "Process exit code.")
        private final int exitCode;
        @Schema(title = "UTF-8 stdout preview.", description = "At most 65536 bytes; use stdoutUri for the complete stream.")
        private final String stdout;
        @Schema(title = "UTF-8 stderr preview.", description = "At most 65536 bytes; use stderrUri for the complete stream.")
        private final String stderr;
        @Schema(title = "Full stdout in internal storage.")
        private final URI stdoutUri;
        @Schema(title = "Full stderr in internal storage.")
        private final URI stderrUri;
    }
}
