#!/usr/bin/env python3
"""Golden tests for khwan.glass block generation + parsing (no live changes)."""
import importlib.util
import json
import os
import sys
import tempfile

import importlib.machinery
import importlib.util
import os

CTL = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "scripts", "glass-ctl"))
loader = importlib.machinery.SourceFileLoader("glass_ctl", CTL)
spec = importlib.util.spec_from_loader("glass_ctl", loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)

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


# ── 1. default state → golden block (no per-app rows by default) ──────
state = g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE))
block = g.gen_block(state)
golden = """-- BEGIN khwan.glass (managed by the Glass bar panel — edits are overwritten; use the panel)
hl.config({
  decoration = {
    blur = { enabled = true, size = 14, passes = 3,
             brightness = 1, contrast = 1, noise = 0.011 },
    rounding = 0,
    dim_inactive = false,
    dim_strength = 0.15,
  },
})
o.window(".*", { opacity = "0.85 0.85" })
-- END khwan.glass"""
check("golden block (default state)", block == golden,
      f"\n--- got ---\n{block}\n--- want ---\n{golden}")

# ── 2. round-trip with a per-app row: gen → parse → gen is stable ─────
state = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                      {"frost": {"apps": {"com.nousresearch.hermes": 0.82}}}))
block = g.gen_block(state)
parsed = g.parse_block(block)
check("round-trip parse", parsed is not None)
if parsed:
    check("round-trip frost.all", abs(parsed["frost"]["all"] - 0.85) < 1e-9, str(parsed["frost"]))
    check("round-trip hermes app", parsed["frost"]["apps"].get("com.nousresearch.hermes") == 0.82,
          str(parsed["frost"]["apps"]))
    check("round-trip blur", parsed["blur"] == state["blur"], str(parsed["blur"]))
    check("round-trip shapes", parsed["shapes"] == state["shapes"], str(parsed["shapes"]))
    check("round-trip stable", g.gen_block(parsed) == block)

# ── 3. keepSolid rows survive round-trip ──────────────────────────────
s3 = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                     {"frost": {"apps": {"vlc": 0.9}, "keepSolid": ["mpv", "zoom"]}}))
b3 = g.gen_block(s3)
p3 = g.parse_block(b3)
check("keepSolid generated", 'o.window({ class = "mpv" }, { opacity = "1 1" })' in b3, b3)
check("keepSolid parsed back", p3 and sorted(p3["frost"]["keepSolid"]) == ["mpv", "zoom"],
      str(p3["frost"]["keepSolid"]) if p3 else "None")
check("app+keepSolid coexist", p3 and p3["frost"]["apps"].get("vlc") == 0.9)

# ── 4. sanitize: bad class names dropped, values clamped ──────────────
s4 = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE), {
    "frost": {"apps": {"evil class;rm -rf": 0.5, "good.App-x": 9.0}},
    "blur": {"size": 999, "passes": -3, "noise": 2.0},
    "shapes": {"rounding": -5, "dimStrength": 5.0},
}))
check("bad class dropped", "evil class;rm -rf" not in s4["frost"]["apps"])
check("good class kept", "good.App-x" in s4["frost"]["apps"])
check("app opacity clamped to 1.0", s4["frost"]["apps"]["good.App-x"] == 1.0)
check("blur size clamped 24", s4["blur"]["size"] == 24)
check("passes clamped 1", s4["blur"]["passes"] == 1)
check("noise clamped 0.10", s4["blur"]["noise"] == 0.10)
check("rounding clamped 0", s4["shapes"]["rounding"] == 0)
check("dimStrength clamped 0.60", s4["shapes"]["dimStrength"] == 0.60)

# ── 5. splice into a copy of the REAL looknfeel.lua ───────────────────
real = os.path.expanduser("~/.config/hypr/looknfeel.lua")
if not os.path.exists(real):
    print("  skip  real-file splice (no ~/.config/hypr/looknfeel.lua)")
