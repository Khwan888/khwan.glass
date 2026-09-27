#!/usr/bin/env python3
"""Smoke + bug tests for khwan.glass: run the real CLI end-to-end in a
sandboxed HOME with stubbed hyprctl/omarchy binaries. Nothing real is
touched — config, state and tool calls all live in a temp dir."""
import glob
import json
import os
import subprocess
import sys
import tempfile

CTL = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "scripts", "glass-ctl"))

failures = []
checks_run = 0


def check(name, cond, detail=""):
    global checks_run
    checks_run += 1
    if cond:
        print(f"  ok  {name}")
    else:
        failures.append(name)
        print(f"FAIL  {name} {detail}")


LEGACY = """-- Change the default Omarchy look'n'feel.
-- Milky glass
hl.config({
  decoration = {
    blur = { enabled = true, size = 14, passes = 3, brightness = 1, contrast = 1, noise = 0.011 },
    rounding = 0,
    dim_inactive = false,
    dim_strength = 0.15,
  },
})
o.window(".*", { opacity = "0.85 0.85" })
"""


class Sandbox:
    def __init__(self):
        self.td = tempfile.mkdtemp(prefix="glass-smoke-")
        self.home = self.td
        os.makedirs(os.path.join(self.home, ".config/hypr"), exist_ok=True)
        stubs = os.path.join(self.home, "stubs")
        os.makedirs(stubs, exist_ok=True)
        self._stub(stubs, "hyprctl",
                   'echo "hyprctl $*" >> "$HOME/tool.log"\n'
                   'if [ "$1" = "clients" ]; then echo "[]"; fi\n')
        self._stub(stubs, "omarchy", 'echo "omarchy $*" >> "$HOME/tool.log"\n')

    @staticmethod
    def _stub(dirpath, name, body):
        p = os.path.join(dirpath, name)
        with open(p, "w") as fh:
            fh.write("#!/usr/bin/env bash\n" + body + "exit 0\n")
        os.chmod(p, 0o755)

    @property
    def lf(self):
        return os.path.join(self.home, ".config/hypr/looknfeel.lua")

    @property
    def state(self):
        return os.path.join(self.home, ".local/state/omarchy/glass.json")

    @property
    def log(self):
        try:
            with open(os.path.join(self.home, "tool.log")) as fh:
                return fh.read()
        except OSError:
            return ""

    def env(self):
        env = dict(os.environ)
        env["HOME"] = self.home
        env["PATH"] = os.path.join(self.home, "stubs") + ":" + env.get("PATH", "")
        return env

    def seed(self, text):
        with open(self.lf, "w") as fh:
            fh.write(text)

    def read(self, path):
        with open(path) as fh:
            return fh.read()

    def run(self, *args):
        return subprocess.run([sys.executable, CTL, *args],
                              capture_output=True, text=True,
                              env=self.env(), timeout=30)


def jout(p):
    try:
        return json.loads(p.stdout)
    except ValueError:
        return None


# ── S1. init: adopt only — file untouched, no tools called ─────────────
sb = Sandbox()
sb.seed(LEGACY)
before = sb.read(sb.lf)
p = sb.run("init")
check("S1 init exit 0", p.returncode == 0, p.stderr)
j = jout(p)
check("S1 init ok json", bool(j and j.get("ok")), p.stdout[:200])
check("S1 init leaves looknfeel untouched", sb.read(sb.lf) == before)
check("S1 init calls no tools", sb.log == "")
check("S1 init writes state file", os.path.exists(sb.state))

# ── S2. persist: first user change creates the block, no reload ────────
p = sb.run("persist", '{"blur":{"size":16}}')
check("S2 persist exit 0", p.returncode == 0, p.stderr)
check("S2 block created", "-- BEGIN khwan.glass" in sb.read(sb.lf))
check("S2 legacy trimmed by first write", "-- Milky glass" not in sb.read(sb.lf))
check("S2 live eval called", "eval" in sb.log)
check("S2 persist does NOT reload", "reload" not in sb.log, sb.log)
check("S2 one backup taken", len(glob.glob(sb.lf + ".bak.*")) == 1)

