"""Tests the match server (the headless referee) with two scripted players.

    python tools/test_match_server.py [fight|forfeit|leave|cheat|draft|draft_timeout|team|team_leave]

Python plays both players: it sends the inputs a real game would (60 per second, with the last
three in each packet) and reads the server's snapshots and events. Checks, per scenario:
  fight    both pick, the server counts down and runs the fight, hits and a result arrive, the
           snapshots come at ~30 per second and the inputs are applied; CPU and memory are measured
  forfeit  one player goes silent: the other one wins by forfeit
  leave    one player sends "leave" during the fight: the other one wins
  cheat    one player sends impossible inputs (huge, NaN, jumping counters): nothing moves
           beyond what a keyboard can do, and the match goes on normally
  draft    a draft match: both ban one Pokémon, then pick one after the other; bad bans and picks
           are ignored; only the picked Pokémon can be played
  team     a 2 vs 2 (four players: slots 0 and 2 against 1 and 3): four Pokémon in every snapshot,
           a team wins when both of the other team's Pokémon are out
  team_leave  in a 2 vs 2 one player leaves: only their Pokémon is out, the others fight on
  team_draft  a 2 vs 2 with a draft: four bans (hidden), the picks in the order team A, B, B, A, then the match
draft_timeout  nobody does anything in the draft: random bans and picks fill in, the match starts

Godot: the GODOT environment variable or "godot" on PATH.
"""
import json
import math
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.join(os.path.dirname(HERE), "game")
PORT = 17901
ACTIONS = ["jump", "dodge", "lock_on", "mov1", "mov2", "mov3", "mov4", "descend"]
REC = 113          # bytes of one Pokémon in a snapshot (Net.write_fighter)


class Client:
    """One scripted player."""

    def __init__(self, slot):
        self.slot = slot
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.setblocking(False)
        self.frame = 0
        self.hist = []
        self.counters = [0] * 8
        self.last_event = 0
        self.seen = set()
        self.events = []
        self.snapshots = 0
        self.phase = 0
        self.fighters = []
        self.applied = 0
        self.first_snapshot_at = None
        self.last_snapshot_at = None

    def send(self, kind, payload=b""):
        self.sock.sendto(bytes([self.slot, kind]) + payload, ("127.0.0.1", PORT))

    def msg(self, data):
        self.send(0x11, json.dumps(data).encode())

    def input(self, mx=0.0, my=0.0, yaw=0.0, presses=(), counters_jump=None):
        self.frame += 1
        for p in presses:
            self.counters[ACTIONS.index(p)] = (self.counters[ACTIONS.index(p)] + 1) % 256
        if counters_jump is not None:
            self.counters = [(c + counters_jump) % 256 for c in self.counters]
        rec = struct.pack("<IfffH8B", self.frame, mx, my, yaw, 0, *self.counters)
        self.hist = (self.hist + [rec])[-3:]
        self.send(0x12, struct.pack("<HB", self.last_event, len(self.hist)) + b"".join(self.hist))

    def poll(self):
        while True:
            try:
                data = self.sock.recvfrom(4096)[0]
            except (BlockingIOError, ConnectionResetError):
                return
            if len(data) < 12 or data[1] != 0x80:
                continue
            now = time.perf_counter()
            self.first_snapshot_at = self.first_snapshot_at or now
            self.last_snapshot_at = now
            self.snapshots += 1
            _, self.applied = struct.unpack_from("<II", data, 2)
            self.phase = data[10]
            n = data[11]
            off = 12
            self.fighters = []
            for _ in range(n):
                rec = data[off:off + REC]
                off += REC
                pos = struct.unpack_from("<fff", rec, 22)
                hp, energy = struct.unpack_from("<ff", rec, 61)
                self.fighters.append({"pos": pos, "hp": hp, "energy": energy, "state": rec[50]})
            count = data[off]
            off += 1
            for _ in range(count):
                eid, ln = struct.unpack_from("<HH", data, off)
                off += 4
                body = json.loads(data[off:off + ln])
                off += ln
                self.last_event = max(self.last_event, eid)
                if eid not in self.seen:
                    self.seen.add(eid)
                    self.events.append(body)

    def events_of(self, kind):
        return [e for e in self.events if e.get("t") == kind]


