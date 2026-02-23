#!/usr/bin/env python3
"""
token_debug.py — FPTN token format analyser

Usage:
    python3 token_debug.py token_working.txt token_new.txt
    python3 token_debug.py <any .txt file>

Install deps (once, in a venv):
    python3 -m venv .venv && .venv/bin/pip install brotli
    .venv/bin/python3 token_debug.py ...
"""

import sys
import base64
import json
import binascii
import hashlib
import struct
from pathlib import Path

try:
    import brotli
    BROTLI_AVAILABLE = True
except ImportError:
    BROTLI_AVAILABLE = False


# ── helpers ──────────────────────────────────────────────────────────────────

def pad(s: str) -> str:
    """Add standard base64 padding."""
    rem = len(s) % 4
    return s + "=" * (4 - rem) if rem else s


def sanitize(raw: str) -> tuple[str, str]:
    """Strip known FPTN prefixes and whitespace; return (prefix, cleaned_b64)."""
    raw = raw.strip()
    prefix = ""
    for p in ("fptnb://", "fptnb:", "fptn://", "fptn:"):
        if raw.startswith(p):
            prefix = p.rstrip(":/")
            raw = raw[len(p):]
            break
    # strip whitespace, backticks, existing padding (mirror C++ RemoveSubstring)
    raw = "".join(raw.split())
    raw = raw.replace("`", "").rstrip("=")
    return prefix, raw


def try_decode_b64(b64: str) -> bytes | None:
    """Attempt standard → URL-safe base64 decode."""
    for variant in [b64, b64.replace("-", "+").replace("_", "/")]:
        try:
            return base64.b64decode(pad(variant))
        except Exception:
            pass
    return None


def hexdump(data: bytes, width: int = 16) -> str:
    lines = []
    for i in range(0, len(data), width):
        chunk = data[i : i + width]
        hex_part = " ".join(f"{b:02x}" for b in chunk)
        asc_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append(f"  {i:04x}  {hex_part:<{width*3}}  {asc_part}")
    return "\n".join(lines)


def print_section(title: str) -> None:
    print(f"\n{'─'*60}")
    print(f"  {title}")
    print(f"{'─'*60}")


def analyse_servers(servers: list, label: str = "servers") -> None:
    print(f"\n  [{label}]  ({len(servers)} entries)")
    for s in servers:
        name = s.get("name", "?")
        host = s.get("host", "?")
        port = s.get("port", "?")
        fp   = s.get("md5_fingerprint", "")
        fp_display = fp if fp else "(empty)"
        print(f"    {name:<30}  {host}:{port}  md5={fp_display}")


def analyse_json_token(data: bytes) -> None:
    try:
        obj = json.loads(data.decode("utf-8"))
    except Exception as e:
        print(f"  ✗ JSON parse failed: {e}")
        return

    print(f"  ✓ Valid JSON  ({len(data)} bytes decoded)")
    print()
    print(f"  version      : {obj.get('version', '(missing)')}")
    print(f"  service_name : {obj.get('service_name', '(missing)')}")
    print(f"  username     : {obj.get('username', '(missing)')}")
    password = obj.get('password', '(missing)')
    print(f"  password     : {password[:4]}{'*'*(len(password)-4) if len(password)>4 else ''}")

    servers = obj.get("servers", [])
    analyse_servers(servers, "servers")

    cz = obj.get("censored_zone_servers", [])
    if cz:
        analyse_servers(cz, "censored_zone_servers")

    extra = [k for k in obj if k not in
             ("version", "service_name", "username", "password",
              "servers", "censored_zone_servers")]
    if extra:
        print(f"\n  ⚠  Unknown top-level fields (new format?): {extra}")
        for k in extra:
            print(f"     {k} = {json.dumps(obj[k])[:120]}")

    # iOS compatibility check
    print()
    if not servers:
        print("  ✗ iOS: no servers — FPTNToken decode would fail (empty list)")
    else:
        missing_fp = [s.get("name") for s in servers
                      if not s.get("md5_fingerprint")]
        if missing_fp:
            print(f"  ⚠  iOS: {len(missing_fp)} server(s) have empty md5_fingerprint:")
            for n in missing_fp:
                print(f"       {n}")
        else:
            print("  ✓ iOS: all servers have md5_fingerprint")


def analyse_brotli_token(data: bytes) -> None:
    """Decompress a Brotli payload and analyse the resulting JSON."""
    if not BROTLI_AVAILABLE:
        print("  ✗ 'brotli' module not available — install it:")
        print("    python3 -m venv .venv && .venv/bin/pip install brotli")
        print("    .venv/bin/python3 token_debug.py ...")
        return

    try:
        decompressed = brotli.decompress(data)
    except Exception as e:
        print(f"  ✗ Brotli decompress failed: {e}")
        return

    print(f"  ✓ Brotli decompressed  {len(data)} → {len(decompressed)} bytes"
          f"  ({len(decompressed)/len(data):.1f}x expansion)")
    analyse_json_token(decompressed)


def analyse_file(path: Path) -> None:
    raw = path.read_text(encoding="utf-8").strip()
    print_section(f"FILE: {path.name}  ({len(raw)} chars)")

    print(f"  Raw preview  : {raw[:80]}{'...' if len(raw)>80 else ''}")

    prefix, b64 = sanitize(raw)
    print(f"  Detected prefix : '{prefix}' {'(NEW format — fptnb)' if 'fptnb' in prefix else '(legacy fptn)'}")
    print(f"  Cleaned b64 len : {len(b64)} chars")

    decoded = try_decode_b64(b64)
    if decoded is None:
        print(f"\n  ✗ base64 decode FAILED")
        print(f"    Non-base64 chars: "
              f"{set(c for c in b64 if c not in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=')}")
        return

    if "fptnb" in prefix:
        print_section(f"BROTLI-compressed payload  ({path.name})")
        analyse_brotli_token(decoded)
    else:
        print_section(f"JSON payload  ({path.name})")
        analyse_json_token(decoded)


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    files = sys.argv[1:] if len(sys.argv) > 1 else []
    if not files:
        # auto-discover token*.txt in cwd
        files = sorted(Path(".").glob("token*.txt"))
        if not files:
            print("Usage: python3 token_debug.py <token_file> [token_file2 ...]")
            sys.exit(1)

    for arg in files:
        p = Path(arg)
        if not p.exists():
            print(f"  ✗ File not found: {p}")
            continue
        try:
            analyse_file(p)
        except Exception as e:
            print(f"  ✗ Unexpected error analysing {p}: {e}")

    print(f"\n{'─'*60}\n")


if __name__ == "__main__":
    main()
