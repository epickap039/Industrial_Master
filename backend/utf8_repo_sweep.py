from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = frozenset({".git", ".dart_tool", "build", "node_modules", "__pycache__", "venv", ".venv"})
EXTS = frozenset({
    ".py", ".dart", ".yaml", ".yml", ".json", ".md", ".mdc", ".toml", ".sql",
    ".xml", ".gradle", ".properties", ".bat", ".ps1", ".sh", ".html", ".css",
    ".js", ".ts", ".tsx", ".jsx", ".cmake", ".txt", ".csv",
})

def utf16_le_bytes_to_str(raw: bytes) -> str:
    if raw.startswith(b"\xff\xfe"):
        return raw[2:].decode("utf-16-le")
    if raw.startswith(b"\xfe\xff"):
        return raw[2:].decode("utf-16-be")
    return raw.decode("utf-16-le")

def main() -> int:
    fixed = []
    skipped = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in EXTS:
            continue
        if SKIP_DIRS.intersection(p.parts):
            continue
        raw = p.read_bytes()
        if not raw or raw.count(0) == 0:
            continue
        try:
            s = utf16_le_bytes_to_str(raw)
        except UnicodeError as e:
            skipped.append((p, str(e)))
            continue
        ctrl = sum(1 for c in s[:800] if ord(c) < 32 and c not in "\n\r\t")
        if ctrl > 8:
            skipped.append((p, "too_many_control_chars"))
            continue
        text = s.replace("\r\n", "\n").replace("\r", "\n")
        p.write_bytes(text.encode("utf-8"))
        fixed.append(p)
    for p in sorted(fixed, key=lambda x: str(x)):
        nul = p.read_bytes().count(0)
        print("OK nul=%d\t%s" % (nul, p.relative_to(ROOT)))
    print("--- fixed %d skipped %d" % (len(fixed), len(skipped)))
    for p, err in skipped:
        print("SKIP %s: %s" % (p.relative_to(ROOT), err))
    return 0

if __name__ == "__main__":
    sys.exit(main())