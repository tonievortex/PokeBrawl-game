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
    ap.add_argument("--scenario", default="accept", choices=["accept", "decline", "room"])
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--relay-only", action="store_true", help="forbid the direct path: the fight goes through the relay")
    ap.add_argument("--draft", action="store_true", help="a draft match (ban and pick; needs --arena)")
    ap.add_argument("--team", action="store_true", help="a 2 vs 2 through the ranked queue: four copies (needs --arena)")
    ap.add_argument("--arena", action="store_true", help="the SERVER runs the fight (needs GODOT): the rating follows its result")
    ap.add_argument("--lag", type=int, default=0, help="simulated round trip in ms (each copy)")
    ap.add_argument("--loss", type=int, default=0, help="simulated packet loss in percent")
    args = ap.parse_args()
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    accounts = ("a", "b", "c", "d") if args.team else ("a", "b")
    n = len(accounts)
    env = dict(os.environ, POKEBRAWL_REGISTER_LIMIT="100", POKEBRAWL_PORT=str(PORT), POKEBRAWL_DB=os.path.join(tmp, "r.db"), POKEBRAWL_GRACE="5", POKEBRAWL_LOG="", POKEBRAWL_LEADERBOARD_MIN="0")
    if args.arena:
        env.update(POKEBRAWL_ARENA_GODOT=godot, POKEBRAWL_ARENA_GAME=GAME, POKEBRAWL_ARENA_ARGS="--match_max=40")
    server_log = open(os.path.join(tmp, "server.log"), "w")
    server = subprocess.Popen([sys.executable, "-u", args.backend], env=env, stdout=server_log, stderr=subprocess.STDOUT)
    procs = []
    room_file = os.path.join(tmp, "room_code.txt")
    try:
        for _ in range(50):
            try:
                get("/health")
                break
            except Exception:
                time.sleep(0.1)
        for i, acc in enumerate(accounts):
            cmd = [godot]
            if not (args.show and i == 0):
                cmd.append("--headless")
            if args.scenario == "room":
                cmd_room = ["--room=" + ("create" if i == 0 else "join"), "--room_file=" + room_file]
            else:
                cmd_room = []
            cmd += ["--path", GAME, "--", "--test=menu_net", "--ranked", "--bot", "--scenario=" + args.scenario] + cmd_room + (["--no_direct"] if args.relay_only else []) + (["--draft"] if args.draft else []) + (["--team"] if args.team else []) + (["--lag=%d" % args.lag] if args.lag else []) + (["--loss=%d" % args.loss] if args.loss else []) + [
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
        for acc in accounts:
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

        check(len(finals) == n, "all %d copies finished (%d)" % (n, len(finals)))
        if len(finals) == n:
            for f in finals:
                check(f["result"] == "ok", "%s: %s" % (f["role"], f["result"]))
            check({f["role"] for f in finals} == ({"host", "guest", "host2", "guest2"} if args.team else {"host", "guest"}), "the backend gave each player a role: %s" % sorted(f["role"] for f in finals))
            check(all(f["screen"] == "ranked" for f in finals), "both end on the Ranked screen")
            want_path = "server" if args.arena else ("relay" if args.relay_only else "direct")
            check(all(f["path"] == want_path for f in finals), "the packets travelled %s (%s)" % (want_path, [f["path"] for f in finals]))
            print("     ping avg: %s ms, teleports: %s, own: %s (biggest %s m)" % ([f["ping_avg"] for f in finals], [f["jumps"] for f in finals], [f.get("own_jumps") for f in finals], [f.get("max_own_jump") for f in finals]))
            board = get("/leaderboard")["players"]
            games = sorted(p["wins"] + p["losses"] for p in board)
            if args.scenario == "room":
                check(all(f["played"] == 1 for f in finals), "one battle each")
                check(board == [], "a private room's match left the ranking untouched: %s" % board)
                check(all(bool(f["ranked"].get("friendly")) and f["ranked"].get("delta") == 0 for f in finals), "both saw it as friendly, rating change 0: %s" % [f["ranked"] for f in finals])
            elif args.arena:
                check(all(f["played"] == 1 for f in finals), "one battle each (the arena has no rematch)")
                if args.team:
                    check(all(f.get("team", {}).get("match") and f["team"].get("ok") and f["team"].get("ally") == 1 and f["team"].get("enemies") == 2 for f in finals),
                          "each saw a 2 vs 2 with one ally and two rivals, and the four fighters were built right: %s" % [f.get("team") for f in finals])
                if args.draft:
                    dr = [f.get("draft", {}) for f in finals]
                    check(all(x.get("match") and x.get("stage") == "done" for x in dr), "both went through the draft: %s" % [x.get("stage") for x in dr])
                    check(dr[0].get("bans") == dr[1].get("bans") and dr[0].get("picks") == dr[1].get("picks") and all(dr[0].get("picks")) and dr[0]["picks"][0] != dr[0]["picks"][1],
                          "both saw the same bans and two different picks: bans %s, picks %s" % (dr[0].get("bans"), dr[0].get("picks")))
                    check(not set(dr[0]["picks"]) & set(dr[0]["bans"]), "nobody got a banned Pokémon")
                check(all(f.get("report") == "sent" for f in finals), "each player reported someone from the result screen (F5, 1%s): %s" % (", 1" if args.team else "", [f.get("report") for f in finals]))
                check(all(f.get("replay", {}).get("listed", 0) >= 1 and f["replay"].get("started") and f["replay"].get("moved") for f in finals),
                      "each player found the match in My replays and watched it play (Pokémon moved): %s" % [f.get("replay") for f in finals])
                check(games == [1] * n, "the server's result counted once for each: %s" % board)
                won = sorted(bool(f["ranked"].get("won")) for f in finals)
                check(won == ([False, False, True, True] if args.team else [False, True]), "the winners and the losers: %s" % [f["ranked"] for f in finals])
                ratings = sorted(p["rating"] for p in board)
                if args.team:
                    check(ratings[0] < 1000 and ratings[1] < 1000 and ratings[2] > 1000 and ratings[3] > 1000, "the rating of both team-mates moved together: %s" % ratings)
                else:
                    check(ratings[0] < 1000 < ratings[1], "the rating moved both ways: %s" % ratings)
            elif args.scenario == "accept":
                check(all(f["played"] == 2 for f in finals), "both played two battles")
                check(games == [2, 2], "the rematch counted as a second ranked match: %s" % board)
            else:
                check(all(f["played"] == 1 for f in finals), "only one battle was played")
                check(games == [1, 1], "only one match counted: %s" % board)
                loser = [f for f in finals if not f["ranked"].get("won", True)]
                check(len(loser) == 1 and "declined" in loser[0]["notice"].lower(),
                      "the one who asked sees that it was declined: %s" % [f["notice"] for f in finals])
        server_log.flush()
        with open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace") as f:
            backend_out = f.read()
        if args.scenario == "room":
            check("opened room" in backend_out and "FRIENDLY" in backend_out and "private room" in backend_out, "the backend made the room, matched the friends and settled it as friendly")
        elif args.arena:
            check("(arena: the server runs the fight" in backend_out and "RESULT" in backend_out, "the backend's match server settled the match")
            check(backend_out.count("COMPLAINT") >= n, "the backend recorded all %d reports" % n)
        else:
            check("(through the relay)" in backend_out and "both players are connected through the relay" in backend_out,
                  "the fight went through the backend's relay (no port opened anywhere)")
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
