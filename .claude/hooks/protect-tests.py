# Decision logic for protect-tests.sh; reads the hook payload on stdin.
import json, os, re, subprocess, sys
root = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = payload.get("tool_name", "")
inp = payload.get("tool_input", {}) or {}

TEST_PATH = re.compile(r"(^|/)(test|tests)/|_test\.exs$")

def is_test(path):
    if not path:
        return False
    p = os.path.abspath(os.path.join(root, path)) if not os.path.isabs(path) else path
    rel = os.path.relpath(p, root)
    return TEST_PATH.search(rel) is not None and not rel.startswith("..")

def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)

RULE = ("Existing tests are read-only for agents (CLAUDE.md, 'Tests are protected'). "
        "Add a NEW test file instead, or stop and ask the owner; the owner consents by "
        "running `touch .claude/tests-unlock`.")

def tracked(rel):
    """Is this file committed to git?

    A test file git does not track is one the current session just wrote. It
    is not part of the owner's suite, nobody has reviewed it, and the
    pre-commit hook already lets new test files through (it refuses only
    modify, delete and rename). Locking it would only stop an agent from
    fixing a test it is halfway through writing, which protects nothing. The
    moment it is committed it is locked like every other test.
    """
    try:
        r = subprocess.run(["git", "ls-files", "--error-unmatch", "--", rel],
                           cwd=root, capture_output=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return True  # fail closed: if git cannot answer, treat it as protected


if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    path = inp.get("file_path") or inp.get("notebook_path") or ""
    if is_test(path):
        full = path if os.path.isabs(path) else os.path.join(root, path)
        rel = os.path.relpath(full, root)
        if os.path.exists(full) and tracked(rel):
            deny(f"{tool} on a committed test file ({rel}) is blocked. " + RULE)
    sys.exit(0)

if tool == "Bash":
    cmd = inp.get("command", "") or ""
    mentions_test = re.search(r"(^|[\s'\"=:(])\.?/?(test|tests)/\S*|\S+_test\.exs", cmd) is not None
    if not mentions_test:
        sys.exit(0)
    mutating = re.compile(
        r"(^|[\s;&|(])(rm|mv|cp|tee|truncate|unlink|shred|install)\s"
        r"|\bsed\s+(-[a-zA-Z]*i|--in-place)"
        r"|\bperl\s+-[a-zA-Z]*i"
        r"|\bgit\s+(rm|mv|restore|checkout|clean|stash)\b"
        r"|(^|[^<])>\s*\.?/?(test|tests)/"
        r"|(^|[\s;&|(])(python3?|perl|ruby|node|elixir|iex|awk|ed|ex|vim?|nano|patch)\s"
        r"|\bmix\s+(format|run)\b"
    )
    if mutating.search(cmd):
        deny("This shell command could delete or rewrite a test file. " + RULE)
    sys.exit(0)

sys.exit(0)
