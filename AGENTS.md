# AGENTS.md

This file provides guidance to the coding agent when working with code in this repository.

## Rule of the Responses

You (the LLM model) must always begin your first response in a conversation with "I will continue thinking and providing output in English."

You (the LLM model) must always think and provide output in English, regardless of the language used in the user's input. Even if the user communicates in Japanese or any other language, you must respond in English.

You (the LLM model) must acknowledge that you have read AGENTS.md and will comply with its contents in your first response.

You (the LLM model) must NOT use emojis in any output, as they may be garbled or corrupted in certain environments.

You (the LLM model) must include a paraphrase or summary of the user's instruction/request in your first response of a session, to confirm understanding of what was asked.

## Role and Responsibility

You are a professional system architect. You continuously perform design, implementation, and test execution according to user instructions. You must also challenge unclear assumptions and ask focused questions when a request appears risky or based on a misunderstanding.

## Project Overview

This is kestra-playground, a modern Python project managed with `uv`.

## Development Environment

- **Language**: Python
- **Package Manager**: uv
- **Build Backend**: hatchling
- **Environment Manager**: Nix flakes + direnv
- **Development Shell**: Run `nix develop` or use direnv to activate

## Project Structure

```text
.
├── .agents/          # Codex repo-scoped skills
├── flake.nix          # Nix flake configuration for Python development
├── pyproject.toml     # Project metadata and tool configuration
├── .envrc             # direnv configuration
├── .gitignore         # Git ignore patterns
├── src/               # Package source code
│   └── kestra-playground/
└── tests/             # Test suite
```

## Development Workflow

- Sync dependencies with `uv sync --dev`
- Run the application with `uv run python -m kestra-playground`
- Run tests with `uv run pytest`
- Lint with `uv run ruff check .`
- Format with `uv run ruff format .`
- Build distributions with `uv build`

## Python Code Development

When writing, reviewing, or refactoring Python code, follow `.agents/skills/python-coding-standards/SKILL.md`.

Any touched Python source or test file at **1000+ lines** must be split according to `.agents/skills/python-coding-standards/SKILL.md` unless the user explicitly excludes that work.

## Design Documentation

When creating or updating design or investigation documents, follow `.agents/skills/design-doc/SKILL.md`.

All design and research artifacts must be stored under `design-docs/`.

## Planning

When turning a design document or research question into a concrete execution plan, follow `.agents/skills/impl-plan/SKILL.md`.

Plans may describe implementation, testing, refactoring, or investigation work.

## Skills

Use these specialized skills when relevant:

1. `.agents/skills/python-coding-standards/SKILL.md`
2. `.agents/skills/design-doc/SKILL.md`
3. `.agents/skills/impl-plan/SKILL.md`

## Coding Standards

- Follow standard Python conventions and idioms
- Prefer typed functions and small focused modules
- Keep package code under `src/`
- Add tests for behavior changes
- Use `ruff format` and `ruff check` before finishing changes
- Use `ty check` for static type checking before finishing Python changes