else:
    real_text = open(real, encoding="utf-8").read()
    # reconstruct the pre-managed state: strip any live managed block the way
    # remove_block does, so this test works whether or not the real file is managed
    if g.split_managed(real_text):
        _pre, _inner, _post = g.split_managed(real_text)
        real_text = (_pre.rstrip() + "\n" if _pre.strip() else "")
        if _post.strip():
            real_text += "\n" + _post.lstrip("\n")
    with tempfile.TemporaryDirectory() as td:
        # deterministic adoption source: seed a state file instead of the live one
        _state_orig, _look_orig = g.STATE_PATH, g.LOOKNFEEL
        g.STATE_PATH = os.path.join(td, "glass.json")
        g.save_state(g.sanitize_state(g.deep_merge(
            g.copy.deepcopy(g.DEFAULT_STATE),
            {"frost": {"apps": {"com.nousresearch.hermes": 0.82}}})))
        lf = os.path.join(td, "looknfeel.lua")
        open(lf, "w").write(real_text)
        g.LOOKNFEEL = lf
        # init adopts but never writes (consent model — see §13)
        g.cmd_init()
        check("real file: init leaves it untouched", open(lf).read() == real_text)
        # first user-initiated write creates the managed block
        g.write_block(g.load_state())
        text5 = open(lf).read()
        parts = g.split_managed(text5)
        check("real file: block spliced", parts is not None)
        check("real file: commented template intact",
              "-- Change the default Omarchy look'n'feel." in text5)
        check("real file: adopted hermes 0.82",
              parts and 'opacity = "0.82 0.82"' in parts[1], parts[1] if parts else "")
        # second write replaces in place
        g.write_block(g.load_state())
        text5b = open(lf).read()
        check("real file: second write replaces", text5b.count(g.MANAGED_BEGIN) == 1)
        # readback on the temp file keeps userPresets from the base state
        base5 = g.load_state()
        base5["userPresets"] = {"My Look": g.sanitize_preset({"blur": {"size": 20}})}
        rb5 = g.parse_block(open(lf).read(), base5)
        check("readback keeps userPresets", rb5 and "My Look" in rb5["userPresets"],
              str(rb5["userPresets"]) if rb5 else "None")
        g.STATE_PATH, g.LOOKNFEEL = _state_orig, _look_orig

# ── 6. all 9 applyable presets generate + parse + identify ────────────
for name in ("milky", "cloud", "frosted", "smoke", "ink", "crystal", "veil", "gauze", "crisp"):
    sp = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE), g.PRESETS[name]))
    bp = g.gen_block(sp)
    check(f"preset {name} generates + parses", g.parse_block(bp) is not None)
    check(f"preset {name} identified active", g.active_preset(sp) == name,
          f"got {g.active_preset(sp)}")

# presets leave per-app rows alone (deliberate)
s6b = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                    {"frost": {"apps": {"kitty": 0.5}}}))
s6c = g.sanitize_state(g.deep_merge(s6b, g.PRESETS["ink"]))
check("preset keeps per-app rows", s6c["frost"]["apps"].get("kitty") == 0.5, str(s6c["frost"]))
check("preset still identified with rows", g.active_preset(s6c) == "ink")

# ── 7. stock position + custom ────────────────────────────────────────
st = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE), g.STOCK))
check("stock identified", g.active_preset(st) == "stock", f"got {g.active_preset(st)}")
tw = g.sanitize_state(g.deep_merge(g.copy.deepcopy(st), {"shapes": {"rounding": 5}}))
check("custom when tweaked", g.active_preset(tw) is None, f"got {g.active_preset(tw)}")
tw2 = g.sanitize_state(g.deep_merge(g.copy.deepcopy(st), {"blur": {"size": 3}}))
check("inert blur tweak stays stock", g.active_preset(tw2) == "stock", f"got {g.active_preset(tw2)}")
st_r = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                     {"shapes": {"rounding": 12, "dimInactive": True}}))
st_r = g.sanitize_state(g.deep_merge(st_r, g.STOCK))
check("stock squares the corners + clears dim", st_r["shapes"]["rounding"] == 0
      and not st_r["shapes"]["dimInactive"] and g.active_preset(st_r) == "stock",
      str(st_r["shapes"]))
check("milky state not stock", g.active_preset(g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE))) == "milky")

# ── 8. sync wipes per-app rules ───────────────────────────────────────
s8 = g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE))
s8["frost"]["apps"] = {"a.b": 0.5, "c.d": 0.6}
s8["frost"]["keepSolid"] = ["e.f"]
removed8 = g.sync_state(s8)
check("sync removed count", removed8 == 3, str(removed8))
check("sync wiped apps", s8["frost"]["apps"] == {} and s8["frost"]["keepSolid"] == [])
b8 = g.gen_block(s8)
check("sync block has no class rules", 'class =' not in b8, b8)
check("sync keeps global rule", 'o.window(".*", { opacity = "0.85 0.85" })' in b8)

