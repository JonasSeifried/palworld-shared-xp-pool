"""The .sav container: reading both compression formats, writing one of them.

Palworld 0.6 switched save compression from zlib to Oodle Kraken. The container
is otherwise unchanged -- 4 bytes uncompressed length, 4 bytes compressed
length, a 3-byte magic, a type byte, then the payload -- but the magic went from
`PlZ` to `PlM` and `palworld-save-tools` refuses anything it does not recognise.

Reading either format is easy. Writing Oodle is not: Oodle's compressor is
proprietary, and the open reimplementation everyone uses (libooz, via `pyooz`)
only decompresses. So a save read as `PlM` is written back as `PlZ`.

That relies on the game still accepting zlib saves. Two things say it does. The
shipping binary still carries the `PlZ` magic next to `PlM`, in both the read
and write paths. And Palworld had to keep the zlib path to migrate everyone's
pre-0.6 saves forward. Neither is proof -- the only proof is loading an edited
save in the game, which has not been done yet.
"""

from __future__ import annotations

import zlib
from dataclasses import dataclass

PLZ = b"PlZ"  # zlib, pre-0.6
PLM = b"PlM"  # Oodle Kraken, 0.6 onward
CNK = b"CNK"  # Xbox container, wraps a second header

SINGLE_ZLIB = 0x31
DOUBLE_ZLIB = 0x32

HEADER = 12


class CompressionError(Exception):
    pass


@dataclass(frozen=True)
class SaveFormat:
    """How a .sav was packed, and how we will pack it again."""

    magic: bytes
    save_type: int

    @property
    def is_oodle(self) -> bool:
        return self.magic == PLM


def _oodle_decompress(payload: bytes, expected: int) -> bytes:
    try:
        import ooz
    except ImportError:
        raise CompressionError(
            "this save is Oodle-compressed (Palworld 0.6+) and needs the ooz "
            "decompressor: pip install pyooz"
        ) from None
    return ooz.decompress(payload, expected)


def decompress_sav(data: bytes) -> tuple[bytes, SaveFormat]:
    """Unpack a .sav into its raw GVAS bytes."""
    if len(data) < HEADER:
        raise CompressionError("file is too short to be a Palworld save")

    offset = 0
    if data[8:11] == CNK:
        # Xbox writes its own header in front of the real one.
        offset = 12

    uncompressed_len = int.from_bytes(data[offset : offset + 4], "little")
    compressed_len = int.from_bytes(data[offset + 4 : offset + 8], "little")
    magic = data[offset + 8 : offset + 11]
    save_type = data[offset + 11]
    body = data[offset + HEADER :]

    if magic not in (PLZ, PLM):
        raise CompressionError(
            f"not a Palworld save: expected magic {PLZ!r} or {PLM!r}, found {magic!r}"
        )

    if magic == PLM:
        raw = _oodle_decompress(body, uncompressed_len)
    elif save_type == DOUBLE_ZLIB:
        raw = zlib.decompress(zlib.decompress(body))
    elif save_type == SINGLE_ZLIB:
        if compressed_len != len(body):
            raise CompressionError(
                f"truncated save: header says {compressed_len} compressed bytes, "
                f"file has {len(body)}"
            )
        raw = zlib.decompress(body)
    else:
        raise CompressionError(f"unknown zlib save type: 0x{save_type:02x}")

    if len(raw) != uncompressed_len:
        raise CompressionError(
            f"decompressed to {len(raw)} bytes, header says {uncompressed_len}"
        )

    return raw, SaveFormat(magic=magic, save_type=save_type)


def zlib_format_for(filename: str) -> SaveFormat:
    """The zlib packing Palworld itself used for a given file before 0.6.

    Level.sav was double-compressed and everything else single. Matching that
    exactly is free, and keeps a converted save looking like something the game
    wrote rather than something merely close enough.
    """
    save_type = DOUBLE_ZLIB if filename == "Level.sav" else SINGLE_ZLIB
    return SaveFormat(magic=PLZ, save_type=save_type)


def compress_sav(raw: bytes, fmt: SaveFormat) -> bytes:
    """Pack raw GVAS bytes back into a .sav.

    `fmt` must be a zlib format; an Oodle one has no compressor to call. Callers
    convert with `zlib_format_for` and tell the user what happened.
    """
    if fmt.is_oodle:
        raise CompressionError(
            "cannot write Oodle-compressed saves -- convert to zlib with "
            "zlib_format_for() first"
        )

    if fmt.save_type == DOUBLE_ZLIB:
        body = zlib.compress(zlib.compress(raw))
        # The middle length is the once-compressed size, not the file's.
        compressed_len = len(zlib.compress(raw))
    elif fmt.save_type == SINGLE_ZLIB:
        body = zlib.compress(raw)
        compressed_len = len(body)
    else:
        raise CompressionError(f"unknown zlib save type: 0x{fmt.save_type:02x}")

    return (
        len(raw).to_bytes(4, "little")
        + compressed_len.to_bytes(4, "little")
        + fmt.magic
        + bytes([fmt.save_type])
        + body
    )
