package io.kestra.plugin.pythontask;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/** Convert structured options and flags into literal argv elements. */
final class PythonArguments {
    private static final Pattern NAME = Pattern.compile("[A-Za-z0-9][A-Za-z0-9_-]*");

    private PythonArguments() { }

    static List<String> build(List<String> args, Map<String, String> options, List<String> flags) {
        if (args == null || options == null || flags == null) {
            throw new IllegalArgumentException("args, options and flags must not be null");
        }
        var result = new ArrayList<String>();
        for (String argument : args) {
            validateValue(argument);
            result.add(argument);
        }
        for (var entry : options.entrySet()) {
            validateName(entry.getKey());
            if (entry.getValue() != null) {
                validateValue(entry.getValue());
            }
        }
        // Map iteration order is not part of the public contract.
        options.entrySet().stream().filter(entry -> entry.getValue() != null).sorted(Map.Entry.comparingByKey()).forEach(entry ->
            result.add("--" + entry.getKey() + "=" + entry.getValue()));
        for (String flag : flags) {
            validateName(flag);
            result.add("--" + flag);
        }
        return List.copyOf(result);
    }

    private static void validateName(String name) {
        if (name == null || !NAME.matcher(name).matches()) {
            throw new IllegalArgumentException("Option and flag names must use letters, digits, underscores or hyphens, without a leading hyphen");
        }
    }

    private static void validateValue(String value) {
        if (value == null || value.indexOf('\0') >= 0) {
            throw new IllegalArgumentException("Argument and option values must be non-null strings without NUL bytes");
        }
    }
}
