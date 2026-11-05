"""Ranked end-to-end test: a local backend and two copies of the game that find each other
through the queue, connect, fight, and get the rating result back.

    python tools/test_ranked.py --backend C:/path/to/PokeBrawl-Backend/server.py [--scenario accept|decline] [--show]

  accept  (default)  the loser asks for a rematch, the winner accepts, a second ranked battle
                     is played; both then leave to the Ranked screen. Both matches must count.
  decline            the winner declines: both must end on the Ranked screen, the loser with
                     "declined" on it, and only one match counts.
  --show             the first copy gets a window (screenshots go to captures/net_*.png)

Godot: the GODOT environment variable (the same one play.bat uses) or "godot" on PATH.
Each copy keeps its own account file (--ranked_account).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.join(os.path.dirname(HERE), "game")
PORT = 18081
BASE = "http://127.0.0.1:%d" % PORT


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True, help="path to the backend's server.py")
    ap.add_argument("--timeout", type=int, default=290)
    ap.add_argument("--scenario", default="accept", choices=["accept", "decline"])
    ap.add_argument("--show", action="store_true")
    args = ap.parse_args()
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    env = dict(os.environ, POKEBRAWL_PORT=str(PORT), POKEBRAWL_DB=os.path.join(tmp, "r.db"), POKEBRAWL_GRACE="5", POKEBRAWL_LOG="")
    server_log = open(os.path.join(tmp, "server.log"), "w")
    server = subprocess.Popen([sys.executable, "-u", args.backend], env=env, stdout=server_log, stderr=subprocess.STDOUT)
    procs = []
    try:
        for _ in range(50):
            try:
                get("/health")
                break
            except Exception:
                time.sleep(0.1)
        for i, acc in enumerate(("a", "b")):
            cmd = [godot]
            if not (args.show and i == 0):
                cmd.append("--headless")
            cmd += ["--path", GAME, "--", "--test=menu_net", "--ranked", "--bot", "--scenario=" + args.scenario,
                    "--ranked_server=" + BASE, "--ranked_account=" + acc + str(os.getpid())]
            logf = open(os.path.join(tmp, "copy_%s.log" % acc), "w", encoding="utf-8")
            procs.append(subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, text=True))
        finals = []
        deadline = time.time() + args.timeout
        while time.time() < deadline and any(p.poll() is None for p in procs):
            time.sleep(0.5)
        for p in procs:
            if p.poll() is None:
                p.kill()
        outs = []
        for acc in ("a", "b"):
            with open(os.path.join(tmp, "copy_%s.log" % acc), encoding="utf-8", errors="replace") as f:
                out = f.read()
            outs.append(out)
            for line in out.splitlines():
                if line.startswith("MENU_NET_FINAL "):
                    finals.append(json.loads(line[len("MENU_NET_FINAL "):]))
        ok = True

        def check(cond, what):
            nonlocal ok
            print(("ok   " if cond else "FAIL ") + what)
            ok = ok and cond

        check(len(finals) == 2, "both copies finished (%d)" % len(finals))
        if len(finals) == 2:
            for f in finals:
                check(f["result"] == "ok", "%s: %s" % (f["role"], f["result"]))
            check({f["role"] for f in finals} == {"host", "guest"}, "the backend made one host and one guest")
            check(all(f["screen"] == "ranked" for f in finals), "both end on the Ranked screen")
            board = get("/leaderboard")["players"]
            games = sorted(p["wins"] + p["losses"] for p in board)
            if args.scenario == "accept":
                check(all(f["played"] == 2 for f in finals), "both played two battles")
                check(games == [2, 2], "the rematch counted as a second ranked match: %s" % board)
            else:
                check(all(f["played"] == 1 for f in finals), "only one battle was played")
                check(games == [1, 1], "only one match counted: %s" % board)
                loser = [f for f in finals if not f["ranked"].get("won", True)]
                check(len(loser) == 1 and "declined" in loser[0]["notice"].lower(),
                      "the one who asked sees that it was declined: %s" % [f["notice"] for f in finals])
        if not ok:
            for i, out in enumerate(outs):
                lines = [ln for ln in out.splitlines() if '"status": "waiting"' not in ln]
                print("\n---- copy %d ----\n%s" % (i, "\n".join(lines)[-4000:]))
            server_log.flush()
            print("\n---- backend ----\n" + open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read()[-3000:])
        sys.exit(0 if ok else 1)
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
        server.terminate()


if __name__ == "__main__":
    main()