def sample_process():
    """Total CPU seconds and working set (MB) of the Godot processes (Windows)."""
    cmd = ("$g = Get-Process | Where-Object { $_.Name -like 'Godot*' }; "
           "$cpu = ($g | ForEach-Object { $_.TotalProcessorTime.TotalSeconds } | Measure-Object -Sum).Sum; "
           "$mb = ($g | Measure-Object WorkingSet64 -Sum).Sum / 1MB; \"$cpu $mb\"")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", cmd], capture_output=True, text=True, timeout=20).stdout.split()
        return float(out[0].replace(",", ".")), float(out[1].replace(",", "."))
    except Exception:
        return None


def bot(client, enemy_slot, frame_in_fight):
    me = client.fighters[client.slot]["pos"] if len(client.fighters) > max(client.slot, enemy_slot) else (0, 0, 0)
    en = client.fighters[enemy_slot]["pos"] if len(client.fighters) > max(client.slot, enemy_slot) else (0, 0, 0)
    dx, dz = en[0] - me[0], en[2] - me[2]
    d = math.hypot(dx, dz) or 1.0
    mx, my = (dx / d, -dz / d) if d > 4.0 else (0.0, 0.0)
    presses = []
    if frame_in_fight == 1:
        presses.append("lock_on")
    if frame_in_fight % 36 == 0:
        presses.append("mov1")
    if frame_in_fight % 67 == 0:
        presses.append("mov2")
    if frame_in_fight % 150 == 0:
        presses.append("dodge")
    client.input(mx, my, 0.0, presses)


def team_main(scenario):
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    result_file = os.path.join(tmp, "result.json")
    log = open(os.path.join(tmp, "server.log"), "w", encoding="utf-8")
    proc = subprocess.Popen([godot, "--headless", "--path", GAME, "--", "--server", "--port=%d" % PORT, "--match=t4", "--players=4",
                             "--result=" + result_file, "--match_max=45"], stdout=log, stderr=subprocess.STDOUT)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    species = ["charizard", "lucario", "pikachu", "snorlax"]
    try:
        t0 = time.time()
        while time.time() - t0 < 90:
            log.flush()
            if "MATCH_SERVER ready" in open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read():
                break
            time.sleep(0.5)
        c = [Client(i) for i in range(4)]
        for i, cl in enumerate(c):
            cl.msg({"t": "choice", "species": species[i], "ready": True})
        fight_frame = 0
        left_sent = False
        left_at = None
        result = None
        next_tick = time.perf_counter()
        deadline = time.time() + 120
        while time.time() < deadline:
            for cl in c:
                cl.poll()
            in_fight = c[0].phase == 2
            if in_fight:
                fight_frame += 1
            for i, cl in enumerate(c):
                if i == 3 and left_sent:
                    continue
                if in_fight and fight_frame > 120:
                    bot(cl, i ^ 1, fight_frame - 120)
                else:
                    cl.input()
            if scenario == "team_leave" and in_fight and fight_frame > 600 and not left_sent:
                c[3].msg({"t": "leave"})
                left_sent = True
                left_at = time.time()
            res = c[0].events_of("result")
            if res:
                result = res[0]
                break
            if scenario == "team_leave" and left_at and time.time() - left_at > 4.0:
                break
            next_tick += 1.0 / 60.0
            time.sleep(max(0.0, next_tick - time.perf_counter()))
        for _ in range(60):
            for cl in c:
                cl.poll()
            time.sleep(1 / 60)
        starts = [e for e in c[0].events if e.get("t") == "start"]
        check(bool(starts) and [x["species"] for x in starts[0]["slots"]] == species, "all four got the start with their four Pokémon")
        check(all(len(cl.fighters) == 4 for cl in c), "every snapshot carries four Pokémon")
        check(len(c[0].events_of("hit")) > 0, "hits are decided by the server (%d hit events)" % len(c[0].events_of("hit")))
        if scenario == "team":
            check(result is not None and result.get("winner") in (0, 1) and result.get("reason") in ("ko", "time"), "a team won: %s" % result)
            if result and result.get("reason") == "ko":
                win = result["winner"]
                check(all(result["hp"][s] <= 0 for s in range(4) if s % 2 != win), "it won by putting both of the other team's Pokémon out: hp %s" % result["hp"])
            check(os.path.exists(result_file) and json.load(open(result_file)).get("players") == 4, "the backend gets the result with players = 4")
        else:
            check(left_sent and result is None, "one player left: the match goes on with the other three (no result yet)")
            fighters = c[0].fighters
            check(len(fighters) == 4 and fighters[3]["hp"] <= 0, "only the Pokémon of the one who left is out (hp %s)" % (fighters[3]["hp"] if len(fighters) == 4 else None))
            check(sum(1 for i in range(3) if fighters[i]["hp"] > 0) >= 2 or result is not None, "the others are still standing (at least two of the three: the bots also fight each other)")
    finally:
        proc.kill()
        subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Process | Where-Object { $_.Name -like 'Godot*' } | Stop-Process -Force"], capture_output=True)
    print("\n%s" % ("ALL OK" if ok else "FAILED"))
    if not ok:
        print(open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read()[-2000:])
    sys.exit(0 if ok else 1)