# ── S3. frost: block rewrite + reload ──────────────────────────────────
p = sb.run("frost", '{"frost":{"all":0.7}}')
check("S3 frost exit 0", p.returncode == 0, p.stderr)
check("S3 reload called", "reload" in sb.log)
check("S3 block carries value", 'opacity = "0.7 0.7"' in sb.read(sb.lf),
      sb.read(sb.lf)[:300])

# ── S4. presets: ink applies, stock removes the block ──────────────────
p = sb.run("preset", "ink")
check("S4 preset ink exit 0", p.returncode == 0, p.stderr)
check("S4 ink in block", "brightness = 0.55" in sb.read(sb.lf))
p = sb.run("preset", "stock")
check("S4 preset stock exit 0", p.returncode == 0, p.stderr)
text4 = sb.read(sb.lf)
check("S4 stock removes block", "-- BEGIN khwan.glass" not in text4)
check("S4 stock leaves no glass statements",
      "hl.config" not in text4 and "o.window" not in text4)

# ── S5. user presets via CLI ───────────────────────────────────────────
p = sb.run("savepreset", "Smoke Test")
j = jout(p)
check("S5 savepreset ok", p.returncode == 0 and j and j.get("ok"), p.stdout[:200])
p = sb.run("get")
j = jout(p)
check("S5 get lists user preset", j and "Smoke Test" in j.get("user", []),
      p.stdout[:300])
p = sb.run("delpreset", "Smoke Test")
check("S5 delpreset ok", p.returncode == 0)
p = sb.run("delpreset", "Smoke Test")
j = jout(p)
check("S5 delpreset twice fails cleanly",
      p.returncode == 1 and j and not j.get("ok"))

# ── S6. corners switch (toggle = square ↔ remembered radius) ───────────
p = sb.run("round", "toggle")
check("S6 round toggle exit 0", p.returncode == 0, p.stderr)
check("S6 toggle restores remembered radius",
      "rounding = 16" in sb.read(sb.lf), sb.read(sb.lf)[:300])
p = sb.run("round", "toggle")
check("S6 toggle back to square", "rounding = 0" in sb.read(sb.lf))

# ── S7. revert restores the newest backup ──────────────────────────────
snap = sb.read(sb.lf)
p = sb.run("round", "false")
check("S7 round false exit 0", p.returncode == 0)
check("S7 squares corners", "rounding = 0" in sb.read(sb.lf))
p = sb.run("revert")
check("S7 revert exit 0", p.returncode == 0, p.stderr)
check("S7 revert restores previous file", sb.read(sb.lf) == snap)

# ── S8. missing / absent config: clean errors, never creates files ─────
sb2 = Sandbox()  # dir exists, looknfeel.lua absent
p = sb2.run("persist", '{"blur":{"size":5}}')
j = jout(p)
check("S8 missing file: exit 1", p.returncode == 1, f"{p.returncode} {p.stdout[:120]}")
check("S8 missing file: clean json error",
      bool(j and not j.get("ok") and "looknfeel" in j.get("error", "")),
      p.stdout[:200])
check("S8 missing file: no traceback", "Traceback" not in p.stderr)
check("S8 missing file: nothing created", not os.path.exists(sb2.lf))
sb3 = Sandbox()
os.rmdir(os.path.join(sb3.home, ".config/hypr"))
p = sb3.run("persist", '{"blur":{"size":5}}')
j = jout(p)
check("S8b missing dir: clean error", p.returncode == 1 and j and not j.get("ok"),
      p.stdout[:200])

# ── S9. unknown command ────────────────────────────────────────────────
p = sb.run("nonsense")
j = jout(p)
check("S9 unknown command exit 2", p.returncode == 2 and j and not j.get("ok"))

# ── S10. bar toggle routes through omarchy ─────────────────────────────
p = sb.run("bar", "toggle")
check("S10 bar toggle exit 0", p.returncode == 0, p.stderr)
check("S10 omarchy called", "bar transparent" in sb.log, sb.log[-200:])

# ── S11. concurrency: two writers, flock serialises, state stays valid ─
env = sb.env()
p1 = subprocess.Popen([sys.executable, CTL, "persist", '{"blur":{"size":9}}'],
                      env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                      text=True)
p2 = subprocess.Popen([sys.executable, CTL, "persist", '{"blur":{"size":10}}'],
                      env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                      text=True)