# ── 9. user presets: save / apply (replace) / delete / guards ─────────
s9 = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                   {"frost": {"apps": {"com.nousresearch.hermes": 0.82}}}))
err9 = g.set_user_preset(s9, "My Look")
check("save user preset ok", err9 is None and "My Look" in s9["userPresets"],
      f"err={err9}")
s9b = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                    {"blur": {"size": 5, "brightness": 0.5},
                                     "frost": {"all": 0.4, "apps": {"firefox": 0.6}}}))
s9b["userPresets"] = s9["userPresets"]  # applying keeps the registry
s9c = g.apply_user_preset(s9b, "My Look")
check("user preset restores look", s9c["blur"]["size"] == 14 and s9c["blur"]["brightness"] == 1.0
      and s9c["frost"]["all"] == 0.85, str(s9c["blur"]))
check("user preset replaces app rows", s9c["frost"]["apps"] == {"com.nousresearch.hermes": 0.82},
      str(s9c["frost"]["apps"]))
check("user preset identified active", g.active_preset(s9c) == "My Look",
      f"got {g.active_preset(s9c)}")
s9d = g.sanitize_state(g.deep_merge(g.copy.deepcopy(s9c), {"frost": {"apps": {"firefox": 0.6}}}))
check("extra app row breaks user-preset identity", g.active_preset(s9d) == "milky",
      f"got {g.active_preset(s9d)}")
check("apply unknown user preset returns None",
      g.apply_user_preset(g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE)), "nope") is None)
check("reserved name blocked",
      g.set_user_preset(g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE)), "milky") is not None)
check("reserved name blocked case-insensitively",
      g.set_user_preset(g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE)), "Ink") is not None)
check("bad name blocked",
      g.set_user_preset(g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE)), "bad/name!") is not None)
check("user preset sanitized on load",
      g.sanitize_state({"userPresets": {"x": {"blur": {"size": 999}}}})["userPresets"]["x"]["blur"]["size"] == 24)
check("case-folded builtin dropped on load",
      "Ink" not in g.sanitize_state({"userPresets": {"Ink": {"blur": {"size": 1}}}})["userPresets"])
check("malicious preset name dropped",
      "not a valid/name" not in g.sanitize_state({"userPresets": {"not a valid/name": {}, "y": {"blur": {"size": 1}}}})["userPresets"])
check("valid short name kept",
      "y" in g.sanitize_state({"userPresets": {"not a valid/name": {}, "y": {"blur": {"size": 1}}}})["userPresets"])

# ── 10. ok_state response shape ───────────────────────────────────────
r10 = g.ok_state(g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE)))
check("ok_state keys", r10["ok"] and "active" in r10 and r10["active"] == "milky"
      and r10["builtins"] == ["milky", "cloud", "frosted", "smoke", "ink", "crystal", "veil", "gauze", "crisp", "stock"]
      and r10["user"] == [] and r10["tour"] == ["cloud", "smoke", "ink", "crystal", "milky"],
      json.dumps(r10))

# ── 11. corners switch + rounding memory ──────────────────────────────
s11 = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                    {"shapes": {"rounding": 7}}))
check("roundingMem defaults 16", g.sanitize_state({})["roundingMem"] == 16)
check("roundingMem clamped", g.sanitize_state({"roundingMem": 99})["roundingMem"] == 24)
check("roundingMem clamped low", g.sanitize_state({"roundingMem": -5})["roundingMem"] == 0)
check("switch false → square", g.rounding_switch(s11, "false") == 0)
check("switch true keeps current", g.rounding_switch(s11, "true") == 7)
check("switch toggle squares", g.rounding_switch(s11, "toggle") == 0)
s11z = g.sanitize_state(g.deep_merge(g.copy.deepcopy(s11), {"shapes": {"rounding": 0}}))
check("switch restores memory", g.rounding_switch(s11z, "true") == 16
      and g.rounding_switch(s11z, "toggle") == 16)
