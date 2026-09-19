import pytest

from sharedxp.pool import Mode, Player, build_plan, pool_exp


class LinearCurve:
    """Stand-in curve for tests: 100 XP per level, level 1 at 0 XP."""

    def level_for_exp(self, exp: int) -> int:
        return exp // 100 + 1


CURVE = LinearCurve()


def mk(uid, level, exp):
    return Player(uid=uid, name=f"p{uid}", level=level, exp=exp)


def test_mean_floors_rather_than_rounding_up():
    players = [mk("a", 1, 0), mk("b", 1, 1), mk("c", 1, 1)]
    assert pool_exp(players, Mode.MEAN) == 0


def test_mean_of_uneven_group():
    players = [mk("a", 1, 0), mk("b", 3, 200), mk("c", 5, 400)]
    assert pool_exp(players, Mode.MEAN) == 200


def test_single_player_pool_is_that_player():
    assert pool_exp([mk("a", 7, 650)], Mode.MEAN) == 650


def test_empty_group_rejected():
    with pytest.raises(ValueError):
        pool_exp([], Mode.MEAN)


def test_negative_xp_rejected():
    with pytest.raises(ValueError):
        pool_exp([mk("a", 1, -5)], Mode.MEAN)


def test_nobody_is_ever_de_levelled():
    players = [mk("low", 1, 0), mk("high", 5, 400)]
    plan = build_plan(players, CURVE, Mode.MEAN)

    assert plan.pool_exp == 200
    by_uid = {c.player.uid: c for c in plan.changes}

    # the player behind is pulled up to the pool
    assert by_uid["low"].target_exp == 200
    assert by_uid["low"].level_delta > 0

    # the player ahead keeps everything and is left alone
    assert by_uid["high"].target_exp == 400
    assert by_uid["high"].changed is False


def test_no_change_when_everyone_is_already_level():
    players = [mk("a", 3, 250), mk("b", 3, 250)]
    plan = build_plan(players, CURVE, Mode.MEAN)
    assert plan.touched == ()


def test_level_never_drops_even_if_curve_disagrees():
    # a player whose stored level is ahead of what their XP implies
    # (hand-edited save, curve drift) must not be knocked back down
    players = [mk("odd", 40, 100), mk("b", 2, 100)]
    plan = build_plan(players, CURVE, Mode.MEAN)
    odd = next(c for c in plan.changes if c.player.uid == "odd")
    assert odd.target_level == 40


def test_max_mode_lifts_everyone_to_the_front_runner():
    players = [mk("a", 1, 0), mk("b", 5, 400)]
    plan = build_plan(players, CURVE, Mode.MAX)
    assert plan.pool_exp == 400
    assert all(c.target_exp == 400 for c in plan.changes)


def test_exp_delta_reports_the_gain():
    players = [mk("a", 1, 0), mk("b", 5, 400)]
    plan = build_plan(players, CURVE, Mode.MEAN)
    a = next(c for c in plan.changes if c.player.uid == "a")
    assert a.exp_delta == 200
