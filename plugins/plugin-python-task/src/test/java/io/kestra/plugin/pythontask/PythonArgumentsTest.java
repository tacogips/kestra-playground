package io.kestra.plugin.pythontask;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class PythonArgumentsTest {
    @Test
    void combinesArgsOptionsAndValuelessFlagsWithoutSplittingValues() {
        String hostile = "--other='; $(touch injected)\n日本語";
        assertEquals(
            List.of("positional", "--repeat", "a", "--repeat", "b",
                "--customer=" + hostile, "--empty=", "--output=two words.csv", "--verbose", "--dry-run"),
            PythonArguments.build(
                List.of("positional", "--repeat", "a", "--repeat", "b"),
                Map.of("output", "two words.csv", "empty", "", "customer", hostile),
                List.of("verbose", "dry-run")));
    }

    @Test
    void emptyStructuredFieldsPreserveLegacyArgs() {
        assertEquals(List.of("", "--customer", "two words"),
            PythonArguments.build(List.of("", "--customer", "two words"), Map.of(), List.of()));
        assertEquals(List.of(), PythonArguments.build(List.of(), Map.of(), List.of()));
    }

    @Test
    void rejectsAmbiguousNamesAndOmitsNullOptions() {
        for (String invalid : List.of("", "--customer", "-c", "two words", "customer=value", "x\ny", "$(cmd)")) {
            assertThrows(IllegalArgumentException.class, () ->
                PythonArguments.build(List.of(), Map.of(invalid, "value"), List.of()));
            assertThrows(IllegalArgumentException.class, () ->
                PythonArguments.build(List.of(), Map.of(), List.of(invalid)));
        }
        var nullOption = new HashMap<String, String>();
        nullOption.put("customer", null);
        assertEquals(List.of(), PythonArguments.build(List.of(), nullOption, List.of()));
        assertThrows(IllegalArgumentException.class, () ->
            PythonArguments.build(List.of(), Map.of("customer", "nul\0value"), List.of()));
        assertThrows(IllegalArgumentException.class, () ->
            PythonArguments.build(null, Map.of(), List.of()));
    }
}
