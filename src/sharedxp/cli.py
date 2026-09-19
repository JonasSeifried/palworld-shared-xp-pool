"""sharedxp - put a Palworld world's players on one shared XP pool and tech tree."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .curve import ExpCurve, Observation
from .pool import Mode, build_plan
from .save import LevelSave, PlayerSave, normalize_uid
from .tech import PlayerTech, build_tech_plan

DEFAULT_TABLE = Path(__file__).resolve().parents[2] / "data" / "exp_table.json"


def _print_xp(curve, players, plan) -> None:
    print(f"curve: {curve.source}")

    drift = curve.validate([Observation(p.name, p.level, p.exp) for p in players])
    if drift:
        print("\ncurve drift (expected on saves made before a curve change):")
        for line in drift:
            print(f"  ! {line}")
        print("  these players keep their stored level; nobody is lowered.")

    print(f"\n{'player':<16}{'level':>7}{'xp':>14}  ->{'level':>7}{'xp':>14}   change")
    print("-" * 74)
    for c in plan.changes:
        p = c.player
        if not c.changed:
            mark = "  (already ahead of the pool)"
        else:
            mark = f"  +{c.exp_delta:,} xp"
            if c.level_delta:
                mark += f", +{c.level_delta} lv"
        print(
            f"{p.name:<16}{p.level:>7}{p.exp:>14,}  ->"
            f"{c.target_level:>7}{c.target_exp:>14,}{mark}"
        )
    print("-" * 74)
    print(f"pool ({plan.mode.value}): {plan.pool_exp:,} xp = level {plan.pool_level}")


def _print_tech(tplan) -> None:
    print(f"\n{'player':<16}{'unlocks':>18}{'points':>14}{'ancient':>14}")
    print("-" * 74)
    for c in tplan.changes:
        p = c.player
        have, want = len(p.unlocked), len(c.target_unlocked)
        unlocks = f"{have} -> {want}" if have != want else f"{have}"
        pts = (
            f"{p.points} -> {c.target_points}"
            if c.points_delta
            else f"{p.points}"
        )
        if c.target_boss_points is None:
            boss = "-"
        elif c.boss_delta:
            boss = f"{p.boss_points or 0} -> {c.target_boss_points}"
        else:
            boss = f"{p.boss_points or 0}"
        print(f"{p.name:<16}{unlocks:>18}{pts:>14}{boss:>14}")
    print("-" * 74)
    print(f"shared tech tree: {len(tplan.unlocked)} unlocks, {tplan.points} points", end="")
    print(f", {tplan.boss_points} ancient" if tplan.boss_points is not None else "")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="sharedxp", description=__doc__)
    ap.add_argument("command", choices=["report", "apply"])
    ap.add_argument("world", help="world save dir (the one containing Level.sav)")
    ap.add_argument("--table", default=str(DEFAULT_TABLE), help="exp table json")
    ap.add_argument("--mode", default="mean", choices=[m.value for m in Mode])
    ap.add_argument("--no-tech", action="store_true", help="pool XP only, leave tech alone")
    ap.add_argument("--yes", action="store_true", help="skip the apply confirmation")
    args = ap.parse_args(argv)

    world = Path(args.world)
    curve = ExpCurve.from_json(args.table)
    level_save = LevelSave.load(world)
    players = level_save.players()
    if not players:
        raise SystemExit("no players found in this save")

    plan = build_plan(players, curve, Mode(args.mode))
    print("=== shared xp pool ===")
    _print_xp(curve, players, plan)

    tplan = None
    psaves: dict[str, PlayerSave] = {}
    if not args.no_tech:
        psaves = PlayerSave.load_all(world)
        techs, missing = [], []
        for p in players:
            key = normalize_uid(p.uid)
            if key not in psaves:
                missing.append(p.name)
                continue
            pts, boss, unlocked = psaves[key].read_tech()
            techs.append(PlayerTech(uid=key, name=p.name, points=pts, boss_points=boss, unlocked=unlocked))
        print("\n=== shared tech tree ===")
        if missing:
            print(f"  ! no Players/ file for: {', '.join(missing)} (skipped)")
        if techs:
            tplan = build_tech_plan(techs)
            _print_tech(tplan)
        else:
            print("  no player files to sync")

    n_xp = len(plan.touched)
    n_tech = len(tplan.touched) if tplan else 0
    print(f"\nwould change: {n_xp} player(s) xp, {n_tech} player(s) tech")

    if args.command == "report":
        print("(report only - nothing was written)")
        return 0

    if not n_xp and not n_tech:
        print("nothing to do.")
        return 0

    if not args.yes:
        print(f"\nabout to rewrite saves under {world}")
        if input("type 'apply' to continue: ").strip() != "apply":
            print("aborted.")
            return 1

    print()
    if n_xp:
        print(f"backup: {level_save.backup().name}")
        targets = {c.player.uid: (c.target_level, c.target_exp) for c in plan.touched}
        level_save.apply(targets)
        level_save.save()
        print(f"wrote xp for {len(targets)} player(s)")

    if tplan and n_tech:
        for c in tplan.touched:
            ps = psaves[c.player.uid]
            print(f"backup: {ps.backup().name}")
            ps.write_tech(c.target_points, c.target_boss_points, c.target_unlocked)
            ps.save()
        print(f"wrote tech for {n_tech} player(s)")

    return _verify(world, plan, tplan, args)


def _verify(world, plan, tplan, args) -> int:
    """Re-read everything from disk and confirm the values actually landed."""
    bad = []

    fresh = {p.uid: p for p in LevelSave.load(world).players()}
    for c in plan.touched:
        got = fresh.get(c.player.uid)
        if got and (got.level != c.target_level or got.exp != c.target_exp):
            bad.append(
                f"{c.player.name}: wanted lv {c.target_level}/{c.target_exp:,}, "
                f"found lv {got.level}/{got.exp:,}"
            )

    if tplan and not args.no_tech:
        fresh_p = PlayerSave.load_all(world)
        for c in tplan.touched:
            ps = fresh_p.get(c.player.uid)
            if not ps:
                continue
            pts, boss, unlocked = ps.read_tech()
            if pts != c.target_points:
                bad.append(f"{c.player.name}: wanted {c.target_points} points, found {pts}")
            if set(unlocked) != set(c.target_unlocked):
                bad.append(
                    f"{c.player.name}: wanted {len(c.target_unlocked)} unlocks, "
                    f"found {len(unlocked)}"
                )
            if c.target_boss_points is not None and boss != c.target_boss_points:
                bad.append(
                    f"{c.player.name}: wanted {c.target_boss_points} ancient, found {boss}"
                )

    if bad:
        print("\nVERIFY FAILED:")
        for b in bad:
            print(f"  ! {b}")
        return 2
    print("verified: re-read from disk matches the plan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
