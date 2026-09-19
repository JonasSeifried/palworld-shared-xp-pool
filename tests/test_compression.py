"""The .sav container, both compression eras."""

import zlib

import pytest

from sharedxp.compression import (
    DOUBLE_ZLIB,
    PLM,
    PLZ,
    SINGLE_ZLIB,
    CompressionError,
    SaveFormat,
    compress_sav,
    decompress_sav,
    zlib_format_for,
)

PAYLOAD = b"GVAS" + b"pretend this is a save" * 64


def pack(raw: bytes, magic: bytes, save_type: int, body: bytes) -> bytes:
    return (
        len(raw).to_bytes(4, "little")
        + len(body).to_bytes(4, "little")
        + magic
        + bytes([save_type])
        + body
    )


@pytest.mark.parametrize("save_type", [SINGLE_ZLIB, DOUBLE_ZLIB])
def test_zlib_round_trips_byte_for_byte(save_type):
    fmt = SaveFormat(magic=PLZ, save_type=save_type)
    blob = compress_sav(PAYLOAD, fmt)
    back, back_fmt = decompress_sav(blob)
    assert back == PAYLOAD
    assert back_fmt == fmt


def test_level_sav_is_double_compressed_like_the_game_writes_it():
    assert zlib_format_for("Level.sav").save_type == DOUBLE_ZLIB
    assert zlib_format_for("LevelMeta.sav").save_type == SINGLE_ZLIB
    assert zlib_format_for("B7189712000000000000000000000000.sav").save_type == SINGLE_ZLIB
    assert zlib_format_for("Level.sav").magic == PLZ


def test_oodle_saves_are_recognised_as_oodle():
    assert SaveFormat(magic=PLM, save_type=0x31).is_oodle
    assert not SaveFormat(magic=PLZ, save_type=DOUBLE_ZLIB).is_oodle


def test_writing_oodle_is_refused_rather_than_guessed_at():
    # There is no open Oodle compressor, so this has to fail loudly instead of
    # quietly producing a file the game cannot read.
    with pytest.raises(CompressionError, match="cannot write Oodle"):
        compress_sav(PAYLOAD, SaveFormat(magic=PLM, save_type=0x31))


def test_an_unknown_magic_is_rejected():
    blob = pack(PAYLOAD, b"XXX", SINGLE_ZLIB, zlib.compress(PAYLOAD))
    with pytest.raises(CompressionError, match="not a Palworld save"):
        decompress_sav(blob)


def test_a_truncated_file_is_caught():
    body = zlib.compress(PAYLOAD)
    blob = pack(PAYLOAD, PLZ, SINGLE_ZLIB, body)[:-20]
    with pytest.raises(CompressionError, match="truncated"):
        decompress_sav(blob)


def test_a_wrong_uncompressed_length_is_caught():
    body = zlib.compress(PAYLOAD)
    blob = (
        (len(PAYLOAD) + 999).to_bytes(4, "little")
        + len(body).to_bytes(4, "little")
        + PLZ
        + bytes([SINGLE_ZLIB])
        + body
    )
    with pytest.raises(CompressionError, match="header says"):
        decompress_sav(blob)


def test_too_short_to_be_a_save():
    with pytest.raises(CompressionError, match="too short"):
        decompress_sav(b"Pl")
