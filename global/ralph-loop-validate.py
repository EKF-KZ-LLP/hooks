#!/usr/bin/env python3
"""Shared Ralph Loop validator for hook wrappers.

The validator is intentionally strict. A rule counts as enforced only when
this process exits non-zero with a concrete reason.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REQUIRED_FIELDS = [
    "type",
    "required",
    "scope",
    "source_of_truth",
    "success_criteria",
    "verification",
    "evidence",
    "result",
    "commit",
    "status",
]

VALID_TYPES = {
    "discovery",
    "code",
    "test",
    "review",
    "docs",
    "ci",
    "adr",
    "safety",
    "other",
}

VALID_STATUSES = {
    "planned",
    "in_progress",
    "verified",
    "blocked",
    "failed",
    "done",
    "waived",
}

ATTEMPT_FIELDS = [
    "attempt",
    "task_id",
    "trigger",
    "hypothesis",
    "action",
    "command_or_artifact",
    "result",
    "next_decision",
    "evidence",
    "commit",
    "timestamp",
]

INVALID_BLOCKER_RE = re.compile(
    r"(не получилось|тесты падают|ошибка|неясно|нужно разобраться|probably impossible|не работает)",
    re.IGNORECASE,
)

VALID_BLOCKER_RE = re.compile(
    r"(missing credential|missing credentials|missing business decision|"
    r"destructive approval|approval needed|external system unavailable|"
    r"conflicting source of truth|retry budget exhausted|user decision required)",
    re.IGNORECASE,
)

EXTERNAL_RE = re.compile(
    r"(external|tooling|library|api|dependency|package|sdk|ci|codeql|github actions)",
    re.IGNORECASE,
)

DOC_SEARCH_RE = re.compile(
    r"(internet|context7|official docs|docs search|vendor docs|upstream docs|web search)",
    re.IGNORECASE,
)

CONSULT_RE = re.compile(
    r"(senior engineer|consult_senior|consult senior|codex:rescue|codex:codex-rescue|consult_codex)",
    re.IGNORECASE,
)

LOCAL_SOURCE_TOKENS = ["repo", "docs", "tests", "git", "logs"]
GOVERNED_SUFFIXES = {
    ".go",
    ".py",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".rs",
    ".java",
    ".kt",
    ".swift",
    ".rb",
    ".sh",
    ".sql",
    ".yml",
    ".yaml",
    ".toml",
    ".json",
    ".md",
}

CHECKBOX_RE = re.compile(r"^(\s*)- \[([ xX~])\](?: \[SKIP\])?\s+(.+)$")
TASK_ID_RE = re.compile(r"^(?:\*\*)?([A-Z][A-Z0-9]*-[0-9A-Z._-]+):")
FIELD_RE = re.compile(r"^\s+-\s+([a-z_]+):\s*(.*)$")
HEX_RE = re.compile(r"\b[0-9a-f]{40}\b", re.IGNORECASE)


class GateError(Exception):
    pass


@dataclass
class Task:
    task_id: str | None
    line_no: int
    indent: int
    checked: bool
    skip: bool
    title: str
    block: list[str]
    meta: dict[str, str]

    @property
    def status(self) -> str:
        return clean_value(self.meta.get("status", "")).lower()

    @property
    def task_type(self) -> str:
        return clean_value(self.meta.get("type", "")).lower()

    @property
    def required(self) -> bool:
        return clean_value(self.meta.get("required", "")).lower() == "true"

    @property
    def text(self) -> str:
        return "\n".join(self.block)


def deny(reason: str, event_name: str | None = None) -> None:
    if event_name:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": event_name,
                        "permissionDecision": "deny",
                        "permissionDecisionReason": reason,
                    }
                }
            )
        )
    print(f"::error::{reason}", file=sys.stderr)
    raise SystemExit(2)


def run(cmd: list[str], cwd: Path | None = None) -> str:
    try:
        return subprocess.check_output(cmd, cwd=str(cwd) if cwd else None, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""


def resolve_project(project_arg: str | None = None) -> Path:
    if project_arg:
        return Path(project_arg).resolve()
    env_project = os.environ.get("CLAUDE_PROJECT_DIR")
    if env_project:
        return Path(env_project).resolve()
    top = run(["git", "rev-parse", "--show-toplevel"])
    return Path(top).resolve() if top else Path.cwd().resolve()


def git_head(project: Path) -> str:
    return run(["git", "rev-parse", "HEAD"], cwd=project)


def git_head_parents(project: Path) -> list[str]:
    line = run(["git", "rev-list", "--parents", "-n", "1", "HEAD"], cwd=project)
    return line.split()[1:] if line else []


def git_changed_files(project: Path, base: str, head: str = "HEAD") -> list[str]:
    output = run(["git", "diff", "--name-only", f"{base}..{head}"], cwd=project)
    return [line.strip() for line in output.splitlines() if line.strip()]


def git_is_ancestor(project: Path, commit: str, head: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, head],
            cwd=str(project),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        return result.returncode == 0
    except Exception:
        return False


def git_commit_distance(project: Path, base: str, head: str) -> int | None:
    value = run(["git", "rev-list", "--count", f"{base}..{head}"], cwd=project)
    try:
        return int(value)
    except ValueError:
        return None


def is_metadata_only_path(rel: str) -> bool:
    return (
        rel in {"WORKPLAN.md", "HANDOFF.md", "DECISIONS.md"}
        or rel.startswith(".checkpoints/")
        or rel.startswith(".agent-state/")
        or rel == ".claude/active-tracker"
        or rel.startswith(".claude/sprints/")
        or rel.startswith("docs/superpowers/plans/")
        or rel.startswith("docs/phase-0-data-quality/")
    )


def head_is_metadata_only(project: Path, parent: str) -> bool:
    changed = git_changed_files(project, parent)
    return bool(changed) and all(is_metadata_only_path(rel) for rel in changed)


def nearest_evidence_ancestor(project: Path, head: str, evidence_commits: set[str]) -> str | None:
    candidates: list[tuple[int, str]] = []
    for commit in evidence_commits:
        if not commit or not git_is_ancestor(project, commit, head):
            continue
        distance = git_commit_distance(project, commit, head)
        if distance is not None:
            candidates.append((distance, commit))
    if not candidates:
        return None
    candidates.sort()
    return candidates[0][1]


def task_scope_unchanged_since(project: Path, task: Task, base: str, head: str) -> bool:
    scope = clean_value(task.meta.get("scope", ""))
    if not scope or not any(token in scope for token in ("/", ".")):
        return False
    changed = git_changed_files(project, base, head)
    if not changed:
        return True
    for rel in changed:
        if is_metadata_only_path(rel):
            continue
        path = project / rel
        if rel in scope or path.name in scope:
            return False
    return True


def head_matches_evidence(project: Path, head: str, evidence_commits: set[str], task: Task) -> bool:
    if not head:
        return True
    if head in evidence_commits:
        return True
    parents = git_head_parents(project)
    # Merge commits create a self-reference problem for pre-push: adding the
    # merge SHA into evidence would change that same SHA. Accept evidence that
    # names the first parent, i.e. the verified branch tip before merging main.
    if len(parents) > 1 and parents[0] in evidence_commits:
        return True
    # Non-merge commits have the same self-reference problem only for
    # metadata-only evidence commits. Do not let a code commit inherit stale
    # first-parent evidence.
    if bool(parents) and parents[0] in evidence_commits and head_is_metadata_only(project, parents[0]):
        return True
    # Closed task evidence should not be invalidated by later commits that
    # touch files outside that task's declared scope. Same-scope changes still
    # require fresh evidence and remain blocked by the review_old_sha test.
    ancestor = nearest_evidence_ancestor(project, head, evidence_commits)
    return bool(ancestor and task_scope_unchanged_since(project, task, ancestor, head))


def is_git_repo(project: Path) -> bool:
    return (project / ".git").exists() and bool(git_head(project))


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(errors="replace")
    except FileNotFoundError:
        return ""


def clean_value(value: str | None) -> str:
    if value is None:
        return ""
    value = value.strip()
    if value.startswith("`") and value.endswith("`"):
        value = value[1:-1].strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1].strip()
    if value.startswith("'") and value.endswith("'"):
        value = value[1:-1].strip()
    return value.strip()


def resolve_path(project: Path, value: str) -> Path:
    value = clean_value(value)
    path = Path(value)
    if path.is_absolute():
        return path
    return project / path


def require_checkpoint_path(project: Path, task_id: str, path: Path, label: str) -> None:
    expected = (project / ".checkpoints" / task_id).resolve()
    try:
        path.resolve().relative_to(expected)
    except ValueError as exc:
        raise GateError(f"{task_id}: {label} must live under .checkpoints/{task_id}/") from exc


def is_tracker_path(path: Path) -> bool:
    name = path.name
    raw = str(path)
    if "/node_modules/" in raw or "/.git/" in raw:
        return False
    return (
        name in {"WORKPLAN.md", "HANDOFF.md", "active-tracker", "active-tracker.md"}
        or name.endswith("-tracker.md")
        or "active-tracker" in name
        or "phase0-plan" in name
        or (name.lower().endswith((".md", ".markdown")) and "plan" in name.lower())
        or "/.claude/plans/" in raw
    )


def is_source_path(path: Path) -> bool:
    return path.suffix in {".go", ".py", ".ts", ".tsx", ".js", ".jsx", ".rs", ".java", ".kt", ".swift", ".rb"}


def is_governed_path(path: Path) -> bool:
    raw = str(path)
    if "/.git/" in raw or "/node_modules/" in raw or "/dist/" in raw or "/build/" in raw:
        return False
    if "/.checkpoints/" in raw or "/.claude/" in raw:
        return False
    if path.name in {"WORKPLAN.md", "HANDOFF.md"}:
        return False
    return path.suffix in GOVERNED_SUFFIXES


def is_test_path(path: Path) -> bool:
    name = path.name
    return (
        name.endswith(("_test.go", "_test.py"))
        or name.startswith("test_")
        or ".test." in name
        or ".spec." in name
    )


def parse_tasks(text: str) -> tuple[list[Task], list[str]]:
    lines = text.splitlines()
    starts: list[int] = []
    for index, line in enumerate(lines):
        if CHECKBOX_RE.match(line):
            starts.append(index)

    tasks: list[Task] = []
    errors: list[str] = []
    for pos, start in enumerate(starts):
        end = starts[pos + 1] if pos + 1 < len(starts) else len(lines)
        line = lines[start]
        match = CHECKBOX_RE.match(line)
        if not match:
            continue
        indent = len(match.group(1))
        state = match.group(2).lower()
        title = match.group(3).strip()
        id_match = TASK_ID_RE.match(title)
        task_id = id_match.group(1) if id_match else None
        if not task_id or task_id == "TASK-ID":
            errors.append(f"line {start + 1}: checkbox is missing a concrete TASK-ID")
        block = lines[start:end]
        meta: dict[str, str] = {}
        for block_line in block[1:]:
            field_match = FIELD_RE.match(block_line)
            if field_match:
                meta[field_match.group(1).lower()] = field_match.group(2).strip()
        tasks.append(
            Task(
                task_id=task_id,
                line_no=start + 1,
                indent=indent,
                checked=state == "x",
                skip="[SKIP]" in line,
                title=title,
                block=block,
                meta=meta,
            )
        )
    return tasks, errors


def tasks_by_id(tasks: Iterable[Task]) -> dict[str, Task]:
    result: dict[str, Task] = {}
    for task in tasks:
        if task.task_id:
            result[task.task_id] = task
    return result


def validate_evidence(project: Path, task: Task, context: str = "task evidence") -> None:
    evidence_value = clean_value(task.meta.get("evidence", ""))
    if not evidence_value or evidence_value.lower() in {"pending", "n/a", "none", "todo"} or evidence_value.startswith("<"):
        raise GateError(f"{task.task_id}: {context} path is missing or placeholder")

    evidence_path = resolve_path(project, evidence_value)
    require_checkpoint_path(project, task.task_id or "UNKNOWN", evidence_path, context)
    if not evidence_path.exists():
        raise GateError(f"{task.task_id}: evidence file '{evidence_value}' does not exist")
    if evidence_path.stat().st_size == 0:
        raise GateError(f"{task.task_id}: evidence file '{evidence_value}' is empty")

    evidence_text = read_text(evidence_path)
    if not re.search(r"^(Command|Verify command|Verify|Test command|How verified|command_or_artifact):", evidence_text, re.M):
        raise GateError(f"{task.task_id}: evidence '{evidence_value}' lacks command/verify field")
    if not re.search(r"^(Result|Outcome|Logs|Output|result):", evidence_text, re.M):
        raise GateError(f"{task.task_id}: evidence '{evidence_value}' lacks result/output field")
    if not re.search(r"^(Commit|SHA|Fix commit|commit):", evidence_text, re.M):
        raise GateError(f"{task.task_id}: evidence '{evidence_value}' lacks commit/SHA field")

    head = git_head(project)
    file_commits = set(HEX_RE.findall(evidence_text))
    evidence_commits = set(file_commits)
    meta_commit = clean_value(task.meta.get("commit", ""))
    if HEX_RE.fullmatch(meta_commit):
        evidence_commits.add(meta_commit)
    lowered = f"{task.text}\n{evidence_text}".lower()
    is_prefix_evidence = "pre-fix" in lowered or "pre-review" in lowered
    if head and not is_prefix_evidence:
        if not head_matches_evidence(project, head, file_commits, task):
            found = ", ".join(sorted(file_commits)) or "none"
            raise GateError(f"{task.task_id}: evidence file SHA is stale or missing current HEAD {head}; found {found}")

    is_review = task.task_type == "review" or "review" in lowered or "codex" in lowered
    if is_review:
        if "diff-only" in lowered and "diff-only: false" not in lowered:
            raise GateError(f"{task.task_id}: review evidence is diff-only")
        if "full-code-path" not in lowered:
            raise GateError(f"{task.task_id}: review evidence must include full-code-path")
        if head and not head_matches_evidence(project, head, evidence_commits, task) and not is_prefix_evidence:
            raise GateError(f"{task.task_id}: review evidence must match current HEAD {head}")

    if "codex" in lowered:
        if "claude code plugin" not in lowered or "codex:rescue" not in lowered or "codex:codex-rescue" not in lowered:
            raise GateError(f"{task.task_id}: Codex evidence must come from Claude Code plugin + codex:rescue")
        if "agents.md" not in lowered:
            raise GateError(f"{task.task_id}: Codex evidence must prove AGENTS.md was read")
        if "verbatim" not in lowered:
            raise GateError(f"{task.task_id}: Codex evidence must preserve verbatim review output")

    if task.checked and task.status == "done" and task.required:
        if not re.search(r"(Senior-review:\s*PASS|Senior Engineer[^\n]*PASS)", evidence_text, re.I):
            raise GateError(f"{task.task_id}: DONE requires Senior review PASS evidence")
        if "full-code-path" not in lowered:
            raise GateError(f"{task.task_id}: DONE requires full-code-path review evidence")
        for token in ["claude code plugin", "codex:rescue", "codex:codex-rescue", "agents.md", "verbatim"]:
            if token not in lowered:
                raise GateError(f"{task.task_id}: DONE requires Codex review evidence with {token}")

    for label, pattern in required_stack_checks(task):
        if not re.search(pattern, lowered):
            raise GateError(f"{task.task_id}: evidence missing required {label} check for touched stack")


def required_stack_checks(task: Task) -> list[tuple[str, str]]:
    text = f"{task.text}\n{task.meta.get('verification', '')}\n{task.meta.get('scope', '')}".lower()
    if task.task_type not in {"code", "test", "ci"}:
        return []
    checks: list[tuple[str, str]] = []
    if re.search(r"\.(ts|tsx|js|jsx)\b", text):
        checks.extend(
            [
                ("tests", r"\b(test|jest|vitest|npm test|pnpm test|yarn test)\b"),
                ("lint", r"\b(lint|eslint)\b"),
                ("typecheck", r"\b(typecheck|tsc)\b"),
            ]
        )
    elif re.search(r"\.py\b", text):
        checks.extend(
            [
                ("tests", r"\b(test|pytest|unittest)\b"),
                ("lint", r"\b(lint|ruff|flake8|pylint)\b"),
            ]
        )
    elif re.search(r"\.go\b", text):
        checks.extend(
            [
                ("tests", r"\bgo test\b"),
                ("static analysis", r"\b(go vet|staticcheck|lint)\b"),
            ]
        )
    else:
        checks.append(("tests", r"\b(test|tests)\b"))
    if "coverage" in text:
        checks.append(("coverage", r"\bcoverage\b"))
    if "ci" in text or ".github/workflows" in text:
        checks.append(("CI", r"\bci\b"))
    return checks


def validate_task_contract(project: Path, text: str, *, closed_evidence: bool = True) -> list[Task]:
    tasks, errors = parse_tasks(text)
    if errors:
        raise GateError("; ".join(errors))

    seen: set[str] = set()
    for task in tasks:
        if not task.task_id:
            continue
        if task.task_id in seen:
            raise GateError(f"{task.task_id}: duplicate TASK-ID")
        seen.add(task.task_id)

        missing = [field for field in REQUIRED_FIELDS if not clean_value(task.meta.get(field))]
        if missing:
            raise GateError(f"{task.task_id}: missing metadata fields: {', '.join(missing)}")

        if task.task_type not in VALID_TYPES:
            raise GateError(f"{task.task_id}: invalid type '{task.meta.get('type', '')}'")
        required_value = clean_value(task.meta.get("required", "")).lower()
        if required_value not in {"true", "false"}:
            raise GateError(f"{task.task_id}: required must be true or false")
        if task.status not in VALID_STATUSES:
            raise GateError(f"{task.task_id}: invalid status '{task.meta.get('status', '')}'")

        if task.checked:
            if task.status not in {"done", "waived"}:
                raise GateError(f"{task.task_id}: closed checkbox requires status done or waived")
            if task.status == "waived":
                for field in ["reason", "risk", "owner", "tracker"]:
                    if not re.search(rf"^\s+-\s+{field}:\s*\S", task.text, re.M | re.I):
                        raise GateError(f"{task.task_id}: waived checkbox requires {field}")
            if closed_evidence:
                validate_evidence(project, task)

    # Parent cannot close while child remains open.
    for index, parent in enumerate(tasks):
        if not parent.checked or not parent.task_id:
            continue
        for child in tasks[index + 1 :]:
            if child.indent <= parent.indent:
                break
            if child.required and not child.checked and child.status not in {"done", "waived"}:
                raise GateError(f"{parent.task_id}: parent closed while child {child.task_id} is still open")

    return tasks


def validate_deleted_or_renamed_required(old_text: str, new_text: str) -> None:
    old_tasks, _ = parse_tasks(old_text)
    new_tasks, _ = parse_tasks(new_text)
    old_required = {task.task_id for task in old_tasks if task.task_id and task.required}
    new_ids = {task.task_id for task in new_tasks if task.task_id}
    added_ids = new_ids - {task.task_id for task in old_tasks if task.task_id}
    missing_ids = old_required - new_ids
    for task_id in sorted(missing_ids):
        waive_re = re.compile(
            rf"WAIVE:\s*{re.escape(task_id)}[\s\S]*reason:\s*\S[\s\S]*risk:\s*\S[\s\S]*owner:\s*\S[\s\S]*tracker:\s*\S",
            re.IGNORECASE,
        )
        if waive_re.search(new_text):
            continue
        if added_ids:
            renamed = any(
                re.search(
                    rf"(history|deviation)[\s\S]*{re.escape(task_id)}[\s\S]*{re.escape(new_id)}",
                    new_text,
                    re.IGNORECASE,
                )
                for new_id in added_ids
            )
            if renamed:
                continue
        raise GateError(f"{task_id}: required checkbox deleted or renamed without WAIVE/history evidence")


def parse_attempts(handoff_text: str) -> list[dict[str, str]]:
    attempts: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in handoff_text.splitlines():
        match = re.match(r"^\s*-\s*attempt:\s*(.+)$", line)
        if match:
            if current:
                attempts.append(current)
            current = {"attempt": match.group(1).strip()}
            continue
        if current is None:
            continue
        field_match = re.match(r"^\s*-?\s*([a-z_]+):\s*(.*)$", line)
        if field_match:
            current[field_match.group(1).lower()] = field_match.group(2).strip()
    if current:
        attempts.append(current)
    return attempts


def retry_budget(task: Task) -> int:
    text = f"{task.title}\n{task.text}".lower()
    if task.task_type in {"docs", "adr"} or "config" in text:
        return 2
    if task.task_type == "safety" or "destructive" in text or "security-sensitive" in text:
        return 1
    if "critical" in text or "production" in text or "incident" in text:
        return 3
    return 3


def validate_attempt_evidence(project: Path, attempt: dict[str, str], task_id: str) -> None:
    evidence_value = clean_value(attempt.get("evidence", ""))
    if not evidence_value or evidence_value.lower() in {"pending", "n/a", "none"}:
        raise GateError(f"{task_id}: attempt {attempt.get('attempt')} lacks evidence path")
    evidence_path = resolve_path(project, evidence_value)
    require_checkpoint_path(project, task_id, evidence_path, "attempt evidence")
    if not evidence_path.exists():
        raise GateError(f"{task_id}: attempt evidence '{evidence_value}' does not exist")
    if evidence_path.stat().st_size == 0:
        raise GateError(f"{task_id}: attempt evidence '{evidence_value}' is empty")

    head = git_head(project)
    commit_value = clean_value(attempt.get("commit", ""))
    evidence_text = read_text(evidence_path)
    lowered = f"{commit_value}\n{evidence_text}".lower()
    if head and HEX_RE.fullmatch(commit_value) and commit_value != head:
        if "pre-fix" not in lowered and "pre-review" not in lowered:
            raise GateError(f"{task_id}: attempt {attempt.get('attempt')} commit {commit_value} is stale vs HEAD {head}")


def validate_blocked_or_failed_task(project: Path, task: Task) -> None:
    task_id = task.task_id or "UNKNOWN"
    blocker_text = task.text
    if INVALID_BLOCKER_RE.search(blocker_text):
        raise GateError(f"{task_id}: invalid blocker text")
    if not VALID_BLOCKER_RE.search(blocker_text):
        raise GateError(f"{task_id}: blocker is not specific and actionable")

    handoff = project / "HANDOFF.md"
    if not handoff.exists():
        raise GateError(f"{task_id}: blocked/failed requires HANDOFF.md attempt log")
    attempts = [item for item in parse_attempts(read_text(handoff)) if clean_value(item.get("task_id", "")) == task_id]
    if not attempts:
        raise GateError(f"{task_id}: HANDOFF.md has no attempt entries for this task")

    for attempt in attempts:
        missing = [field for field in ATTEMPT_FIELDS if not clean_value(attempt.get(field))]
        if missing:
            raise GateError(f"{task_id}: attempt {attempt.get('attempt', '?')} missing fields: {', '.join(missing)}")
        validate_attempt_evidence(project, attempt, task_id)

    budget = retry_budget(task)
    if len(attempts) < budget:
        raise GateError(f"{task_id}: retry budget not exhausted, has {len(attempts)} attempt(s), needs {budget}")

    seen_hypotheses: set[str] = set()
    for attempt in attempts:
        hypothesis = re.sub(r"\s+", " ", clean_value(attempt.get("hypothesis", "")).lower())
        if hypothesis in seen_hypotheses:
            raise GateError(f"{task_id}: repeated failed attempt without new hypothesis")
        seen_hypotheses.add(hypothesis)

    attempts_text = "\n".join(" ".join(item.values()) for item in attempts)
    lowered = attempts_text.lower()
    if len(attempts) >= 2 and not re.search(
        r"(strategy_shift|strategy shift|search_docs|consult_senior|consult_codex|codex:rescue)",
        lowered,
    ):
        raise GateError(f"{task_id}: no strategy shift after repeated failure")

    missing_sources = [token for token in LOCAL_SOURCE_TOKENS if token not in lowered]
    if missing_sources:
        raise GateError(f"{task_id}: blocked/failed before local sources were used: {', '.join(missing_sources)}")

    if EXTERNAL_RE.search(blocker_text) and not DOC_SEARCH_RE.search(attempts_text):
        raise GateError(f"{task_id}: external/tooling blocker without internet/Context7/docs search")

    if not CONSULT_RE.search(attempts_text):
        raise GateError(f"{task_id}: stuck task lacks Senior Engineer or codex:rescue consultation")


def validate_handoff_update(project: Path, old_text: str, new_text: str) -> None:
    old_attempts = parse_attempts(old_text)
    new_attempts = parse_attempts(new_text)
    if len(new_attempts) < len(old_attempts):
        raise GateError("HANDOFF.md attempt history cannot shrink")
    old_keys = {(item.get("task_id", ""), item.get("attempt", "")) for item in old_attempts}
    new_keys = {(item.get("task_id", ""), item.get("attempt", "")) for item in new_attempts}
    missing = sorted(old_keys - new_keys)
    if missing:
        task_id, attempt = missing[0]
        raise GateError(f"HANDOFF.md cannot remove attempt history for {task_id} attempt {attempt}")
    for attempt in new_attempts:
        missing_fields = [field for field in ATTEMPT_FIELDS if not clean_value(attempt.get(field))]
        if missing_fields:
            raise GateError(
                f"HANDOFF.md attempt {attempt.get('attempt', '?')} missing fields: {', '.join(missing_fields)}"
            )
        evidence_value = clean_value(attempt.get("evidence", ""))
        if evidence_value and evidence_value.lower() not in {"pending", "n/a", "none"}:
            evidence_path = resolve_path(project, evidence_value)
            if not evidence_path.exists() or evidence_path.stat().st_size == 0:
                raise GateError(f"HANDOFF.md attempt {attempt.get('attempt')} evidence is missing or empty")


def changed_to_blocked_or_failed(old_text: str, new_tasks: list[Task]) -> list[Task]:
    old_tasks, _ = parse_tasks(old_text)
    old_status = {task.task_id: task.status for task in old_tasks if task.task_id}
    changed: list[Task] = []
    for task in new_tasks:
        if not task.task_id:
            continue
        if task.status in {"blocked", "failed"} and old_status.get(task.task_id) != task.status:
            changed.append(task)
    return changed


def apply_tool_payload(project: Path, payload: dict) -> tuple[Path | None, str, str, str]:
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    file_value = tool_input.get("file_path") or ""
    file_path = Path(file_value).resolve() if file_value else None
    old_text = read_text(file_path) if file_path and file_path.exists() else ""
    post_text = old_text
    new_fragment = ""

    if tool == "Write":
        post_text = str(tool_input.get("content") or "")
        new_fragment = post_text
    elif tool == "Edit":
        old = str(tool_input.get("old_string") or "")
        new = str(tool_input.get("new_string") or "")
        new_fragment = new
        post_text = old_text.replace(old, new, 1) if old and old in old_text else new
    elif tool == "MultiEdit":
        post_text = old_text
        fragments: list[str] = []
        for edit in tool_input.get("edits") or []:
            old = str(edit.get("old_string") or "")
            new = str(edit.get("new_string") or "")
            fragments.append(new)
            post_text = post_text.replace(old, new, 1) if old and old in post_text else post_text + "\n" + new
        new_fragment = "\n".join(fragments)
    return file_path, old_text, post_text, new_fragment


def active_tracker_path(project: Path) -> Path | None:
    pointer = project / ".claude" / "active-tracker"
    if not pointer.exists():
        return None
    value = read_text(pointer).strip()
    if not value:
        return None
    path = Path(value)
    return path if path.is_absolute() else project / path


def find_active_task(project: Path) -> Task | None:
    tasks = find_active_tasks(project)
    return tasks[0] if tasks else None


def find_active_tasks(project: Path) -> list[Task]:
    candidates = [project / "WORKPLAN.md"]
    tracker = active_tracker_path(project)
    if tracker:
        candidates.insert(0, tracker)
    for candidate in candidates:
        if not candidate.exists():
            continue
        tasks, _ = parse_tasks(read_text(candidate))
        active = [
            task
            for task in tasks
            if task.status == "in_progress" or (task.required and not task.checked and task.status == "planned")
        ]
        if active:
            return active
    return []


def task_scope_matches_path(task: Task, rel: str, path: Path) -> bool:
    scope = clean_value(task.meta.get("scope", ""))
    return bool(scope and (rel in scope or path.name in scope))


def select_active_task_for_paths(project: Path, staged_paths: list[str]) -> Task | None:
    tasks = [task for task in find_active_tasks(project) if task.task_id]
    if not tasks:
        return None
    governed = [rel for rel in staged_paths if is_governed_path(project / rel)]
    if not governed:
        return None

    matches: list[Task] = []
    for task in tasks:
        if all(task_scope_matches_path(task, rel, project / rel) for rel in governed):
            matches.append(task)

    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        ids = ", ".join(task.task_id or "UNKNOWN" for task in matches)
        raise GateError(f"multiple active tasks match staged files: {ids}. Narrow task scope or stage one task at a time")
    if len(tasks) > 1:
        ids = ", ".join(task.task_id or "UNKNOWN" for task in tasks)
        staged = ", ".join(governed)
        raise GateError(f"staged files do not match any single active task scope: {staged}. Active tasks: {ids}")
    return tasks[0]


def validate_governed_edit(project: Path, file_path: Path) -> None:
    if not is_governed_path(file_path):
        return
    task = find_active_task(project)
    if not task or not task.task_id:
        raise GateError(f"{file_path}: edit requires an active TASK-ID")
    rel = str(file_path)
    try:
        rel = str(file_path.relative_to(project))
    except ValueError:
        pass
    scope = clean_value(task.meta.get("scope", ""))
    if rel not in scope and file_path.name not in scope:
        raise GateError(f"{task.task_id}: changed file '{rel}' is not tied to task scope")

    handoff = project / "HANDOFF.md"
    handoff_text = read_text(handoff)
    pvc_re = re.compile(
        rf"plan_vs_code_check:\s*{re.escape(task.task_id)}[\s\S]*files:\s*.*{re.escape(file_path.name)}[\s\S]*mismatch:\s*\S[\s\S]*decision:\s*\S",
        re.IGNORECASE,
    )
    if not pvc_re.search(handoff_text):
        raise GateError(f"{task.task_id}: pre-edit requires plan-vs-code check with files, mismatch and decision")

    if task.task_type == "code" and is_source_path(file_path) and not is_test_path(file_path):
        pref = project / ".checkpoints" / task.task_id / "pre-fix-failing-test.md"
        pref_text = read_text(pref)
        if not pref.exists() or not re.search(r"Result:\s*FAIL", pref_text, re.I) or not re.search(r"Command:", pref_text):
            raise GateError(f"{task.task_id}: behavior-code edit requires failing test evidence before fix")


def validate_tracker_update(project: Path, old_text: str, new_text: str) -> None:
    tasks = validate_task_contract(project, new_text, closed_evidence=True)
    validate_deleted_or_renamed_required(old_text, new_text)
    for task in changed_to_blocked_or_failed(old_text, tasks):
        validate_blocked_or_failed_task(project, task)


def latest_relevant_change(project: Path) -> tuple[float, Path | None]:
    suffixes = {
        ".go",
        ".py",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".sh",
        ".sql",
        ".yml",
        ".yaml",
        ".toml",
        ".json",
        ".md",
    }
    latest = 0.0
    latest_path: Path | None = None
    for root, dirs, files in os.walk(project):
        root_path = Path(root)
        parts = set(root_path.parts)
        if ".git" in parts or "node_modules" in parts or ".checkpoints" in parts:
            dirs[:] = []
            continue
        if ".claude" in parts:
            dirs[:] = []
            continue
        for name in files:
            path = root_path / name
            if path.name in {"WORKPLAN.md", "HANDOFF.md"}:
                continue
            if path.suffix not in suffixes:
                continue
            mtime = path.stat().st_mtime
            if mtime > latest:
                latest = mtime
                latest_path = path
    return latest, latest_path


def validate_workplan_handoff_fresh(project: Path) -> None:
    latest, latest_path = latest_relevant_change(project)
    if not latest_path:
        return
    for name in ["WORKPLAN.md", "HANDOFF.md"]:
        path = project / name
        if not path.exists():
            raise GateError(f"{name} missing while source files changed")
        if path.stat().st_mtime + 1 < latest:
            raise GateError(f"{name} is older than latest changed file {latest_path.relative_to(project)}")


def validate_stop(project: Path) -> None:
    tracker = active_tracker_path(project)
    if not tracker:
        raise GateError("no active plan tracker; create .claude/active-tracker before task start or DONE")
    if not tracker.exists():
        raise GateError(f"active tracker '{tracker}' missing")
    text = read_text(tracker)
    tasks = validate_task_contract(project, text, closed_evidence=True)
    if not tasks:
        raise GateError("active plan has zero checkbox tasks")
    if not any(task.required for task in tasks):
        raise GateError("active plan has zero required tasks; active-tracker cannot point to a trivial/session-only tracker")
    for task in tasks:
        if task.required and not task.checked and task.status not in {"done", "waived"}:
            raise GateError(f"DONE blocked: required {task.task_id} is still open")
        if task.status in {"blocked", "failed"}:
            validate_blocked_or_failed_task(project, task)
    validate_workplan_handoff_fresh(project)


def validate_precommit(project: Path) -> None:
    tracker = active_tracker_path(project)
    if tracker and tracker.exists():
        validate_task_contract(project, read_text(tracker), closed_evidence=True)
    validate_workplan_handoff_fresh(project)
    staged = run(["git", "diff", "--cached", "--name-only"], cwd=project)
    staged_paths = [line for line in staged.splitlines() if line.strip()]
    task = select_active_task_for_paths(project, staged_paths)
    if staged_paths and task and task.task_id:
        for rel in staged_paths:
            path = project / rel
            if not is_governed_path(path):
                continue
            if not task_scope_matches_path(task, rel, path):
                raise GateError(f"{task.task_id}: staged file '{rel}' is outside task scope")


def payload_exit_code(payload: dict) -> int | None:
    candidates = [
        payload.get("exit_code"),
        payload.get("status"),
        (payload.get("tool_response") or {}).get("exit_code") if isinstance(payload.get("tool_response"), dict) else None,
        (payload.get("tool_result") or {}).get("exit_code") if isinstance(payload.get("tool_result"), dict) else None,
        (payload.get("result") or {}).get("exit_code") if isinstance(payload.get("result"), dict) else None,
    ]
    for value in candidates:
        if isinstance(value, int):
            return value
        if isinstance(value, str) and re.fullmatch(r"-?\d+", value.strip()):
            return int(value.strip())
    return None


def is_failure_trigger(command: str) -> bool:
    return bool(
        re.search(
            r"\b(test|pytest|unittest|go test|npm test|pnpm test|yarn test|vitest|jest|lint|eslint|ruff|flake8|pylint|typecheck|tsc|mypy|pyright|gh pr checks|gh run|codeql|codex|review)\b",
            command,
            re.IGNORECASE,
        )
    )


def validate_recent_failed_attempt(project: Path, command: str) -> None:
    task = find_active_task(project)
    if not task or not task.task_id:
        raise GateError("verification failed but no active TASK-ID is available for Ralph Loop attempt logging")
    handoff = project / "HANDOFF.md"
    attempts = [item for item in parse_attempts(read_text(handoff)) if clean_value(item.get("task_id", "")) == task.task_id]
    if not attempts:
        raise GateError(f"{task.task_id}: verification failed but HANDOFF.md has no attempt entry")
    latest = attempts[-1]
    missing = [field for field in ATTEMPT_FIELDS if not clean_value(latest.get(field))]
    if missing:
        raise GateError(f"{task.task_id}: latest failed attempt missing fields: {', '.join(missing)}")
    validate_attempt_evidence(project, latest, task.task_id)
    evidence_path = resolve_path(project, clean_value(latest.get("evidence", "")))
    try:
        age = max(0.0, __import__("time").time() - evidence_path.stat().st_mtime)
    except FileNotFoundError:
        raise GateError(f"{task.task_id}: failed attempt evidence missing")
    if age > 900:
        raise GateError(f"{task.task_id}: failed attempt evidence is stale ({int(age)}s old)")
    artifact = f"{latest.get('command_or_artifact', '')}\n{read_text(evidence_path)}"
    command_token = command.strip().split()[0] if command.strip() else ""
    if command_token and command_token not in artifact:
        raise GateError(f"{task.task_id}: latest attempt does not reference failed command '{command_token}'")

    latest_hypothesis = re.sub(r"\s+", " ", clean_value(latest.get("hypothesis", "")).lower())
    previous_hypotheses = {
        re.sub(r"\s+", " ", clean_value(item.get("hypothesis", "")).lower())
        for item in attempts[:-1]
    }
    if latest_hypothesis in previous_hypotheses:
        raise GateError(f"{task.task_id}: latest failed attempt repeats an earlier hypothesis")

    latest_text = " ".join(latest.values()).lower()
    if len(attempts) >= 2 and not re.search(
        r"(strategy_shift|strategy shift|search_docs|consult_senior|consult_codex|codex:rescue)",
        latest_text,
    ):
        raise GateError(f"{task.task_id}: repeated verification failure requires strategy shift")

    workplan = project / "WORKPLAN.md"
    if not workplan.exists():
        raise GateError(f"{task.task_id}: verification failure requires WORKPLAN.md update")
    if workplan.stat().st_mtime + 1 < evidence_path.stat().st_mtime:
        raise GateError(f"{task.task_id}: WORKPLAN.md was not updated after latest failed attempt evidence")


def handle_pretool(project: Path) -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        return
    payload = json.loads(raw)
    tool = payload.get("tool_name") or ""
    if tool not in {"Edit", "Write", "MultiEdit"}:
        return
    file_path, old_text, post_text, _ = apply_tool_payload(project, payload)
    if not file_path:
        return
    if file_path.name == "HANDOFF.md":
        validate_handoff_update(project, old_text, post_text)
    elif is_tracker_path(file_path):
        validate_tracker_update(project, old_text, post_text)
    else:
        validate_governed_edit(project, file_path)


def handle_posttool_failure(project: Path) -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        return
    payload = json.loads(raw)
    if (payload.get("tool_name") or "") != "Bash":
        return
    command = ((payload.get("tool_input") or {}).get("command") or "").strip()
    code = payload_exit_code(payload)
    if code is None or code == 0:
        return
    if not is_failure_trigger(command):
        return
    validate_recent_failed_attempt(project, command)


def handle_validate_file(project: Path, file_path: Path) -> None:
    validate_task_contract(project, read_text(file_path), closed_evidence=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["pretool", "posttool-failure", "stop", "precommit", "validate-file"])
    parser.add_argument("--project")
    parser.add_argument("--file")
    args = parser.parse_args()
    project = resolve_project(args.project)
    try:
        if args.mode == "pretool":
            handle_pretool(project)
        elif args.mode == "posttool-failure":
            handle_posttool_failure(project)
        elif args.mode == "stop":
            validate_stop(project)
        elif args.mode == "precommit":
            validate_precommit(project)
        elif args.mode == "validate-file":
            if not args.file:
                raise GateError("validate-file requires --file")
            handle_validate_file(project, Path(args.file).resolve())
    except GateError as exc:
        deny(str(exc), "PreToolUse" if args.mode == "pretool" else None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