def draft_main(scenario):
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    log = open(os.path.join(tmp, "server.log"), "w", encoding="utf-8")
    args = ["--draft=1"] + (["--draft_time=2"] if scenario == "draft_timeout" else [])
    proc = subprocess.Popen([godot, "--headless", "--path", GAME, "--", "--server", "--port=%d" % PORT, "--match=d1",
                             "--match_max=20"] + args, stdout=log, stderr=subprocess.STDOUT)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    def last(c):
        e = c.events_of("draft")
        return e[-1] if e else {}

    def spin(clients, seconds, cond=None):
        end = time.time() + seconds
        while time.time() < end:
            for cl in clients:
                cl.poll()
                cl.input()
            if cond and cond():
                return True
            time.sleep(1 / 60)
        return bool(cond and cond())

    try:
        t0 = time.time()
        while time.time() - t0 < 90:
            log.flush()
            if "MATCH_SERVER ready" in open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read():
                break
            time.sleep(0.5)
        c = [Client(0), Client(1)]
        spin(c, 0.3)
        spin(c, 3.0, lambda: last(c[0]).get("stage") == "ban")
        st = last(c[0])
        check(st.get("stage") == "ban" and st.get("bans") == [None, None], "the draft opens with the ban stage, bans hidden: %s" % st.get("stage"))
        if scenario == "draft":
            c[0].msg({"t": "ban", "species": "notapokemon"})
            spin(c, 0.5)
            check(last(c[0]).get("ban_done") == [False, False], "a ban of something that is not a Pokémon is ignored")
            c[0].msg({"t": "pick", "species": "charizard"})
            spin(c, 0.5)
            check(last(c[0]).get("stage") == "ban", "a pick during the ban stage is ignored")
            c[0].msg({"t": "ban", "species": "pikachu"})
            spin(c, 0.5)
            st = last(c[0])
            check(st.get("ban_done") == [True, False] and st.get("bans") == [None, None], "one ban in: the other player's is still hidden (%s)" % st.get("ban_done"))
            c[0].msg({"t": "ban", "species": "gengar"})
            spin(c, 0.5)
            check(last(c[0]).get("stage") == "ban", "a second ban from the same player changes nothing")
            c[1].msg({"t": "ban", "species": "snorlax"})
            spin(c, 3.0, lambda: last(c[0]).get("stage") == "pick")
            st = last(c[0])
            check(st.get("stage") == "pick" and st.get("bans") == ["pikachu", "snorlax"], "both banned: the bans are shown and the picks begin: %s" % st.get("bans"))
            first = st.get("turn")
            second = 1 - first
            c[second].msg({"t": "pick", "species": "charizard"})
            spin(c, 0.5)
            check(last(c[0]).get("picks") == [None, None], "picking out of turn is ignored")
            c[first].msg({"t": "pick", "species": "pikachu"})
            spin(c, 0.5)
            check(last(c[0]).get("picks") == [None, None], "picking a banned Pokémon is ignored")
            c[first].msg({"t": "pick", "species": "charizard"})
            spin(c, 0.8)
            st = last(c[0])
            check(st.get("picks")[first] == "charizard" and st.get("turn") == second, "the first pick is in and the turn passes")
            c[second].msg({"t": "pick", "species": "charizard"})
            spin(c, 0.5)
            check(last(c[0]).get("picks")[second] is None, "the other cannot take the same Pokémon")
            c[second].msg({"t": "pick", "species": "lucario"})
            spin(c, 3.0, lambda: last(c[0]).get("stage") == "done")
            check(last(c[0]).get("stage") == "done" and last(c[0]).get("picks")[second] == "lucario", "both picked: the draft is done")
        else:
            spin(c, 12.0, lambda: last(c[0]).get("stage") == "done")
            st = last(c[0])
            check(st.get("stage") == "done" and all(st.get("picks")) and all(st.get("bans")), "nobody acted: random bans and picks filled the draft in time: bans %s, picks %s" % (st.get("bans"), st.get("picks")))
            check(st["picks"][0] != st["picks"][1] and not set(st["picks"]) & set(st["bans"]), "the picks differ and are not banned")
        st = last(c[0])
        picks = st["picks"]
        other_species = [sp for sp in ("charizard", "lucario", "pikachu", "snorlax", "gengar") if sp not in picks][0]
        c[0].msg({"t": "choice", "species": other_species, "ready": True})
        c[1].msg({"t": "choice", "species": picks[1], "ready": True})
        spin(c, 1.5)
        check(not any(e.get("t") == "start" for e in c[0].events), "a Pokémon that was not picked cannot be played (no start)")
        c[0].msg({"t": "choice", "species": picks[0], "ready": True})
        spin(c, 4.0, lambda: any(e.get("t") == "start" for e in c[0].events))
        start = [e for e in c[0].events if e.get("t") == "start"]
        check(bool(start) and [x["species"] for x in start[0]["slots"]] == picks, "with the picked ones the match starts: %s" % ([x["species"] for x in start[0]["slots"]] if start else None))
    finally:
        proc.kill()
        subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Process | Where-Object { $_.Name -like 'Godot*' } | Stop-Process -Force"], capture_output=True)
    print("\n%s" % ("ALL OK" if ok else "FAILED"))
    if not ok:
        print(open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read()[-2000:])
    sys.exit(0 if ok else 1)


