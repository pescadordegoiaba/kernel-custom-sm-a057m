#!/usr/bin/env python3
"""Patch and verify a file in a newc/crc CPIO archive."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys


HEADER_SIZE = 110
FIELD_COUNT = 13
FILESIZE_INDEX = 6
NAMESIZE_INDEX = 11
CHECK_INDEX = 12
MAGICS = {b"070701", b"070702"}


def align4(value: int) -> int:
    return (value + 3) & ~3


def normalize(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/")


@dataclass(frozen=True)
class Record:
    start: int
    data_start: int
    data_end: int
    end: int
    magic: bytes
    fields: tuple[int, ...]
    name_bytes: bytes
    name: str
    data: bytes


@dataclass(frozen=True)
class Archive:
    raw: bytes
    records: tuple[Record, ...]
    tail: bytes


def parse_archive(raw: bytes) -> Archive:
    records: list[Record] = []
    offset = 0

    while True:
        start = offset
        header = raw[offset : offset + HEADER_SIZE]
        if len(header) != HEADER_SIZE:
            raise ValueError(f"truncated CPIO header at offset {offset}")

        magic = header[:6]
        if magic not in MAGICS:
            raise ValueError(f"invalid CPIO magic {magic!r} at offset {offset}")

        try:
            fields = tuple(
                int(header[6 + index * 8 : 14 + index * 8], 16)
                for index in range(FIELD_COUNT)
            )
        except ValueError as error:
            raise ValueError(f"invalid hexadecimal CPIO header at offset {offset}") from error

        offset += HEADER_SIZE
        name_size = fields[NAMESIZE_INDEX]
        if name_size < 1 or offset + name_size > len(raw):
            raise ValueError(f"invalid CPIO name size at offset {start}")

        name_field = raw[offset : offset + name_size]
        if name_field[-1:] != b"\0":
            raise ValueError(f"unterminated CPIO name at offset {start}")
        name_bytes = name_field[:-1]
        name = name_bytes.decode("utf-8", "surrogateescape")

        offset = align4(offset + name_size)
        data_start = offset
        data_end = data_start + fields[FILESIZE_INDEX]
        if data_end > len(raw):
            raise ValueError(f"truncated CPIO data for {name!r}")
        offset = align4(data_end)

        record = Record(
            start=start,
            data_start=data_start,
            data_end=data_end,
            end=offset,
            magic=magic,
            fields=fields,
            name_bytes=name_bytes,
            name=name,
            data=raw[data_start:data_end],
        )
        records.append(record)

        if name == "TRAILER!!!":
            return Archive(raw=raw, records=tuple(records), tail=raw[offset:])


def encode_field(value: int) -> bytes:
    if value < 0 or value > 0xFFFFFFFF:
        raise ValueError(f"CPIO field does not fit in 32 bits: {value}")
    return f"{value:08x}".encode("ascii")


def replace_file(archive: Archive, entry: str, payload: bytes) -> bytes:
    wanted = normalize(entry)
    matches = [record for record in archive.records if normalize(record.name) == wanted]
    if len(matches) != 1:
        raise ValueError(f"expected one {wanted!r} entry, found {len(matches)}")

    record = matches[0]
    prefix = bytearray(archive.raw[record.start : record.data_start])
    filesize_offset = 6 + FILESIZE_INDEX * 8
    check_offset = 6 + CHECK_INDEX * 8
    prefix[filesize_offset : filesize_offset + 8] = encode_field(len(payload))
    if record.magic == b"070702":
        prefix[check_offset : check_offset + 8] = encode_field(sum(payload) & 0xFFFFFFFF)

    data_padding = b"\0" * (align4(len(payload)) - len(payload))
    return (
        archive.raw[: record.start]
        + bytes(prefix)
        + payload
        + data_padding
        + archive.raw[record.end :]
    )


def verify_only_changes(stock: Archive, custom: Archive, allowed_entries: list[str]) -> None:
    allowed = {normalize(entry) for entry in allowed_entries}
    stock_names = [record.name for record in stock.records]
    custom_names = [record.name for record in custom.records]
    if stock_names != custom_names:
        raise ValueError("CPIO entry order or names changed")
    if stock.tail != custom.tail:
        raise ValueError("CPIO bytes after TRAILER!!! changed")

    seen: set[str] = set()
    for stock_record, custom_record in zip(stock.records, custom.records):
        name = normalize(stock_record.name)
        if stock_record.magic != custom_record.magic:
            raise ValueError(f"CPIO magic changed for {name!r}")
        if stock_record.name_bytes != custom_record.name_bytes:
            raise ValueError(f"CPIO name bytes changed for {name!r}")

        ignored_fields = {FILESIZE_INDEX, CHECK_INDEX} if name in allowed else set()
        for index, (stock_value, custom_value) in enumerate(
            zip(stock_record.fields, custom_record.fields)
        ):
            if index not in ignored_fields and stock_value != custom_value:
                raise ValueError(
                    f"CPIO metadata field {index} changed for {name!r}: "
                    f"{stock_value} != {custom_value}"
                )

        if name in allowed:
            seen.add(name)
        elif stock_record.data != custom_record.data:
            raise ValueError(f"CPIO payload changed for unauthorized entry {name!r}")

    missing = allowed - seen
    if missing:
        raise ValueError(f"allowed CPIO entries not found: {sorted(missing)!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    replace_parser = subparsers.add_parser("replace")
    replace_parser.add_argument("archive", type=Path)
    replace_parser.add_argument("entry")
    replace_parser.add_argument("payload", type=Path)
    replace_parser.add_argument("output", type=Path)

    verify_parser = subparsers.add_parser("verify-only-changes")
    verify_parser.add_argument("stock", type=Path)
    verify_parser.add_argument("custom", type=Path)
    verify_parser.add_argument("entries", nargs="+")

    args = parser.parse_args()
    try:
        if args.command == "replace":
            raw = args.archive.read_bytes()
            output = replace_file(parse_archive(raw), args.entry, args.payload.read_bytes())
            args.output.write_bytes(output)
        else:
            verify_only_changes(
                parse_archive(args.stock.read_bytes()),
                parse_archive(args.custom.read_bytes()),
                args.entries,
            )
    except (OSError, ValueError) as error:
        print(f"cpio_newc.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
