"""Tests for ccwatch's snapshot(): the state decisions every frontend shows.

    python3 -m unittest discover remote

Each test builds a fake ~/.claude/sessions and marker directory, pins the clock and stubs out the
process-level probes (pid liveness, ttys, tmux), then checks the decoded snapshot.
"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load_ccwatch():
    loader = importlib.machinery.SourceFileLoader("ccwatch", os.path.join(HERE, "ccwatch"))
    spec = importlib.util.spec_from_loader("ccwatch", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


NOW = 2_000_000_000.0
NO_TMUX = {"available": False, "clients": [], "sessions": []}


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.cw = load_ccwatch()
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.sessions = os.path.join(root, "sessions")
        self.markers = os.path.join(root, "heylisten")
        os.makedirs(self.sessions)
        os.makedirs(self.markers)
        self.cw.SESSIONS_DIR = self.sessions
        self.cw.MARKER_DIR = self.markers
        self.cw.CONFIG = os.path.join(root, "config.json")
        self.alive = set()
        self.cw.pid_alive = lambda pid: pid in self.alive
        self.cw.ttys_for = lambda pids: {}

    def tearDown(self):
        self.tmp.cleanup()

    # helpers

    def session(self, pid=100, sid="s1", alive=True, **fields):
        d = {"pid": pid, "sessionId": sid, "cwd": "/w", "status": "idle", **fields}
        with open(os.path.join(self.sessions, "%d.json" % pid), "w") as f:
            json.dump(d, f)
        if alive:
            self.alive.add(pid)

    def marker(self, name, data, age=0):
        path = os.path.join(self.markers, name)
        with open(path, "w") as f:
            json.dump(data, f)
        os.utime(path, (NOW - age, NOW - age))

    def config(self, **settings):
        with open(self.cw.CONFIG, "w") as f:
            json.dump(settings, f)

    def snap(self, now=NOW):
        return self.cw.snapshot(now, NO_TMUX)["sessions"]

    def one(self, now=NOW):
        s = self.snap(now)
        self.assertEqual(len(s), 1)
        return s[0]

    # sessions

    def test_dead_and_malformed_sessions_are_skipped(self):
        self.session(pid=1, sid="dead", alive=False)
        self.session(pid=2, sid="live")
        with open(os.path.join(self.sessions, "junk.json"), "w") as f:
            f.write("{not json")
        with open(os.path.join(self.sessions, "3.json"), "w") as f:
            json.dump({"pid": "3"}, f)   # pid not an int
        self.assertEqual([s["sessionId"] for s in self.snap()], ["live"])

    def test_tmux_field_with_colon_in_session_name(self):
        self.session(tmux="work:api:@3.%7")
        self.assertEqual(self.one()["tmux"], {"session": "work:api", "window": "@3", "pane": "%7"})

    def test_missing_tmux_field(self):
        self.session()
        self.assertIsNone(self.one()["tmux"])

    def test_session_id_cannot_escape_marker_dir(self):
        # A hostile id is sanitised to the same name hook.py uses, never a path outside MARKER_DIR.
        self.assertEqual(self.cw.marker_name("../../etc/passwd"), "etcpasswd.json")
        self.assertIsNone(self.cw.marker_name("../"))
        self.session(sid="../")
        self.assertIsNone(self.one()["attention"])

    # attention

    def test_attention_from_marker(self):
        self.session()
        self.marker("s1.json", {"state": "permission", "message": "Bash: rm", "ts": NOW - 5})
        self.assertEqual(self.one()["attention"],
                         {"state": "permission", "message": "Bash: rm", "ts": NOW - 5})

    def test_unknown_attention_state_is_ignored(self):
        self.session()
        self.marker("s1.json", {"state": "bogus"})
        self.assertIsNone(self.one()["attention"])

    # prompt cache

    def test_cache_warm_then_cold_after_ttl(self):
        self.session()
        self.marker("s1.ctx.json", {"tokens": 1000, "ttl": 300, "ts": NOW - 299})
        self.assertFalse(self.one()["cacheCold"])
        self.assertTrue(self.one(NOW + 2)["cacheCold"])
        self.assertEqual(self.one()["cacheTtl"], 300)
        self.assertEqual(self.one()["lastTurn"], NOW - 299)

    def test_cache_never_cold_while_busy(self):
        self.session(status="busy")
        self.marker("s1.ctx.json", {"tokens": 1000, "ttl": 300, "ts": NOW - 10_000})
        self.assertFalse(self.one()["cacheCold"])

    def test_cache_ttl_falls_back_to_config(self):
        self.session()
        self.marker("s1.ctx.json", {"tokens": 1000, "ts": NOW - 4000})
        self.assertTrue(self.one()["cacheCold"])         # default 3600
        self.config(cacheTtl=5000)
        self.assertFalse(self.one()["cacheCold"])
        self.assertEqual(self.one()["cacheTtl"], 5000)

    def test_no_ctx_marker_means_not_cold(self):
        self.session()
        s = self.one()
        self.assertFalse(s["cacheCold"])
        self.assertIsNone(s["lastTurn"])
        self.assertIsNone(s["contextTokens"])

    # context level

    def test_context_levels(self):
        self.session()
        for tokens, level in ((599_999, "normal"), (600_000, "high"), (800_000, "full")):
            self.marker("s1.ctx.json", {"tokens": tokens, "ts": NOW})
            self.assertEqual(self.one()["contextLevel"], level, tokens)

    def test_context_window_from_config(self):
        self.session()
        self.marker("s1.ctx.json", {"tokens": 170_000, "ts": NOW})
        self.config(contextWindow=200_000)
        s = self.one()
        self.assertEqual(s["contextWindow"], 200_000)
        self.assertEqual(s["contextLevel"], "full")

    def test_bad_config_values_are_ignored(self):
        self.session()
        self.marker("s1.ctx.json", {"tokens": 700_000, "ts": NOW})
        self.config(contextWindow="small", contextHigh=True, unknownKey=1)
        s = self.one()
        self.assertEqual(s["contextWindow"], 1_000_000)
        self.assertEqual(s["contextLevel"], "high")

    # running turn

    def test_long_turn(self):
        self.session(status="busy")
        self.marker("s1.turn.json", {"ts": NOW - 601})
        self.assertTrue(self.one()["longTurn"])
        self.marker("s1.turn.json", {"ts": NOW - 599})
        self.assertFalse(self.one()["longTurn"])

    def test_long_turn_needs_busy(self):
        self.session(status="idle")
        self.marker("s1.turn.json", {"ts": NOW - 10_000})
        self.assertFalse(self.one()["longTurn"])

    def test_compacting_marker_goes_stale(self):
        self.session()
        self.marker("s1.compacting.json", {"ts": NOW}, age=10)
        self.assertTrue(self.one()["compacting"])
        self.marker("s1.compacting.json", {"ts": NOW}, age=601)
        self.assertFalse(self.one()["compacting"])

    def test_subagents_counted_per_session_minus_stale(self):
        self.session(pid=1, sid="s1")
        self.session(pid=2, sid="s2")
        self.marker("s1.agent.a.json", {}, age=5)
        self.marker("s1.agent.b.json", {}, age=5)
        self.marker("s1.agent.old.json", {}, age=3 * 3600 + 1)
        self.marker("s2.agent.c.json", {}, age=5)
        by_id = {s["sessionId"]: s["subagents"] for s in self.snap()}
        self.assertEqual(by_id, {"s1": 2, "s2": 1})


class TtyCacheTest(unittest.TestCase):
    def setUp(self):
        self.cw = load_ccwatch()
        self.calls = []

        class R:
            def __init__(self, out):
                self.stdout = out

        def run(args, **kw):
            pids = args[-1].split(",")
            self.calls.append(pids)
            return R("".join("%s ttys00%s\n" % (p, p) for p in pids if p != "9"))

        self.cw.subprocess.run = run

    def test_ps_only_for_new_pids(self):
        self.assertEqual(self.cw.ttys_for([1, 2]), {1: "/dev/ttys001", 2: "/dev/ttys002"})
        self.assertEqual(self.cw.ttys_for([1, 2, 3]), {1: "/dev/ttys001", 2: "/dev/ttys002", 3: "/dev/ttys003"})
        self.assertEqual(self.cw.ttys_for([1, 2, 3]), {1: "/dev/ttys001", 2: "/dev/ttys002", 3: "/dev/ttys003"})
        self.assertEqual(self.calls, [["1", "2"], ["3"]])

    def test_no_tty_is_remembered_and_gone_pids_forgotten(self):
        self.assertEqual(self.cw.ttys_for([9]), {})
        self.assertEqual(self.cw.ttys_for([9]), {})
        self.assertEqual(self.calls, [["9"]])
        self.cw.ttys_for([])          # pid 9 exited
        self.cw.ttys_for([9])         # reused: asked again
        self.assertEqual(self.calls, [["9"], ["9"]])


if __name__ == "__main__":
    unittest.main()
