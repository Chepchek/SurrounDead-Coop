"""Crude Lua block-balance checker (no Lua interpreter on this machine).

Strips comments and strings, then tracks function/if/do ... end and
repeat ... until nesting, reporting the first line where it goes wrong.
"""
import re
import sys


def strip(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + m.end())
                j = n if j < 0 else j + len(close)
                out.append("\n" * src.count("\n", i, j))
                i = j
                continue
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            out.append('""' + "\n" * src.count("\n", i, j))
            i = j
            continue
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                if src[j] == "\n":
                    raise SyntaxError(f"unterminated string at line {src.count(chr(10), 0, i) + 1}")
                j += 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(path: str) -> bool:
    src = open(path, encoding="utf-8").read()
    try:
        code = strip(src)
    except SyntaxError as e:
        print(f"{path}: {e}")
        return False
    stack = []
    for lineno, line in enumerate(code.split("\n"), 1):
        for tok in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", line):
            if tok in ("function", "if", "do", "repeat"):
                # 'for'/'while' bodies are opened by their 'do'
                stack.append((tok, lineno))
            elif tok == "end":
                if not stack or stack[-1][0] == "repeat":
                    print(f"{path}:{lineno}: unexpected 'end'")
                    return False
                stack.pop()
            elif tok == "until":
                if not stack or stack[-1][0] != "repeat":
                    print(f"{path}:{lineno}: unexpected 'until'")
                    return False
                stack.pop()
        # parentheses / braces balance per statement are too context-heavy; skip
    if stack:
        print(f"{path}: unclosed {stack[-1][0]} opened at line {stack[-1][1]} ({len(stack)} open)")
        return False
    # global paren/brace balance
    for o, c in ("()", "{}", "[]"):
        if code.count(o) != code.count(c):
            print(f"{path}: unbalanced {o}{c}: {code.count(o)} vs {code.count(c)}")
            return False
    print(f"{path}: ok")
    return True


ok = all([check(p) for p in sys.argv[1:]])
sys.exit(0 if ok else 1)