check("switch invalid arg", g.rounding_switch(s11, "nope") is None)
with tempfile.TemporaryDirectory() as td11w:
    _sp11 = g.STATE_PATH
    g.STATE_PATH = os.path.join(td11w, "glass.json")
    g.save_state(g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                               {"shapes": {"rounding": 5}})))
    check("save pins roundingMem", g.load_state()["roundingMem"] == 5)
    st11 = g.load_state()
    st11["shapes"]["rounding"] = 0            # square; memory must survive
    g.save_state(st11)
    st11b = g.load_state()
    check("square keeps roundingMem",
          st11b["roundingMem"] == 5 and st11b["shapes"]["rounding"] == 0)
    check("switch restores pinned radius", g.rounding_switch(st11b, "toggle") == 5)
    st11c = g.sanitize_state(g.deep_merge(g.copy.deepcopy(g.DEFAULT_STATE),
                                          {"shapes": {"rounding": 9}, "roundingMem": 4}))
    if g.rounding_switch(st11c, "false") == 0 and st11c["shapes"]["rounding"] > 0:
        st11c["roundingMem"] = st11c["shapes"]["rounding"]
    st11c["shapes"]["rounding"] = 0
    g.save_state(st11c)
    check("square pins the live radius first", g.load_state()["roundingMem"] == 9)
    g.STATE_PATH = _sp11

# ── 12. load_state: disk wins for apps/keepSolid (no resurrection) ────
with tempfile.TemporaryDirectory() as td11:
    g.STATE_PATH = os.path.join(td11, "glass.json")
    with open(g.STATE_PATH, "w") as fh:
        json.dump({"version": 1, "frost": {"all": 0.7, "apps": {}, "keepSolid": []}}, fh)
    st11 = g.load_state()
    check("empty apps on disk stays empty", st11["frost"]["apps"] == {}, str(st11["frost"]["apps"]))
    with open(g.STATE_PATH, "w") as fh:
        json.dump({"version": 1, "frost": {"all": 0.7, "apps": {"kitty": 0.5}, "keepSolid": ["mpv"]}}, fh)
    st11b = g.load_state()
    check("disk rows load",
          st11b["frost"]["apps"] == {"kitty": 0.5} and st11b["frost"]["keepSolid"] == ["mpv"],
          str(st11b["frost"]))
    os.remove(g.STATE_PATH)
    st11c = g.load_state()
    check("missing file → defaults (no rows)",
          st11c["frost"]["apps"] == {} and st11c["frost"]["all"] == 0.85)

# ── 13. consent model: init is read-only ──────────────────────────────
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
with tempfile.TemporaryDirectory() as td13:
    _sp13, _lk13 = g.STATE_PATH, g.LOOKNFEEL
    g.STATE_PATH = os.path.join(td13, "glass.json")
    lf = os.path.join(td13, "looknfeel.lua")
    open(lf, "w").write(LEGACY)
    g.LOOKNFEEL = lf
    before13 = open(lf).read()
    rc13 = g.cmd_init()
    check("consent: init exit 0", rc13 == 0)
    check("consent: init leaves looknfeel byte-identical", open(lf).read() == before13)
    check("consent: init writes no backup", not g.glob.glob(lf + ".bak.*"))
    st13 = g.load_state()
    check("consent: init adopts hand-written values",
          st13["blur"]["size"] == 14 and st13["frost"]["all"] == 0.85,
          str(st13["blur"]) + str(st13["frost"]))
    g.STATE_PATH, g.LOOKNFEEL = _sp13, _lk13

# ── 14. guarded legacy trim: pure glass tail trims at first write ─────
with tempfile.TemporaryDirectory() as td14:
    _sp14, _lk14 = g.STATE_PATH, g.LOOKNFEEL
    g.STATE_PATH = os.path.join(td14, "glass.json")
    lf = os.path.join(td14, "looknfeel.lua")
    open(lf, "w").write(LEGACY)
    g.LOOKNFEEL = lf
    g.write_block(g.load_state())
    text14 = open(lf).read()
    check("trim: legacy marker gone after first write", "-- Milky glass" not in text14)
    check("trim: omarchy header comment kept",
          "-- Change the default Omarchy look'n'feel." in text14)
    check("trim: block spliced", g.split_managed(text14) is not None)
    check("trim: one backup taken", len(g.glob.glob(lf + ".bak.*")) == 1)
    g.STATE_PATH, g.LOOKNFEEL = _sp14, _lk14

