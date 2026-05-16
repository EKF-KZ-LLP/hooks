#!/usr/bin/env python3
import difflib
import json
import os
import re
import stat
import subprocess
import sys


CHECKBOX_RE = re.compile(r"^- \[([ x])\]( \[SKIP\])? (.*)$")
OPEN_CHECKBOX_RE = re.compile(r"^- \[ \] (.*)$")
CLOSED_CHECKBOX_RE = re.compile(r"^- \[x\]( \[SKIP\])? (.*)$")
TASK_ID_RE = re.compile(r"^(?:\*\*)?([A-Z][A-Z0-9]*-[0-9A-Z._-]+):")
STATUS_RE = re.compile(r"^\s+-?\s*status:\s*([A-Za-z_-]+)\s*$")
EVIDENCE_RE = re.compile(r"^\s+-\s+evidence:\s*(.+?)\s*$")
COMPLETION_META_RE = re.compile(r"^\s+-\s+(result|commit|status):\s*(.+?)\s*$")


def allow() -> None:
    raise SystemExit(0)


def block(message: str) -> None:
    sys.stderr.write(f"::error::ralph-loop-03: {message}\n")
    raise SystemExit(2)


def repo_root(cwd: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return out or None
    except Exception:
        return None


def norm_path(value: str, base: str) -> str:
    value = os.path.expanduser(value.strip())
    if not value:
        return ""
    path = value if os.path.isabs(value) else os.path.join(base, value)
    if os.path.exists(path):
        return os.path.realpath(path)
    parent = os.path.dirname(path) or "."
    if os.path.exists(parent):
        return os.path.join(os.path.realpath(parent), os.path.basename(path))
    return os.path.abspath(path)


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def chmod_mode(path: str) -> str:
    return oct(stat.S_IMODE(os.stat(path).st_mode))[2:]


def direct_evidence_target(raw_target: str, norm_target: str) -> bool:
    candidates = [raw_target.replace("\\", "/"), norm_target.replace("\\", "/")]
    protected_names = (
        "evidence.md",
        "skip-reason.md",
        "codex-review-raw.txt",
        "iteration-count",
    )
    for candidate in candidates:
        if "/.checkpoints/" not in candidate:
            continue
        base = os.path.basename(candidate)
        if base in protected_names:
            return True
        if base.startswith("attempt-") and base.endswith(".md"):
            return True
        if base == "pre-fix-failing-test.md":
            return True
        if "review" in base and base.endswith(".md"):
            return True
    return False


def approval_refs_target(norm_target: str) -> bool:
    return norm_target.replace("\\", "/").endswith("/.claude/approval-refs.allow")


def clean_evidence_path(value: str) -> str:
    return value.strip().strip("`").strip()


def owner_checkbox(lines: list[str], index: int) -> tuple[int, re.Match[str]] | None:
    if not lines:
        return None
    index = min(index, len(lines) - 1)
    for i in range(index, -1, -1):
        match = CHECKBOX_RE.match(lines[i])
        if match:
            return i, match
    return None


def task_block_end(lines: list[str], checkbox_index: int) -> int:
    end = len(lines)
    for i in range(checkbox_index + 1, len(lines)):
        if CHECKBOX_RE.match(lines[i]):
            return i
    return end


def evidence_for_task(lines: list[str], checkbox_index: int) -> str | None:
    for line in lines[checkbox_index + 1 : task_block_end(lines, checkbox_index)]:
        match = EVIDENCE_RE.match(line)
        if match:
            return clean_evidence_path(match.group(1))
    return None


def task_id_from_checkbox(match: re.Match[str]) -> str | None:
    task_id = TASK_ID_RE.match(match.group(3).strip())
    return task_id.group(1) if task_id else None


def validate_new_task_evidence_path(repo: str, evidence_rel: str, task_id: str) -> None:
    evidence_rel = clean_evidence_path(evidence_rel)
    if not evidence_rel or evidence_rel.lower() in {"pending", "n/a", "none", "todo"}:
        block("new task evidence path must be concrete.")
    if evidence_rel.startswith("<") or os.path.isabs(evidence_rel):
        block("new task evidence path must be a relative .checkpoints path.")
    evidence_abs = norm_path(evidence_rel, repo)
    expected_dir = norm_path(os.path.join(".checkpoints", task_id), repo)
    try:
        common = os.path.commonpath([evidence_abs, expected_dir])
    except ValueError:
        common = ""
    if evidence_abs == expected_dir or common != expected_dir:
        block(f"new task evidence must live under .checkpoints/{task_id}/.")


def validate_pass_evidence(repo: str, lines: list[str], checkbox_index: int) -> None:
    evidence_rel = evidence_for_task(lines, checkbox_index)
    if not evidence_rel:
        block("task block has no `evidence:` marker. Run run-codex-review.sh first.")
    evidence_abs = norm_path(evidence_rel, repo)
    if not os.path.isfile(evidence_abs):
        block(f"evidence file '{evidence_abs}' missing. Run run-codex-review.sh first.")
    mode = chmod_mode(evidence_abs)
    if mode != "444":
        block(
            f"evidence file '{evidence_abs}' has perms '{mode}', expected '444'. "
            "Re-generate via run-codex-review.sh."
        )
    text = read_text(evidence_abs)
    if not re.search(r"^Verdict:[ \t]+PASS([ \t]|$)", text, re.MULTILINE):
        block(
            f"evidence file '{evidence_abs}' does not contain literal 'Verdict: PASS'. "
            "Keep task open and continue work."
        )


def validate_fail_evidence(repo: str, lines: list[str], checkbox_index: int) -> None:
    evidence_rel = evidence_for_task(lines, checkbox_index)
    if not evidence_rel:
        block("failed task has no `evidence:` marker. Record Codex FAIL evidence first.")
    evidence_abs = norm_path(evidence_rel, repo)
    if not os.path.isfile(evidence_abs):
        block(f"fail evidence file '{evidence_abs}' missing. Record Codex FAIL evidence first.")
    mode = chmod_mode(evidence_abs)
    if mode != "444":
        block(
            f"fail evidence file '{evidence_abs}' has perms '{mode}', expected '444'. "
            "Re-generate or freeze the Codex verdict evidence first."
        )
    text = read_text(evidence_abs)
    if not re.search(r"^Verdict:[ \t]+FAIL([ \t]|$)", text, re.MULTILINE):
        block(
            f"fail evidence file '{evidence_abs}' does not contain literal 'Verdict: FAIL'. "
            "Use failed only for a real failed verdict, not as a bypass."
        )


def validate_skip(repo: str, lines: list[str], checkbox_index: int) -> None:
    evidence_rel = evidence_for_task(lines, checkbox_index)
    if not evidence_rel:
        block("SKIP task has no evidence path to derive skip-reason.md location.")
    skip_file = os.path.join(os.path.dirname(norm_path(evidence_rel, repo)), "skip-reason.md")
    if not os.path.isfile(skip_file):
        block(
            f"SKIP flip requires '{skip_file}'. Only hook 02 from user OVERRIDE can create it."
        )
    if chmod_mode(skip_file) != "444":
        block(f"skip-reason '{skip_file}' must be chmod 444.")
    text = read_text(skip_file)
    if "Author: user-override-hook02" not in text:
        block(f"skip-reason '{skip_file}' missing user override marker.")
    if not re.search(r"^Override-prompt-hash: [0-9a-f]{64}$", text, re.MULTILINE):
        block(f"skip-reason '{skip_file}' missing override prompt hash.")


def inserted_lines_allowed(repo: str, lines: list[str], start: int, inserted: list[str]) -> None:
    new_open_tasks: set[int] = set()
    for offset, line in enumerate(inserted):
        checkbox = CHECKBOX_RE.match(line)
        if not checkbox:
            continue
        if checkbox.group(1) != " " or checkbox.group(2):
            block("new tracker tasks must be unchecked '- [ ] ...'.")
        new_open_tasks.add(start + offset)

    for offset, line in enumerate(inserted):
        if not line.strip():
            continue
        checkbox = CHECKBOX_RE.match(line)
        if checkbox:
            continue
        owner = owner_checkbox(lines, start + offset)
        if not owner:
            block("tracker context lines must belong to an open task.")
        owner_index, match = owner
        evidence = EVIDENCE_RE.match(line)
        if evidence:
            if owner_index not in new_open_tasks:
                block("adding or changing evidence markers in existing tracker tasks is forbidden.")
            task_id = task_id_from_checkbox(match)
            if not task_id:
                block("new task with evidence must have a concrete TASK-ID.")
            validate_new_task_evidence_path(repo, evidence.group(1), task_id)
            continue
        if "evidence:" in line or ".checkpoints/" in line:
            block("adding or changing evidence markers in tracker is forbidden.")
        if match.group(1) != " ":
            block("editing completed task blocks is forbidden.")


def changed_pair_allowed(
    repo: str,
    final_lines: list[str],
    final_index: int,
    old_line: str,
    new_line: str,
) -> None:
    if old_line == new_line:
        return
    if "evidence:" in old_line or "evidence:" in new_line or ".checkpoints/" in new_line:
        block("adding or changing evidence markers in tracker is forbidden.")

    old_box = OPEN_CHECKBOX_RE.match(old_line)
    new_closed = CLOSED_CHECKBOX_RE.match(new_line)
    if old_box and new_closed:
        old_body = old_box.group(1)
        new_body = new_closed.group(2)
        if old_body != new_body:
            block("checkbox close must keep task body identical.")
        owner = owner_checkbox(final_lines, final_index)
        if not owner:
            block("could not locate closed task block.")
        checkbox_index, match = owner
        if match.group(2):
            validate_skip(repo, final_lines, checkbox_index)
        else:
            validate_pass_evidence(repo, final_lines, checkbox_index)
        return

    old_closed = CLOSED_CHECKBOX_RE.match(old_line)
    new_open = OPEN_CHECKBOX_RE.match(new_line)
    if old_closed and new_open:
        if old_closed.group(1):
            block("reopening SKIP tasks requires explicit waiver flow, not checkbox edit.")
        old_body = old_closed.group(2)
        new_body = new_open.group(1)
        if old_body != new_body:
            block("checkbox reopen must keep task body identical.")
        owner = owner_checkbox(final_lines, final_index)
        if not owner:
            block("could not locate reopened task block.")
        checkbox_index, match = owner
        if match.group(1) != " " or match.group(2):
            block("reopened task must be an unchecked non-SKIP task.")
        if not evidence_for_task(final_lines, checkbox_index):
            block("reopened task must keep its evidence marker.")
        return

    old_status = STATUS_RE.match(old_line)
    new_status = STATUS_RE.match(new_line)
    if old_status and new_status:
        old_value = old_status.group(1)
        new_value = new_status.group(1)
        if old_value in {"done", "verified", "failed"} and new_value in {"planned", "in_progress"}:
            owner = owner_checkbox(final_lines, final_index)
            if not owner:
                block("could not locate owning task for status reopen.")
            checkbox_index, match = owner
            if match.group(1) != " " or match.group(2):
                block("status reopen requires an unchecked non-SKIP task.")
            if not evidence_for_task(final_lines, checkbox_index):
                block("status reopen must keep task evidence marker.")
            return
        if old_value in {"planned", "in_progress"} and new_value == "failed":
            owner = owner_checkbox(final_lines, final_index)
            if not owner:
                block("could not locate owning task for failed status change.")
            checkbox_index, match = owner
            if match.group(1) != " " or match.group(2):
                block("status: failed requires an open non-SKIP checkbox. Failed is not a closed state.")
            validate_fail_evidence(repo, final_lines, checkbox_index)
            return
        if old_value in {"planned", "in_progress"} and new_value == "done":
            owner = owner_checkbox(final_lines, final_index)
            if not owner:
                block("could not locate owning task for status change.")
            checkbox_index, match = owner
            if match.group(1) != "x" or match.group(2):
                block("status: done requires an already closed non-SKIP task.")
            validate_pass_evidence(repo, final_lines, checkbox_index)
            return
        block(
            "allowed status transitions: planned|in_progress -> done with Verdict: PASS, "
            "planned|in_progress -> failed with Verdict: FAIL, or done|verified|failed -> planned|in_progress for reopen."
        )

    block("tracker edits may only add open tasks/context or close tasks with valid evidence.")


def completion_metadata_block_allowed(
    repo: str,
    old_full: list[str],
    new_lines: list[str],
    old_start: int,
    new_start: int,
) -> bool:
    if not old_full or not new_lines:
        return False
    old_owner = owner_checkbox(old_full, old_start)
    new_owner = owner_checkbox(new_lines, new_start)
    if not old_owner or not new_owner:
        return False

    old_checkbox_index, old_match = old_owner
    new_checkbox_index, new_match = new_owner
    if old_match.group(1) != "x" or old_match.group(2):
        return False
    if new_match.group(1) != "x" or new_match.group(2):
        return False
    if old_full[old_checkbox_index] != new_lines[new_checkbox_index]:
        return False

    old_evidence = evidence_for_task(old_full, old_checkbox_index)
    new_evidence = evidence_for_task(new_lines, new_checkbox_index)
    if not old_evidence or old_evidence != new_evidence:
        return False

    old_body = old_full[old_checkbox_index + 1 : task_block_end(old_full, old_checkbox_index)]
    new_body = new_lines[new_checkbox_index + 1 : task_block_end(new_lines, new_checkbox_index)]
    allowed_keys = {"result", "commit", "status"}
    seen_keys: set[str] = set()

    def immutable_payload(lines: list[str]) -> list[str]:
        payload: list[str] = []
        for line in lines:
            meta = COMPLETION_META_RE.match(line)
            if meta and meta.group(1) in allowed_keys:
                continue
            payload.append(line)
        return payload

    if immutable_payload(old_body) != immutable_payload(new_body):
        return False

    for line in new_body:
        meta = COMPLETION_META_RE.match(line)
        if not meta:
            continue
        key, value = meta.group(1), meta.group(2).strip()
        if key not in allowed_keys:
            return False
        if key in seen_keys:
            return False
        seen_keys.add(key)
        if key == "commit" and not re.match(r"^[0-9a-f]{7,40}$", value):
            return False
        if key == "status" and value != "verified":
            return False
        if key == "result" and ("evidence:" in value or ".checkpoints/" in value):
            # Mentioning an artifact path in prose is OK, but do not allow
            # metadata syntax that looks like a new evidence marker.
            if "evidence:" in value:
                return False

    if "status" not in seen_keys:
        return False
    validate_pass_evidence(repo, new_lines, new_checkbox_index)
    return True


def classify_tracker_edit(repo: str, original: str, final: str) -> None:
    old_lines = original.splitlines()
    new_lines = final.splitlines()
    matcher = difflib.SequenceMatcher(a=old_lines, b=new_lines, autojunk=False)
    changed = False

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        changed = True
        if tag == "delete":
            block("deleting tracker content is forbidden.")
        if tag == "insert":
            inserted_lines_allowed(repo, new_lines, j1, new_lines[j1:j2])
            continue
        if tag == "replace":
            old_part = old_lines[i1:i2]
            new_part = new_lines[j1:j2]
            if len(old_part) != len(new_part):
                if completion_metadata_block_allowed(repo, old_lines, new_lines, i1, j1):
                    continue
                block("mass rewrite or line-count-changing replacement in tracker is forbidden.")
            if len(old_part) > 4:
                block("large tracker replacement is forbidden; use small focused Edit.")
            for offset, (old_line, new_line) in enumerate(zip(old_part, new_part)):
                changed_pair_allowed(repo, new_lines, j1 + offset, old_line, new_line)
            continue
        block(f"unsupported tracker edit opcode: {tag}")

    if not changed:
        allow()


def apply_edit(original: str, tool_name: str, tool_input: dict) -> str:
    if tool_name == "Write":
        block("full-file Write of tracker forbidden. Use focused Edit.")
    edits = []
    if tool_name == "MultiEdit":
        raw_edits = tool_input.get("edits")
        if not isinstance(raw_edits, list) or not raw_edits:
            block("MultiEdit on tracker requires non-empty edits list.")
        edits = raw_edits
    else:
        edits = [
            {
                "old_string": tool_input.get("old_string", ""),
                "new_string": tool_input.get("new_string", tool_input.get("content", "")),
            }
        ]

    current = original
    for edit in edits:
        old = edit.get("old_string", "")
        new = edit.get("new_string", "")
        if not old:
            block("tracker Edit must include old_string; full rewrite is forbidden.")
        count = current.count(old)
        if count != 1:
            block("tracker Edit old_string must match exactly one location; add context lines.")
        current = current.replace(old, new, 1)
    return current


def main() -> None:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        allow()

    tool_name = data.get("tool_name") or ""
    if tool_name not in {"Edit", "Write", "MultiEdit", "NotebookEdit"}:
        allow()

    cwd = data.get("cwd") or os.getcwd()
    repo = repo_root(cwd)
    if not repo:
        allow()

    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    raw_target = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not raw_target:
        allow()
    target = norm_path(raw_target, cwd)

    active_pointer = os.path.join(repo, ".claude", "active-tracker")
    if target == norm_path(active_pointer, repo):
        block(
            "direct edit to .claude/active-tracker forbidden. "
            "Use the approved tracker bootstrap/switch hook or human terminal; "
            "agents cannot change the active tracker pointer."
        )

    if approval_refs_target(target):
        block(
            "direct edit to ~/.claude/approval-refs.allow forbidden. "
            "Approval refs must come from the human operator outside the agent tool path."
        )

    if direct_evidence_target(raw_target, target):
        block(f"direct write to '{raw_target}' forbidden. Evidence is produced only by approved helper hooks.")

    if not os.path.isfile(active_pointer):
        allow()

    tracker_candidate = read_text(active_pointer).strip()
    if tracker_candidate in {"", "__unstructured__"}:
        allow()
    tracker = norm_path(tracker_candidate, repo)
    if not os.path.isfile(tracker):
        allow()

    if target != tracker:
        allow()

    try:
        original = read_text(tracker)
        final = apply_edit(original, tool_name, tool_input)
        classify_tracker_edit(repo, original, final)
    except SystemExit:
        raise
    except Exception as exc:
        block(f"tracker edit could not be validated ({exc}); failing closed.")
    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        sys.stderr.write(f"::warning::ralph-loop-03 fail-open: {exc}\n")
        raise SystemExit(0)
