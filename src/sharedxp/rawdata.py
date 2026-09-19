"""Our own codec for the character blob in Level.sav.

Each entry in `CharacterSaveParameterMap` stores its character as an opaque byte
array: a run of normal GVAS properties followed by a fixed tail. The tail grew
in Palworld 0.6 -- it used to be 4 unknown bytes plus a 16-byte group id, and
now carries 4 more -- which is why `palworld-save-tools` raises "EOF not
reached" on a current save. Upstream has not shipped since October 2024, so
this is ours to handle.

Rather than name the tail's fields and break again the next time one is added,
this keeps everything after the properties as opaque bytes and writes it back
untouched. We only need Level and Exp, both of which are ordinary properties;
nothing else about the character has to be understood to preserve it exactly.

The same codec reads pre-0.6 saves, because a shorter tail is just a shorter
opaque run.
"""

from __future__ import annotations

from typing import Any

from palworld_save_tools.archive import FArchiveReader, FArchiveWriter

CHARACTER_PATH = ".worldSaveData.CharacterSaveParameterMap.Value.RawData"


def decode(reader: FArchiveReader, type_name: str, size: int, path: str) -> dict[str, Any]:
    if type_name != "ArrayProperty":
        raise Exception(f"expected ArrayProperty at {path}, got {type_name}")
    value = reader.property(type_name, size, path, nested_caller_path=path)
    blob = bytes(value["value"]["values"])

    inner = reader.internal_copy(blob, debug=False)
    obj = inner.properties_until_end()
    value["value"] = {"object": obj, "trailing": blob[inner.data.tell() :]}
    return value


def encode(writer: FArchiveWriter, property_type: str, properties: dict[str, Any]) -> int:
    if property_type != "ArrayProperty":
        raise Exception(f"expected ArrayProperty, got {property_type}")
    del properties["custom_type"]

    inner = FArchiveWriter()
    inner.properties(properties["value"]["object"])
    blob = inner.bytes() + properties["value"]["trailing"]

    properties["value"] = {"values": list(blob)}
    return writer.property_inner(property_type, properties)


# Only the character blob is decoded. Every other RawData in the save stays an
# opaque byte array and round-trips verbatim, which is safer than decoding it
# with a parser that predates this save format.
CUSTOM_PROPERTIES = {CHARACTER_PATH: (decode, encode)}


def read_level(save_parameter: dict[str, Any]) -> int:
    """Level, across both property shapes.

    Pre-0.6 it was an IntProperty holding the number directly. From 0.6 it is a
    ByteProperty, which nests the number one level deeper under an enum tag.
    """
    return _unwrap(save_parameter.get("Level"), default=1)


def read_exp(save_parameter: dict[str, Any]) -> int:
    """Exp. IntProperty before 0.6, Int64Property after; both hold a plain int."""
    return _unwrap(save_parameter.get("Exp"), default=0)


def write_level(save_parameter: dict[str, Any], level: int) -> None:
    _rewrap(save_parameter["Level"], level)


def write_exp(save_parameter: dict[str, Any], exp: int) -> None:
    _rewrap(save_parameter["Exp"], exp)


def _unwrap(prop: dict[str, Any] | None, default: int) -> int:
    if not prop:
        return default
    value = prop.get("value", default)
    if isinstance(value, dict):
        value = value.get("value", default)
    return value


def _rewrap(prop: dict[str, Any], number: int) -> None:
    """Set the number without disturbing the wrapper the save already uses."""
    if isinstance(prop.get("value"), dict):
        prop["value"]["value"] = number
    else:
        prop["value"] = number