# ── 15. guarded legacy trim: mixed tails survive ──────────────────────
MIXED = LEGACY + 'hl.env("EDITOR", "nvim")\n'
check("trim: mixed tail not trimmed (unit)",
      g.trim_legacy_glass_section(MIXED) == MIXED)
check("trim: no marker → unchanged (unit)",
      g.trim_legacy_glass_section("hl.config({})\n") == "hl.config({})\n")
with tempfile.TemporaryDirectory() as td15:
    _sp15, _lk15 = g.STATE_PATH, g.LOOKNFEEL
    g.STATE_PATH = os.path.join(td15, "glass.json")
    lf = os.path.join(td15, "looknfeel.lua")
    open(lf, "w").write(MIXED)
    g.LOOKNFEEL = lf
    g.write_block(g.load_state())
    text15 = open(lf).read()
    check("trim: mixed tail survives first write",
          "-- Milky glass" in text15 and 'hl.env("EDITOR", "nvim")' in text15)
    check("trim: block appended after intact tail", g.split_managed(text15) is not None)
    g.STATE_PATH, g.LOOKNFEEL = _sp15, _lk15

# ── 16. stock no-op + write guards never create looknfeel.lua ─────────
with tempfile.TemporaryDirectory() as td16:
    _sp16, _lk16 = g.STATE_PATH, g.LOOKNFEEL
    g.STATE_PATH = os.path.join(td16, "glass.json")
    lf = os.path.join(td16, "looknfeel.lua")
    open(lf, "w").write("-- plain file\n")
    g.LOOKNFEEL = lf
    before16 = open(lf).read()
    check("stock-noop: remove_block empty on unmanaged file", g.remove_block() == "")
    check("stock-noop: file untouched", open(lf).read() == before16)
    missing = os.path.join(td16, "nope", "looknfeel.lua")
    g.LOOKNFEEL = missing
    try:
        g.write_block(g.load_state())
        check("missing-file: write raises CtlError", False)
    except g.CtlError as e:
        check("missing-file: write raises CtlError", "looknfeel.lua" in str(e), str(e))
    check("missing-file: nothing created", not os.path.exists(missing))
    fresh = os.path.join(td16, "fresh.lua")
    g.LOOKNFEEL = fresh
    try:
        g.write_block(g.load_state())
        check("missing-file (dir ok): write raises CtlError", False)
    except g.CtlError:
        check("missing-file (dir ok): write raises CtlError", True)
    check("missing-file (dir ok): nothing created", not os.path.exists(fresh))
    g.STATE_PATH, g.LOOKNFEEL = _sp16, _lk16

# ── 17. backup hygiene (review 2026-09-28): never truncate, never follow ──
with tempfile.TemporaryDirectory() as td17:
    _sp17, _lk17, _tm17 = g.STATE_PATH, g.LOOKNFEEL, g.time.time
    g.STATE_PATH = os.path.join(td17, "glass.json")
    lf = os.path.join(td17, "looknfeel.lua")
    open(lf, "w").write(LEGACY)
    g.LOOKNFEEL = lf
    g.time.time = lambda: 1700000000
    victim = os.path.join(td17, "victim.txt")
    open(victim, "w").write("VICTIM")
    os.symlink(victim, f"{lf}.bak.1700000000")          # colliding symlink
    st17 = g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE))
    bak17 = g.write_block(st17)
    check("backup: colliding symlink not used", bak17 != f"{lf}.bak.1700000000", bak17)
    check("backup: victim not truncated", open(victim).read() == "VICTIM")
    check("backup: colliding symlink still present", os.path.islink(f"{lf}.bak.1700000000"))
    check("backup: content is pre-write text", open(bak17).read() == LEGACY)
    check("backup: name is .bak.<t>.N", bak17 == f"{lf}.bak.1700000000.1", bak17)
    check("backup: ledger recorded", st17.get("backups") == [bak17], str(st17.get("backups")))
    check("backup: ledger persisted", g.load_state().get("backups") == [bak17],
          str(g.load_state().get("backups")))
    bak17b = g.write_block(st17)                        # same second again
    check("backup: second collision bumped", bak17b == f"{lf}.bak.1700000000.2", bak17b)
    check("backup: ledger holds both", st17["backups"] == [bak17, bak17b], str(st17["backups"]))
    check("backup: victim still untouched", open(victim).read() == "VICTIM")
    g.STATE_PATH, g.LOOKNFEEL, g.time.time = _sp17, _lk17, _tm17