p1.communicate(timeout=30)
p2.communicate(timeout=30)
check("S11 both writers exit 0", p1.returncode == 0 and p2.returncode == 0,
      f"{p1.returncode}/{p2.returncode}")
try:
    json.load(open(sb.state))
    state_valid = True
except ValueError:
    state_valid = False
check("S11 state file stays valid json", state_valid)

# ── S12. readback reflects the live block ──────────────────────────────
p = sb.run("readback")
j = jout(p)
check("S12 readback ok", bool(j and j.get("ok")), p.stdout[:200])
check("S12 readback reads live value",
      j and j["state"]["blur"]["size"] in (9, 10),
      str(j and j.get("state", {}).get("blur")))

# ── S13. per-app rows: ✕ removal must drop the row (regression — the frost
#        payload carries the full trimmed apps dict; removal used to be
#        impossible outside Sync all, bug report 2026-09-28) ────────────
sb4 = Sandbox()
sb4.seed("-- seed\n")
FROSTP = '{"frost":{"all":0.85,"apps":%s,"keepSolid":%s}}'


def s13_apps():
    try:
        return json.load(open(sb4.state))["frost"]["apps"]
    except (OSError, ValueError, KeyError):
        return None


p = sb4.run("frost", FROSTP % ('{"kitty":0.5,"zathura":0.9}', "[]"))
check("S13 add rows exit 0", p.returncode == 0, p.stderr)
check("S13 add rows in state", s13_apps() == {"kitty": 0.5, "zathura": 0.9},
      str(s13_apps()))
block13 = sb4.read(sb4.lf)
check("S13 add rows in block",
      'class = "kitty"' in block13 and 'class = "zathura"' in block13)

p = sb4.run("frost", FROSTP % ('{"kitty":0.7,"zathura":0.9}', "[]"))
check("S13 slider update applies", s13_apps() == {"kitty": 0.7, "zathura": 0.9},
      str(s13_apps()))

p = sb4.run("frost", FROSTP % ('{"zathura":0.9}', "[]"))
check("S13 ✕ removes row from state", s13_apps() == {"zathura": 0.9}, str(s13_apps()))
block13 = sb4.read(sb4.lf)
check("S13 ✕ removes rule from block",
      'class = "kitty"' not in block13 and 'class = "zathura"' in block13, block13)

p = sb4.run("frost", FROSTP % ("{}", "[]"))
check("S13 ✕ last row: apps empty", s13_apps() == {}, str(s13_apps()))
block13 = sb4.read(sb4.lf)
check("S13 ✕ last row: no class rules left", "class =" not in block13, block13)
check("S13 ✕ last row: global rule intact", 'opacity = "0.85 0.85"' in block13)

# absent apps key means "leave rows alone" (all-only payloads rely on this)
sb4.run("frost", FROSTP % ('{"kitty":0.5}', "[]"))
sb4.run("frost", '{"frost":{"all":0.7}}')
check("S13 all-only payload keeps rows", s13_apps() == {"kitty": 0.5}, str(s13_apps()))

# undo/applySnap merges snapshots through `set` — same replace semantics
p = sb4.run("set", '{"frost":{"all":0.7,"apps":{},"keepSolid":[]}}')
check("S13 set snapshot removes rows", s13_apps() == {}, str(s13_apps()))

# keepSolid (S toggle) replaces wholesale — pin it stays that way
sb4.run("frost", FROSTP % ("{}", '["mpv"]'))
st13 = json.load(open(sb4.state))
check("S13 keepSolid add", st13["frost"]["keepSolid"] == ["mpv"], str(st13["frost"]))
sb4.run("frost", FROSTP % ("{}", "[]"))
st13 = json.load(open(sb4.state))
check("S13 keepSolid remove", st13["frost"]["keepSolid"] == [], str(st13["frost"]))

# sync still wipes everything (the old escape hatch keeps working)
sb4.run("frost", FROSTP % ('{"kitty":0.5}', "[]"))
sb4.run("sync")
check("S13 sync still wipes", s13_apps() == {} and "class =" not in sb4.read(sb4.lf))

print()
if failures:
    print(f"{len(failures)} FAILURES out of {checks_run}: {failures}")
    sys.exit(1)
print(f"all {checks_run} tests passed")
