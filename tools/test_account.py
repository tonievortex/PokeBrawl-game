"""Account screen test: a local backend and one copy of the game that creates an account, logs out
and in again (see game/scripts/test_account.gd).

    python tools/test_account.py --backend C:/path/to/PokeBrawl-Backend/server.py [--show]

Godot: the GODOT environment variable or "godot" on PATH. --show opens a window and saves
screenshots to captures/account_*.png.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.join(os.path.dirname(HERE), "game")
PORT = 18083


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True)
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--lang", default="", help="the game's language for the screenshots (the checks read English)")
    args = ap.parse_args()
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    env = dict(os.environ, POKEBRAWL_PORT=str(PORT), POKEBRAWL_DB=os.path.join(tmp, "a.db"))
    log = open(os.path.join(tmp, "server.log"), "w")
    server = subprocess.Popen([sys.executable, "-u", args.backend], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/health" % PORT, timeout=2)
                break
            except Exception:
                time.sleep(0.1)
        cmd = [godot] + ([] if args.show else ["--headless"]) + ["--path", GAME, "--", "--test=menu_account",
                                                                  "--ranked_server=http://127.0.0.1:%d" % PORT] + (["--lang=" + args.lang] if args.lang else [])
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120, encoding="utf-8", errors="replace").stdout
        lines = [ln for ln in out.splitlines() if ln.startswith(("OK ", "FAIL ", "ACCOUNT_DONE"))]
        print("\n".join(lines))
        ok = any(ln.startswith("ACCOUNT_DONE ok") for ln in lines) and not any(ln.startswith("FAIL") for ln in lines)
        print("\n%s" % ("ALL OK" if ok else "FAILED"))
        if not ok:
            print(out[-3000:])
            log.flush()
            print(open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read()[-1500:])
        sys.exit(0 if ok else 1)
    finally:
        server.terminate()


if __name__ == "__main__":
    main()