# ── 18. prune: only ledgered backups; foreign files survive ──────────
with tempfile.TemporaryDirectory() as td18:
    _sp18, _lk18, _tm18 = g.STATE_PATH, g.LOOKNFEEL, g.time.time
    g.STATE_PATH = os.path.join(td18, "glass.json")
    lf = os.path.join(td18, "looknfeel.lua")
    open(lf, "w").write("x\n")
    g.LOOKNFEEL = lf
    st18 = g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE))
    made = []
    for i in range(12):
        g.time.time = lambda i=i: 1710000000 + i
        made.append(g.write_block(st18))
    check("prune: write made 12 backups", len(made) == 12, str(made))
    check("prune: ledger trimmed to 10", len(st18["backups"]) == 10, str(st18["backups"]))
    check("prune: oldest two deleted",
          not os.path.exists(made[0]) and not os.path.exists(made[1])
          and all(os.path.exists(p) for p in made[2:]))
    foreign = f"{lf}.bak.1234567890"                    # matches pattern, not ledgered
    open(foreign, "w").write("someone else's backup")
    foreign2 = f"{lf}.bak.1234567890.7"
    open(foreign2, "w").write("also foreign")
    other = f"{lf}.mybackup"
    open(other, "w").write("user data")
    g.prune_backups(st18)
    check("prune: foreign pattern file survives", os.path.exists(foreign))
    check("prune: foreign suffixed file survives", os.path.exists(foreign2))
    check("prune: non-pattern user file survives", os.path.exists(other))
    g.STATE_PATH, g.LOOKNFEEL, g.time.time = _sp18, _lk18, _tm18

# ── 19. reads/writes refuse symlinks & special files (no follow) ─────
with tempfile.TemporaryDirectory() as td19:
    _sp19, _lk19 = g.STATE_PATH, g.LOOKNFEEL
    g.STATE_PATH = os.path.join(td19, "glass.json")
    target = os.path.join(td19, "target.lua")
    open(target, "w").write("-- target\n")
    link = os.path.join(td19, "looknfeel.lua")
    os.symlink(target, link)
    g.LOOKNFEEL = link
    try:
        g.load_text(link)
        check("nofollow: symlink read refused", False)
    except g.CtlError as e:
        check("nofollow: symlink read refused",
              "regular file" in str(e) or "symlink" in str(e), str(e))
    st19 = g.sanitize_state(g.copy.deepcopy(g.DEFAULT_STATE))
    try:
        g.write_block(st19)
        check("nofollow: symlink write refused", False)
    except g.CtlError as e:
        check("nofollow: symlink write refused", "regular file" in str(e), str(e))
    check("nofollow: target untouched", open(target).read() == "-- target\n")
    check("nofollow: no backup on refusal", not g.glob.glob(link + ".bak.*"))
    fifo = os.path.join(td19, "fifo.lua")
    os.mkfifo(fifo)
    g.LOOKNFEEL = fifo
    try:
        g.load_text(fifo)
        check("nofollow: fifo read refused", False)
    except g.CtlError as e:
        check("nofollow: fifo read refused", "regular file" in str(e), str(e))
    try:
        g.write_block(st19)
        check("nofollow: fifo write refused", False)
    except g.CtlError:
        check("nofollow: fifo write refused", True)
    os.unlink(fifo)
    big = os.path.join(td19, "big.lua")
    with open(big, "w") as fh:
        fh.write("x" * (g.LOOKNFEEL_MAX_BYTES + 1))
    g.LOOKNFEEL = big
    try:
        g.load_text(big)
        check("nofollow: oversized read refused", False)
    except g.CtlError as e:
        check("nofollow: oversized read refused", "larger" in str(e), str(e))
    g.LOOKNFEEL = os.path.join(td19, "gone.lua")
    check("nofollow: missing read still empty", g.load_text(g.LOOKNFEEL) == "")
    g.STATE_PATH, g.LOOKNFEEL = _sp19, _lk19

print()
if failures:
    print(f"{len(failures)} FAILURES out of {checks_run}: {failures}")
    sys.exit(1)
print(f"all {checks_run} tests passed")
