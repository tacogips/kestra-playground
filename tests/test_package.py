from kestra_playground import greet


def test_greet_returns_expected_message() -> None:
    assert greet("uv") == "Hello, uv!"


def test_ecommerce_fixture_sql_is_embedded_in_generator_flow() -> None:
    flow = "kestra/flows/generate_ecommerce_mock_data.yaml"

    assert _flow_task_sql(flow, "seed_dimensions") == _read_text(
        "kestra/fixtures/ecommerce/seed_dimensions.sql"
    )
    assert _flow_task_sql(flow, "generate_daily_facts") == _read_text(
        "kestra/fixtures/ecommerce/generate_daily_facts.sql"
    )


def _read_text(path: str) -> str:
    with open(path, encoding="utf-8") as file:
        return file.read().rstrip()


def _flow_task_sql(path: str, task_id: str) -> str:
    lines = _read_text(path).splitlines()
    task_marker = f"  - id: {task_id}"

    try:
        task_start = lines.index(task_marker)
    except ValueError as exc:
        raise AssertionError(f"Task {task_id!r} was not found in {path}") from exc

    sql_marker = "    sql: |"
    try:
        sql_start = lines.index(sql_marker, task_start)
    except ValueError as exc:
        raise AssertionError(f"Task {task_id!r} does not contain a SQL block") from exc

    sql_lines: list[str] = []
    for line in lines[sql_start + 1 :]:
        if line.startswith("  - id: "):
            break
        if line:
            assert line.startswith("      "), f"Unexpected SQL indentation in {path}: {line}"
            sql_lines.append(line[6:])
        else:
            sql_lines.append("")

    return "\n".join(sql_lines).rstrip()
