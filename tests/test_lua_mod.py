"""Run the live mod's Lua suite from pytest, so one command covers both halves.

The Lua tests stub out UE4SS and Palworld, so they need an interpreter but not
the game. Without Lua on PATH they skip rather than fail -- the save editor is
usable on its own and should not require a Lua install to test.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SUITE = ROOT / "tests" / "lua" / "test_pool.lua"


def _lua() -> str | None:
    for name in ("lua", "lua5.4", "lua54"):
        found = shutil.which(name)
        if found:
            return found
    return None


@pytest.mark.skipif(_lua() is None, reason="no lua interpreter on PATH")
def test_live_mod_lua_suite() -> None:
    result = subprocess.run(
        [_lua(), str(SUITE)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
