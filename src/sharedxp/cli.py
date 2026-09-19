"""sharedxp - flatten a Palworld world's players onto one shared XP pool."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .curve import ExpCurve, Observation
from .pool import Mode, build_plan
from .save import LevelSave

DEFAULT_TABLE = Path(__file__).resolve().parents[2] / "data" / "exp_table.json"


def _load(world: str, table: str, mode: str):
    curve = ExpCurve.from_json(table)
    save = LevelSave.load(world)
    players = save.players()
    if not players:
        raise SystemExit("no players found in this save")
    plan = build_plan(players, curve, Mode(mode))
    return curve, save, players, plan


def _print_report(curve, players, plan) -> None:
    print(f"curve: {curve.source}")
    print(f"       levels 1-{curve.max_level}\n")

    drift = curve.validate([Observation(p.name, p.level, p.exp) for p in players])
    if drift:
        print("curve drift (expected on saves made before a curve change):")
        for line in drift:
            print(f"  ! {line}")
        print("  these players keep their stored level; nobody is lowered.\n")

    print(f"{'player':<16}{'level':>7}{'xp':>14}  ->{'level':>7}{'xp':>14}   change")
    print("-" * 74)
    for c in plan.changes:
        p = c.player
        mark = "" if not c.changed else f"  +{c.exp_delta:,} xp"
        if c.changed and c.level_delta:
            mark += f", +{c.level_delta} lv"
        if not c.changed:
            mark = "  (already ahead of the pool)"
        print(
            f"{p.name:<16}{p.level:>7}{p.exp:>14,}  ->"
            f"{c.target_level:>7}{c.target_exp:>14,}{mark}"
        )
    print("-" * 74)
    print(f"pool ({plan.mode.value}): {plan.pool_exp:,} xp = level {plan.pool_level}")
    print(f"players changed: {len(plan.touched)} of {len(plan.changes)}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="sharedxp", description=__doc__)
    ap.add_argument("command", choices=["report", "apply"])
    ap.add_argument("world", help="world save dir (the one containing Level.sav)")
    ap.add_argument("--table", default=str(DEFAULT_TABLE), help="exp table json")
    ap.add_argument(
        "--mode", default="mean", choices=[m.value for m in Mode], help="pooling mode"
    )
    ap.add_argument("--yes", action="store_true", help="skip the apply confirmation")
    args = ap.parse_args(argv)

    curve, save, players, plan = _load(args.world, args.table, args.mode)
    _print_report(curve, players, plan)

    if args.command == "report":
        print("\n(report only - nothing was written)")
        return 0

    if not plan.touched:
        print("\nnothing to do.")
        return 0

    if not args.yes:
        print(f"\nabout to rewrite {save.path}")
        if input("type 'apply' to continue: ").strip() != "apply":
            print("aborted.")
            return 1

    backup = save.backup()
    print(f"\nbackup: {backup}")
    targets = {c.player.uid: (c.target_level, c.target_exp) for c in plan.touched}
    n = save.apply(targets)
    save.save()
    print(f"wrote {n} player(s)")

    # read it back from disk and confirm the values actually landed
    verify = LevelSave.load(Path(args.world)).players()
    by_uid = {p.uid: p for p in verify}
    bad = [
        f"{uid}: expected level {lv} / {xp:,} xp, found level "
        f"{by_uid[uid].level} / {by_uid[uid].exp:,} xp"
        for uid, (lv, xp) in targets.items()
        if uid in by_uid and (by_uid[uid].level != lv or by_uid[uid].exp != xp)
    ]
    if bad:
        print("VERIFY FAILED:")
        for b in bad:
            print(f"  ! {b}")
        return 2
    print("verified: re-read from disk matches the plan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