def team_draft_main():
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    log = open(os.path.join(tmp, "server.log"), "w", encoding="utf-8")
    proc = subprocess.Popen([godot, "--headless", "--path", GAME, "--", "--server", "--port=%d" % PORT, "--match=d4", "--players=4",
                             "--draft=1", "--draft_time=8", "--match_max=20"], stdout=log, stderr=subprocess.STDOUT)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    def last(c):
        e = c.events_of("draft")
        return e[-1] if e else {}

    def spin(clients, seconds, cond=None):
        end = time.time() + seconds
        while time.time() < end:
            for cl in clients:
                cl.poll()
                cl.input()
            if cond and cond():
                return True
            time.sleep(1 / 60)
        return bool(cond and cond())

    try:
        t0 = time.time()
        while time.time() - t0 < 90:
            log.flush()
            if "MATCH_SERVER ready" in open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read():
                break
            time.sleep(0.5)
        c = [Client(i) for i in range(4)]
        spin(c, 3.0, lambda: last(c[0]).get("stage") == "ban")
        st = last(c[0])
        check(st.get("stage") == "ban" and st.get("bans") == [None] * 4 and st.get("ban_done") == [False] * 4, "the draft opens with the ban stage for four, bans hidden: %s" % st.get("ban_done"))
        for i, sp in enumerate(["pikachu", "snorlax", "gengar", "garchomp"]):
            c[i].msg({"t": "ban", "species": sp})
            spin(c, 0.4)
            if i < 3:
                check(last(c[0]).get("stage") == "ban" and last(c[0]).get("bans") == [None] * 4, "ban %d in: the bans are still hidden" % (i + 1))
        spin(c, 3.0, lambda: last(c[0]).get("stage") == "pick")
        st = last(c[0])
        check(st.get("stage") == "pick" and st.get("bans") == ["pikachu", "snorlax", "gengar", "garchomp"], "all four banned: the bans are shown and the picks begin: %s" % st.get("bans"))
        free = [sp for sp in ("charizard", "lucario", "blastoise", "venusaur", "greninja", "scizor")]
        turns = []
        for n in range(4):
            st = last(c[0])
            turn = st.get("turn")
            turns.append(turn)
            wrong = (turn + 1) % 4
            c[wrong].msg({"t": "pick", "species": free[n]})
            spin(c, 0.3)
            check(last(c[0]).get("picks")[wrong] is None, "pick %d: out of turn is ignored" % (n + 1)) if n == 0 else None
            c[turn].msg({"t": "pick", "species": free[n]})
            spin(c, 0.6)
        first = turns[0] % 2
        check(turns == [first, 1 - first, 1 - first + 2, first + 2], "the picks go team A, team B, team B, team A: %s" % turns)
        spin(c, 3.0, lambda: last(c[0]).get("stage") == "done")
        st = last(c[0])
        check(st.get("stage") == "done" and all(st.get("picks")) and len(set(st["picks"])) == 4, "four different picks, the draft is done: %s" % st.get("picks"))
        for i, cl in enumerate(c):
            cl.msg({"t": "choice", "species": st["picks"][i], "ready": True})
        spin(c, 5.0, lambda: any(e.get("t") == "start" for e in c[0].events))
        start = [e for e in c[0].events if e.get("t") == "start"]
        check(bool(start) and [x["species"] for x in start[0]["slots"]] == st["picks"], "with the picked ones the match starts")
    finally:
        proc.kill()
        subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Process | Where-Object { $_.Name -like 'Godot*' } | Stop-Process -Force"], capture_output=True)
    print("\n%s" % ("ALL OK" if ok else "FAILED"))
    if not ok:
        print(open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read()[-2000:])
    sys.exit(0 if ok else 1)


