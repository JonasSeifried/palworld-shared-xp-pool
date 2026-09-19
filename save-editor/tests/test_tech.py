import pytest

from sharedxp.tech import PlayerTech, build_tech_plan


def mk(uid, points, boss, unlocked):
    return PlayerTech(uid=uid, name=uid, points=points, boss_points=boss, unlocked=tuple(unlocked))


def test_unlocks_are_unioned():
    plan = build_tech_plan([
        mk("a", 0, 0, ["Workbench", "HandTorch"]),
        mk("b", 0, 0, ["HandTorch", "Furnace"]),
    ])
    assert set(plan.unlocked) == {"Workbench", "HandTorch", "Furnace"}


def test_union_order_is_stable_first_seen():
    plan = build_tech_plan([
        mk("a", 0, 0, ["Workbench", "HandTorch"]),
        mk("b", 0, 0, ["Furnace", "Workbench"]),
    ])
    assert plan.unlocked == ("Workbench", "HandTorch", "Furnace")


def test_nobody_loses_an_unlock():
    a = mk("a", 0, 0, ["Workbench", "HandTorch", "Furnace"])
    plan = build_tech_plan([a, mk("b", 0, 0, ["Workbench"])])
    for c in plan.changes:
        assert set(c.player.unlocked) <= set(c.target_unlocked)


def test_points_rise_to_the_highest_balance():
    plan = build_tech_plan([mk("a", 49, 0, []), mk("b", 7, 0, []), mk("c", 50, 0, [])])
    assert plan.points == 50
    assert all(c.target_points == 50 for c in plan.changes)


def test_points_are_never_lowered():
    plan = build_tech_plan([mk("rich", 999, 0, []), mk("poor", 1, 0, [])])
    rich = next(c for c in plan.changes if c.player.uid == "rich")
    assert rich.target_points == 999


def test_boss_points_ignore_players_missing_the_field():
    # HenBot's save has no bossTechnologyPoint at all -- None, not zero
    plan = build_tech_plan([mk("a", 0, 9, []), mk("b", 0, None, []), mk("c", 0, 3, [])])
    assert plan.boss_points == 9
    assert all(c.target_boss_points == 9 for c in plan.changes)


def test_boss_field_stays_absent_when_nobody_has_it():
    plan = build_tech_plan([mk("a", 0, None, []), mk("b", 0, None, [])])
    assert plan.boss_points is None
    assert all(c.target_boss_points is None for c in plan.changes)


def test_added_lists_only_the_new_ones():
    plan = build_tech_plan([
        mk("a", 0, 0, ["Workbench"]),
        mk("b", 0, 0, ["Furnace", "HandTorch"]),
    ])
    a = next(c for c in plan.changes if c.player.uid == "a")
    assert a.added == ("Furnace", "HandTorch")


def test_identical_players_are_untouched():
    plan = build_tech_plan([mk("a", 5, 2, ["Workbench"]), mk("b", 5, 2, ["Workbench"])])
    assert plan.touched == ()


def test_empty_rejected():
    with pytest.raises(ValueError):
        build_tech_plan([])


def test_negative_points_rejected():
    with pytest.raises(ValueError):
        build_tech_plan([mk("a", -1, 0, [])])
