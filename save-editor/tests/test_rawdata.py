"""Level and Exp moved property types in Palworld 0.6; both shapes must work."""

from sharedxp.rawdata import read_exp, read_level, write_exp, write_level


def pre_06():
    """IntProperty for both -- the number sits directly under "value"."""
    return {
        "Level": {"id": None, "value": 22, "type": "IntProperty"},
        "Exp": {"id": None, "value": 64386, "type": "IntProperty"},
    }


def post_06():
    """ByteProperty nests the number under an enum tag; Exp widened to 64-bit."""
    return {
        "Level": {"id": None, "value": {"type": "None", "value": 18}, "type": "ByteProperty"},
        "Exp": {"id": None, "value": 43507, "type": "Int64Property"},
    }


def test_reads_the_old_shape():
    sp = pre_06()
    assert read_level(sp) == 22
    assert read_exp(sp) == 64386


def test_reads_the_new_shape():
    sp = post_06()
    assert read_level(sp) == 18
    assert read_exp(sp) == 43507


def test_writing_keeps_the_old_shape_intact():
    sp = pre_06()
    write_level(sp, 30)
    write_exp(sp, 99999)
    assert sp["Level"] == {"id": None, "value": 30, "type": "IntProperty"}
    assert sp["Exp"]["value"] == 99999


def test_writing_keeps_the_new_shape_intact():
    # The enum tag and the property type have to survive: rewriting Level as a
    # bare int would produce a file the game reads as a different property.
    sp = post_06()
    write_level(sp, 30)
    write_exp(sp, 99999)
    assert sp["Level"] == {
        "id": None,
        "value": {"type": "None", "value": 30},
        "type": "ByteProperty",
    }
    assert sp["Exp"] == {"id": None, "value": 99999, "type": "Int64Property"}


def test_written_values_read_back():
    for sp in (pre_06(), post_06()):
        write_level(sp, 42)
        write_exp(sp, 123456)
        assert read_level(sp) == 42
        assert read_exp(sp) == 123456


def test_missing_fields_fall_back_instead_of_crashing():
    assert read_level({}) == 1
    assert read_exp({}) == 0
