# /// script
# dependencies = [
#   "brotli",
# ]
# ///

import sys
import base64
import json
import subprocess
from pathlib import Path

def pad(s: str) -> str:
    rem = len(s) % 4
    return s + "=" * (4 - rem) if rem else s

def decode_token(raw_token: str) -> dict:
    raw_token = raw_token.strip()
    if raw_token.startswith("fptnb:"):
        raw_token = raw_token[len("fptnb:"):]
    elif raw_token.startswith("fptnb://"):
        raw_token = raw_token[len("fptnb://"):]
    
    raw_token = "".join(raw_token.split())
    raw_token = raw_token.replace("`", "").rstrip("=")
    
    # Base64 decode
    decoded = base64.b64decode(pad(raw_token))
    
    # Brotli decompress
    import brotli
    decompressed = brotli.decompress(decoded)
    
    return json.loads(decompressed.decode("utf-8"))

def main():
    if len(sys.argv) < 2:
        print("Usage: uv run tools/run_diag.py <fptnb_token> [server_name_filter]")
        sys.exit(1)
        
    token = sys.argv[1]
    name_filter = sys.argv[2].lower() if len(sys.argv) > 2 else None
    
    try:
        data = decode_token(token)
    except Exception as e:
        print(f"Failed to decode token: {e}")
        sys.exit(1)
        
    username = data.get("username", "")
    password = data.get("password", "")
    servers = data.get("servers", [])
    
    if name_filter:
        servers = [s for s in servers if name_filter in s.get("name", "").lower()]
        
    print(f"Decoded token for user: {username}")
    print(f"Loaded {len(servers)} servers from token.")
    
    # Default SNI and censorship strategy from settings
    strategy = "sni-reality-chrome147"
    sni = "music.yandex.ru"
    
    # Write temp config file to tools directory
    tools_dir = Path(__file__).parent.resolve()
    config_path = tools_dir / "temp_config.txt"
    with open(config_path, "w") as f:
        f.write(f"{username}\n")
        f.write(f"{password}\n")
        f.write(f"{strategy}\n")
        f.write(f"{sni}\n")
        for s in servers:
            name = s.get("name", "")
            host = s.get("host", "")
            port = s.get("port", 443)
            fp = s.get("md5_fingerprint", "")
            f.write(f"{name}|{host}|{port}|{fp}\n")
            
    # Compile C++ diagnostics tool
    cpp_source = tools_dir / "fptn_diag.cpp"
    binary_path = tools_dir / "fptn_diag"
    
    print("Compiling C++ diagnostics tool...")
    compile_cmd = [
        "clang++", "-std=c++20", str(cpp_source),
        "-F", "Fptn-macOS/Cpp", "-framework", "fptn_native_lib",
        "-I", "Fptn-macOS/Cpp/fptn_native_lib.framework/Headers",
        "-rpath", "Fptn-macOS/Cpp",
        "-o", str(binary_path)
    ]
    
    # Run compiler from repository root to resolve framework path properly
    repo_root = tools_dir.parent
    res = subprocess.run(compile_cmd, cwd=repo_root, capture_output=True, text=True)
    if res.returncode != 0:
        print("Compilation failed:")
        print(res.stderr)
        sys.exit(1)
        
    print("Compilation successful. Running diagnostics...")
    print("==================================================")
    
    # Run the diagnostics binary
    run_cmd = [str(binary_path), str(config_path)]
    subprocess.run(run_cmd, cwd=repo_root)

if __name__ == "__main__":
    main()
