import json, re, sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "src/Vectron.sol"
MAP = sys.argv[2] if len(sys.argv) > 2 else "error_map.json"

text = open(SRC, encoding="utf-8", newline="").read()
nl = "\r\n" if "\r\n" in text else "\n"


def skip_string(s, i):
    q = s[i]
    i += 1
    while s[i] != q:
        i += 2 if s[i] == "\\" else 1
    return i + 1


def masked(s):
    """Same-length copy with comments blanked out, so we never match require( inside a comment."""
    out, i, n = list(s), 0, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            i = skip_string(s, i)
        elif s.startswith("//", i):
            j = s.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif s.startswith("/*", i):
            j = s.find("*/", i) + 2
            for k in range(i, j):
                if out[k] not in "\r\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


m = masked(text)
names, used, edits, warnings = {}, set(), [], []


def make_name(msg):
    if msg in names:
        return names[msg]
    words = re.findall(r"[A-Za-z0-9]+", msg)
    base = "".join(w[:1].upper() + w[1:] for w in words)[:48] or "Failed"
    if base[0].isdigit():
        base = "E" + base
    name, k = base, 2
    while name in used or re.search(r"\b" + re.escape(name) + r"\b", text):
        name = base + ("Err" if k == 2 else "Err%d" % k)
        k += 1
    used.add(name)
    names[msg] = name
    return name


for hit in re.finditer(r"\brequire\s*\(", m):
    start = hit.start()
    i = hit.end()
    depth, last_comma = 1, None
    while depth:
        c = text[i]
        if c in "\"'":
            i = skip_string(text, i)
            continue
        if m[i] in "([{":
            depth += 1
        elif m[i] in ")]}":
            depth -= 1
        elif m[i] == "," and depth == 1:
            last_comma = i
        i += 1
    end = i  # index just after the closing paren
    if last_comma is None:
        continue
    arg = text[last_comma + 1 : end - 1].strip()
    if not (arg.startswith('"') and arg.endswith('"') and arg.count('"') == 2):
        warnings.append("skipped non-simple message near offset %d" % start)
        continue
    before = text[:start].rstrip()
    if before.endswith(")") or before.endswith("else"):
        warnings.append("require directly after if/else near line %d" % (text[:start].count("\n") + 1))
    cond = re.sub(r"\s+", " ", text[hit.end() : last_comma]).strip()
    name = make_name(arg[1:-1])
    edits.append((start, end, "if (!(%s)) revert %s()" % (cond, name)))

for start, end, rep in reversed(edits):
    text = text[:start] + rep + text[end:]

block = nl.join("error %s();" % n for n in sorted(used)) + nl + nl
pragma = re.search(r"^pragma solidity[^\n]*\n", text, re.M)
pos = pragma.end()
text = text[:pos] + nl + block + text[pos:].lstrip("\r\n")

open(SRC, "w", encoding="utf-8", newline="").write(text)
json.dump(names, open(MAP, "w"), indent=1)
print("converted", len(edits), "requires into", len(used), "custom errors")
for w in warnings:
    print("WARNING:", w)