def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else "fight"
    if scenario == "team_draft":
        return team_draft_main()
    if scenario in ("draft", "draft_timeout"):
        return draft_main(scenario)
    if scenario in ("team", "team_leave"):
        return team_main(scenario)
    godot = os.environ.get("GODOT", "godot")
    tmp = tempfile.mkdtemp()
    result_file = os.path.join(tmp, "result.json")
    log = open(os.path.join(tmp, "server.log"), "w", encoding="utf-8")
    proc = subprocess.Popen([godot, "--headless", "--path", GAME, "--", "--server", "--port=%d" % PORT,
                             "--match=t1", "--result=" + result_file, "--match_max=%d" % (40 if scenario == "fight" else 300)],
                            stdout=log, stderr=subprocess.STDOUT)
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond

    try:
        t0 = time.time()
        while time.time() - t0 < 90:
            log.flush()
            if "MATCH_SERVER ready" in open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read():
                break
            time.sleep(0.5)
        else:
            print("the server did not start")
            sys.exit(1)
        c = [Client(0), Client(1)]
        c[0].msg({"t": "choice", "species": "charizard", "ready": True})
        c[1].msg({"t": "choice", "species": "lucario", "ready": True})
        cpu0 = None
        fight_frame = 0
        fight_started = None
        left_sent = False
        cheat = {"last": None, "snaps": 0, "max_step": 0.0}
        deadline = time.time() + (120 if scenario == "fight" else 60)
        next_tick = time.perf_counter()
        result = None
        while time.time() < deadline:
            for cl in c:
                cl.poll()
            in_fight = c[0].phase == 2
            if in_fight:
                fight_frame += 1
                if fight_started is None:
                    fight_started = time.perf_counter()
                    cpu0 = (sample_process(), time.perf_counter())
            if scenario == "fight":
                for i, cl in enumerate(c):
                    bot(cl, 1 - i, fight_frame) if in_fight else cl.input()
            elif scenario == "forfeit":
                c[0].input() if not in_fight else bot(c[0], 1, fight_frame)
                # player 1 says nothing at all after its choice
            elif scenario == "leave":
                for i, cl in enumerate(c):
                    bot(cl, 1 - i, fight_frame) if in_fight else cl.input()
                if in_fight and fight_frame > 120 and not left_sent:
                    c[0].msg({"t": "leave"})
                    left_sent = True
            elif scenario == "cheat":
                # Alternating: NaN, huge finite values, a jumping counter, a frame number far ahead.
                n = c[0].frame
                bad = [(float("nan"), 0.0, 0.0), (1e30, -1e30, 1e30), (1e9, 1e9, -1e9), (3.0, -3.0, 50.0)][n % 4]
                if in_fight:
                    c[0].input(bad[0], bad[1], bad[2], counters_jump=100 if n % 2 else None)
                else:
                    c[0].input()
                c[1].input()
            if scenario == "cheat" and in_fight and c[0].fighters:
                p0 = c[0].fighters[0]["pos"]
                if cheat["last"] is not None and c[0].snapshots != cheat["snaps"]:
                    cheat["max_step"] = max(cheat["max_step"], math.dist(p0, cheat["last"]))
                cheat["last"], cheat["snaps"] = p0, c[0].snapshots
            res = [e for e in c[1].events_of("result")] or [e for e in c[0].events_of("result")]
            if res:
                result = res[0]
                break
            if scenario == "cheat" and in_fight and fight_frame > 600:
                break
            next_tick += 1.0 / 60.0
            time.sleep(max(0.0, next_tick - time.perf_counter()))
        # A moment more: the other player gets the result too.
        for _ in range(60):
            for cl in c:
                cl.poll()
            time.sleep(1 / 60)
        cpu1 = (sample_process(), time.perf_counter())

        if scenario in ("fight", "forfeit", "leave"):
            check(any(e.get("t") == "start" for e in c[0].events) and any(e.get("t") == "start" for e in c[1].events),
                  "both players got the start event (stage %s)" % ([e for e in c[0].events if e.get("t") == "start"] or [{}])[0].get("stage"))
            check(len(c[0].events_of("fight")) == 1, "the countdown ended in a fight")
            check(len(c[0].fighters) == 2, "snapshots carry both Pokémon")
        if scenario == "fight":
            span = (c[0].last_snapshot_at - c[0].first_snapshot_at) or 1.0
            rate = c[0].snapshots / span
            check(24 <= rate <= 36, "snapshots arrive at about 30 per second (%.1f)" % rate)
            check(c[0].applied >= fight_frame - 10 and c[0].applied > 100, "the server applied the inputs (frame %d of ~%d)" % (c[0].applied, c[0].frame))
            check(len(c[0].events_of("hit")) > 0, "hits were decided by the server (%d hit events)" % len(c[0].events_of("hit")))
            check(result is not None and result["reason"] in ("ko", "time"), "the match ended with a result: %s" % result)
            if result and result["reason"] == "ko":
                check(result["hp"][result["winner"]] > 0, "the winner has HP left")
            check(os.path.exists(result_file), "the backend gets the result as a file")
            if cpu0 and cpu0[0] and cpu1[0]:
                dt = cpu1[1] - cpu0[1]
                cores = (cpu1[0][0] - cpu0[0][0]) / dt
                print("     measured: %.2f of a core on average, %d MB, over %.0f s of fight" % (cores, cpu1[0][1], dt))
        elif scenario == "forfeit":
            check(result is not None and result["reason"] == "forfeit" and result["winner"] == 0, "a silent player forfeits: %s" % result)
        elif scenario == "leave":
            check(result is not None and result["reason"] == "left" and result["winner"] == 1, "leaving loses the match: %s" % result)
        elif scenario == "cheat":
            pos = c[0].fighters[0]["pos"] if c[0].fighters else (0, 0, 0)
            check(all(math.isfinite(v) for v in pos), "impossible inputs left a normal position: %s" % (tuple(round(v, 1) for v in pos),))
            check(cheat["max_step"] < 2.0, "never faster than a keyboard allows: the most it moved between two snapshots is %.2f m" % cheat["max_step"])
            rival = c[1].fighters[1] if len(c[1].fighters) == 2 else None
            check(rival is not None and rival["hp"] > 0, "the rival was not touched by it (HP %s)" % (rival["hp"] if rival else None))
            check(result is None or result.get("reason") in ("ko", "time"), "the match went on normally or ended by the rules: %s" % result)
    finally:
        proc.kill()
        subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Process | Where-Object { $_.Name -like 'Godot*' } | Stop-Process -Force"],
                       capture_output=True)
    print("\n%s" % ("ALL OK" if ok else "FAILED"))
    if not ok:
        print(open(os.path.join(tmp, "server.log"), encoding="utf-8", errors="replace").read()[-2500:])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
