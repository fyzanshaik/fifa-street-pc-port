#!/usr/bin/env python3
"""Add a macOS-port credit line to FIFA Street's own menu textures.

The press-start and main-menu screens already carry the upstream
"PORTED BY: SAMUELIT0DAVILA" credit baked into their own textures. This tool
draws one extra line, "macOS port: fyzanshaik", into those same textures, below
the existing credit. Because it edits the menu textures it scales with them,
appears only on those screens and never during gameplay.

The assets live in the owner's data1.big as BIG4 archives. Each target entry is
a nested BIGF whose texture is an XPR2 container holding a Xenos-tiled DXT5
(BC3) image. The XPR2 header carries the Xenos texture fetch constant, which
states the format (k_DXT4_5) and the GPU endian mode (k8in16 here, meaning the
stored blocks are byte-swapped in 16-bit half-words relative to the natural BC3
layout). The patcher decodes blocks through that endian transform, re-encodes
only the 16-byte BC3 blocks the new line actually touches and writes the
transformed bytes back, so every other block keeps its exact original bytes and
the existing logo and credit are untouched.

Nothing is written into the original GameData. `build-profile` validates the
source, then builds a preservation profile: a fresh owned directory holding
symlinks to every unrelated original file plus an APFS copy-on-write clone of
data1.big, edits only inside that clone and atomically publishes the finished
profile. The real game data is never opened for writing.

The text mask is generated from a built-in bitmap font, so the output is
deterministic on any machine and does not depend on the host OS or installed
fonts. Applying is idempotent: rebuilding a profile from an unchanged source
yields byte-identical bytes.

Run with --help for usage. The module is import-safe so focused tests can drive
the primitives on synthetic fixtures without any game data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

BIG_MAGIC = (b"BIG4", b"BIGF")
XPR2_MAGIC = b"XPR2"
FETCH_CONSTANT_SIZE = 24  # xenos::xe_gpu_texture_fetch_t, six dwords
BC3_BLOCK = 16
TILE_BLOCKS = 32

# Xenos enumerations (ReXGlue include/rex/graphics/xenos.h).
FETCH_TYPE_TEXTURE = 2
FORMAT_DXT4_5 = 20
DIMENSION_2D = 1
ENDIAN_NONE = 0
ENDIAN_8IN16 = 1
ENDIAN_8IN32 = 2
ENDIAN_16IN32 = 3

TEXT = "macOS port: fyzanshaik"
TEXT_COLOR = (204, 204, 204, 255)

PROFILE_MARKER = "macos-credits-profile.json"
PROFILE_VERSION = 1

# Target definitions pinned to the supported revision. `source_sha256` is the
# SHA-256 of the outer data1.big entry (the nested BIGF) in the original game
# data; `applied_sha256` is that same entry after this tool's edit. A source
# hash mismatch means the data is not the revision these offsets were validated
# against, so we refuse rather than guess. `text_height` is the mask height in
# texels; `text_xy` is the top-left origin of that mask.
TARGETS = (
    {
        "outer": "data/ui/game/screens/bootflow/03_pressstart.big",
        "inner": "5",
        "width": 1024,
        "height": 128,
        "source_sha256": "102341e011b50164b5c58673d04850ef510d13dd18e7cdc795ce2144186a4601",
        "applied_sha256": "7f6e5e12149199507f91f4d93e1c85da8c00410375de3ecb5d838accf8cd6b14",
        "text_xy": (173, 116),
        "text_height": 9,
    },
    {
        "outer": "data/ui/game/screens/menus/mainmenu.big",
        "inner": "8",
        "width": 2048,
        "height": 1024,
        "source_sha256": "aab5097fc96d98d8899a53826b0fd37f93736bed002824390e21cccd864689a1",
        "applied_sha256": "9e8d484d9122506b2ff31be939a77776f3f8ac46b7990329c4c1cc95bddc2526",
        "text_xy": (163, 686),
        "text_height": 17,
    },
)


class CreditPatchError(Exception):
    """Raised for any unsupported, malformed or unexpected input."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --- archive primitives -----------------------------------------------------


def _u32be(data: bytes, offset: int) -> int:
    if offset + 4 > len(data):
        raise CreditPatchError("truncated 32-bit field")
    return struct.unpack_from(">I", data, offset)[0]


def parse_big_directory(header: bytes, file_length: int):
    """Parse a BIG4/BIGF inline directory into [(name, offset, length)]."""
    if len(header) < 16 or header[:4] not in BIG_MAGIC:
        raise CreditPatchError("unsupported BIG archive")
    count = _u32be(header, 8)
    table_end = _u32be(header, 12)
    if count > 200000 or table_end > len(header) or table_end < 16:
        raise CreditPatchError("invalid BIG directory")
    entries = []
    pos = 16
    for _ in range(count):
        if pos + 8 >= table_end:
            raise CreditPatchError("truncated BIG directory")
        offset = _u32be(header, pos)
        length = _u32be(header, pos + 4)
        zero = header.find(b"\x00", pos + 8, table_end)
        if zero < 0 or offset < table_end or offset + length > file_length:
            raise CreditPatchError("invalid BIG entry")
        name = header[pos + 8:zero].decode("utf-8", "replace")
        entries.append((name, offset, length))
        pos = zero + 1
    return entries


def read_data1(data1_path: str):
    """Return (directory_bytes, entries) for a data1.big."""
    with open(data1_path, "rb") as handle:
        header = handle.read(16)
        if len(header) != 16:
            raise CreditPatchError("data1.big is too small")
        table_end = _u32be(header, 12)
        if table_end > 8 * 1024 * 1024:
            raise CreditPatchError("invalid data1 directory size")
        handle.seek(0)
        directory = handle.read(table_end)
    entries = parse_big_directory(directory, os.path.getsize(data1_path))
    return directory, entries


def parse_bigf(data: bytes):
    return parse_big_directory(data, len(data))


def inner_entry(bigf: bytes, name: str):
    for entry_name, offset, length in parse_bigf(bigf):
        if entry_name == name:
            return offset, length
    raise CreditPatchError(f"missing inner asset {name!r}")


# --- endian transform -------------------------------------------------------


def endian_transform(block: bytes, endian: int) -> bytes:
    """Apply the Xenos GPU endian swap to one BC3 block.

    ReXGlue's texture_conversion::CopySwapBlock swaps the stored bytes so the
    natural (PC-order) BC3 layout can be decoded. k8in16 swaps bytes inside
    each 16-bit half-word, which is the mode this game's menu textures declare.
    The transform is an involution: applying it toggles between guest bytes and
    natural bytes.
    """
    if endian == ENDIAN_NONE:
        return bytes(block)
    view = bytearray(block)
    if endian == ENDIAN_8IN16:
        for i in range(0, len(view) - 1, 2):
            view[i], view[i + 1] = view[i + 1], view[i]
    elif endian == ENDIAN_8IN32:
        for i in range(0, len(view) - 3, 4):
            view[i], view[i + 1], view[i + 2], view[i + 3] = (
                view[i + 3], view[i + 2], view[i + 1], view[i])
    elif endian == ENDIAN_16IN32:
        for i in range(0, len(view) - 3, 4):
            view[i], view[i + 1], view[i + 2], view[i + 3] = (
                view[i + 2], view[i + 3], view[i], view[i + 1])
    else:
        raise CreditPatchError(f"unsupported GPU endian mode {endian}")
    return bytes(view)


# --- BC3 (DXT5) -------------------------------------------------------------


def _rgb565(color):
    return ((color[0] >> 3) << 11) | ((color[1] >> 2) << 5) | (color[2] >> 3)


def _from565(c):
    r = (c >> 11) & 0x1F
    g = (c >> 5) & 0x3F
    b = c & 0x1F
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def _color_palette(c0: int, c1: int):
    """The four-entry BC3 color palette.

    Unlike BC1/DXT1, the BC3 color block always uses all four palette entries
    regardless of whether c0 > c1; it never trades the third entry for
    transparency.
    """
    ca, cb = _from565(c0), _from565(c1)
    return [ca, cb,
            tuple((2 * ca[i] + cb[i]) // 3 for i in range(3)),
            tuple((ca[i] + 2 * cb[i]) // 3 for i in range(3))]


def _alpha_palette(a0: int, a1: int):
    if a0 > a1:
        return [a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
    return [a0, a1, (4 * a0 + a1) // 5, (3 * a0 + 2 * a1) // 5,
            (2 * a0 + 3 * a1) // 5, (a0 + 4 * a1) // 5, 0, 255]


def decode_bc3_block(block: bytes):
    """Decode one natural-layout BC3 block to 16 (r, g, b, a) tuples."""
    if len(block) != BC3_BLOCK:
        raise CreditPatchError("BC3 block must be 16 bytes")
    alphas = _alpha_palette(block[0], block[1])
    abits = int.from_bytes(block[2:8], "little")
    c0, c1 = struct.unpack_from("<HH", block, 8)
    cbits = struct.unpack_from("<I", block, 12)[0]
    colors = _color_palette(c0, c1)
    return [(*colors[(cbits >> (2 * i)) & 3], alphas[(abits >> (3 * i)) & 7])
            for i in range(16)]


def encode_bc3_block(pixels) -> bytes:
    """Encode 16 (r, g, b, a) tuples to one natural-layout BC3 block."""
    if len(pixels) != 16:
        raise CreditPatchError("BC3 block needs 16 pixels")

    alphas = [p[3] for p in pixels]
    a_hi, a_lo = max(alphas), min(alphas)
    if a_hi == a_lo:
        alpha_palette = [a_hi] * 8
    else:
        alpha_palette = _alpha_palette(a_hi, a_lo)
    abits = 0
    for i, a in enumerate(alphas):
        best = min(range(8), key=lambda k: (abs(alpha_palette[k] - a), k))
        abits |= best << (3 * i)
    alpha_bytes = bytes([a_hi, a_lo]) + abits.to_bytes(6, "little")

    def luma(p):
        return p[0] * 299 + p[1] * 587 + p[2] * 114

    c0, c1 = _rgb565(max(pixels, key=luma)[:3]), _rgb565(min(pixels, key=luma)[:3])
    colors = _color_palette(c0, c1)
    cbits = 0
    for i, p in enumerate(pixels):
        best = min(range(4), key=lambda k: (
            (colors[k][0] - p[0]) ** 2 + (colors[k][1] - p[1]) ** 2
            + (colors[k][2] - p[2]) ** 2, k))
        cbits |= best << (2 * i)
    return alpha_bytes + struct.pack("<HHI", c0, c1, cbits)


# --- XPR2 / Xenos tiling ----------------------------------------------------


def parse_fetch_constant(data: bytes) -> dict:
    """Decode the 24-byte Xenos texture fetch constant embedded in an XPR2."""
    if len(data) < FETCH_CONSTANT_SIZE:
        raise CreditPatchError("truncated texture fetch constant")
    d0, d1, d2, _d3, _d4, d5 = struct.unpack_from(">6I", data, 0)
    return {
        "type": d0 & 0x3,
        "tiled": (d0 >> 31) & 1,
        "pitch_px": ((d0 >> 22) & 0x1FF) * TILE_BLOCKS,
        "format": d1 & 0x3F,
        "endian": (d1 >> 6) & 0x3,
        "base_address": (d1 >> 12) & 0xFFFFF,
        "width": (d2 & 0x1FFF) + 1,
        "height": ((d2 >> 13) & 0x1FFF) + 1,
        "stack_depth": (d2 >> 26) & 0x3F,
        "dimension": (d5 >> 9) & 0x3,
    }


def xpr2_info(texture: bytes) -> dict:
    """Return the texture geometry and fetch semantics from an XPR2 container.

    The fetch constant sits immediately before the texture data. Its two-d
    size fields are stored as (value - 1), so width/height are recovered with
    +1; the data length in the header must agree with width * height bytes for
    a DXT5 image (one byte per texel).
    """
    if len(texture) < 4 or texture[:4] != XPR2_MAGIC:
        raise CreditPatchError("unsupported texture container")
    if len(texture) < FETCH_CONSTANT_SIZE:
        raise CreditPatchError("texture container is too small")
    data_size = _u32be(texture, 8)
    data_offset = len(texture) - data_size
    if data_offset < FETCH_CONSTANT_SIZE or data_offset % 4 != 0:
        raise CreditPatchError("texture data offset is not sane")
    fetch = parse_fetch_constant(texture[data_offset - FETCH_CONSTANT_SIZE:data_offset])
    if fetch["type"] != FETCH_TYPE_TEXTURE or fetch["tiled"] != 1:
        raise CreditPatchError("texture is not a tiled texture fetch")
    if fetch["format"] != FORMAT_DXT4_5:
        raise CreditPatchError(f"unsupported texture format {fetch['format']}")
    if fetch["dimension"] != DIMENSION_2D:
        raise CreditPatchError("texture is not two-dimensional")
    if fetch["endian"] not in (ENDIAN_NONE, ENDIAN_8IN16, ENDIAN_8IN32, ENDIAN_16IN32):
        raise CreditPatchError(f"unsupported GPU endian mode {fetch['endian']}")
    width, height = fetch["width"], fetch["height"]
    if data_size != width * height:
        raise CreditPatchError("texture length and data size disagree")
    if fetch["pitch_px"] < width or fetch["pitch_px"] % 4 != 0:
        raise CreditPatchError("unexpected texture pitch")
    return {
        "width": width,
        "height": height,
        "data_offset": data_offset,
        "data_size": data_size,
        "pitch_blocks": fetch["pitch_px"] // 4,
        "format": fetch["format"],
        "endian": fetch["endian"],
    }


def tiled_offset(bx: int, by: int, pitch_blocks: int, log2_bpp: int) -> int:
    """Xenos 2D tiled byte offset of block (bx, by).

    Port of ReXGlue's texture_util::GetTiledOffset2D (originating from crunch);
    used with coordinates in blocks and the pitch in blocks.
    """
    pitch = (pitch_blocks + TILE_BLOCKS - 1) // TILE_BLOCKS * TILE_BLOCKS
    macro = ((bx >> 5) + (by >> 5) * (pitch >> 5)) << (log2_bpp + 7)
    micro = ((bx & 7) + ((by & 0xE) << 2)) << log2_bpp
    offset = macro + ((micro & ~0xF) << 1) + (micro & 0xF) + ((by & 1) << 4)
    return (((offset & ~0x1FF) << 3) + ((by & 16) << 7) + ((offset & 0x1C0) << 2)
            + (((((by & 8) >> 2) + (bx >> 3)) & 3) << 6) + (offset & 0x3F))


# --- deterministic text mask ------------------------------------------------


# A built-in 5x7 bitmap font. Only the characters this credit line needs are
# defined; a missing glyph is a hard error rather than a silent fallback. The
# font is part of this repository, so the mask does not depend on the host OS,
# CoreText or any installed font.
_GLYPHS = {
    " ": (".....", ".....", ".....", ".....", ".....", ".....", "....."),
    ":": (".....", "..#..", "..#..", ".....", "..#..", "..#..", "....."),
    "O": (".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
    "S": (".####", "#....", "#....", ".###.", "....#", "....#", "####."),
    "a": (".....", ".....", ".###.", "....#", ".####", "#...#", ".####"),
    "c": (".....", ".....", ".####", "#....", "#....", "#....", ".####"),
    "f": ("...##", "..#..", "..#..", "#####", "..#..", "..#..", "..#.."),
    "h": ("#....", "#....", "#.##.", "##..#", "#...#", "#...#", "#...#"),
    "i": ("..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."),
    "k": ("#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."),
    "m": (".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"),
    "n": (".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"),
    "o": (".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."),
    "p": (".....", ".....", "####.", "#...#", "####.", "#....", "#...."),
    "r": (".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."),
    "s": (".....", ".....", ".####", "#....", ".###.", "....#", "####."),
    "t": (".....", ".#...", ".#...", "####.", ".#...", ".#..#", "..##."),
    "y": (".....", ".....", "#...#", "#...#", ".####", "....#", ".###."),
    "z": (".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"),
}

_GLYPH_HEIGHT = 7
_GLYPH_ADVANCE = 6  # five columns plus one blank separator


def _text_bitmap(text: str):
    rows = [""] * _GLYPH_HEIGHT
    for ch in text:
        if ch not in _GLYPHS:
            raise CreditPatchError(f"no built-in glyph for {ch!r}")
        for y in range(_GLYPH_HEIGHT):
            rows[y] += _GLYPHS[ch][y] + "."
    return len(rows[0]) - 1, [row[:-1] for row in rows]


def render_text_mask(text: str, height: int, supersample: int = 4):
    """Rasterise `text` to an anti-aliased 8-bit coverage mask of the given
    pixel height. Deterministic: same inputs always give the same bytes.
    """
    if height < _GLYPH_HEIGHT:
        raise CreditPatchError("text height is too small")
    if supersample < 1:
        raise CreditPatchError("supersample must be positive")
    base_w, rows = _text_bitmap(text)
    scale = height / _GLYPH_HEIGHT
    out_w = max(1, round(base_w * scale))
    out_h = height
    mask = bytearray(out_w * out_h)
    samples = supersample * supersample
    for oy in range(out_h):
        for ox in range(out_w):
            hits = 0
            for sy in range(supersample):
                by = int((oy + (sy + 0.5) / supersample) / scale)
                if by < 0 or by >= _GLYPH_HEIGHT:
                    continue
                row = rows[by]
                for sx in range(supersample):
                    bx = int((ox + (sx + 0.5) / supersample) / scale)
                    if 0 <= bx < base_w and row[bx] == "#":
                        hits += 1
            mask[oy * out_w + ox] = hits * 255 // samples
    return out_w, out_h, bytes(mask)


# --- per-target edit --------------------------------------------------------


def decode_texture(texture: bytes, width: int, height: int, pitch_blocks: int,
                   endian: int) -> bytes:
    """Decode a whole Xenos-tiled BC3 texture to RGBA bytes (natural order)."""
    rgba = bytearray(width * height * 4)
    for by in range(height // 4):
        for bx in range(pitch_blocks):
            offset = tiled_offset(bx, by, pitch_blocks, 4)
            block = endian_transform(texture[offset:offset + BC3_BLOCK], endian)
            pixels = decode_bc3_block(block)
            for i, (r, g, b, a) in enumerate(pixels):
                px = bx * 4 + (i % 4)
                py = by * 4 + (i // 4)
                if px >= width or py >= height:
                    continue
                base = (py * width + px) * 4
                rgba[base:base + 4] = bytes((r, g, b, a))
    return bytes(rgba)


def patch_texture(texture: bytes, width: int, height: int, pitch_blocks: int,
                  endian: int, mask_crop, origin):
    """Return a copy of `texture` with `mask_crop` drawn at `origin`.

    Only BC3 blocks touched by the mask are re-encoded; all other blocks keep
    their original bytes. Returns (patched_bytes, changed).
    """
    mask_w, mask_h, mask = mask_crop
    x0, y0 = origin
    if x0 < 0 or y0 < 0 or x0 + mask_w > width or y0 + mask_h > height:
        raise CreditPatchError("text mask falls outside the texture")
    first_bx, last_bx = x0 // 4, (x0 + mask_w - 1) // 4
    first_by, last_by = y0 // 4, (y0 + mask_h - 1) // 4
    result = bytearray(texture)
    changed = False
    for by in range(first_by, last_by + 1):
        for bx in range(first_bx, last_bx + 1):
            offset = tiled_offset(bx, by, pitch_blocks, 4)
            original = texture[offset:offset + BC3_BLOCK]
            pixels = decode_bc3_block(endian_transform(original, endian))
            block_x, block_y = bx * 4, by * 4
            rgba = bytearray(4 * 16)
            for i, (r, g, b, a) in enumerate(pixels):
                rgba[i * 4:i * 4 + 4] = bytes((r, g, b, a))
            for py in range(4):
                ty = block_y + py
                if ty < y0 or ty >= y0 + mask_h:
                    continue
                for px in range(4):
                    tx = block_x + px
                    if tx < x0 or tx >= x0 + mask_w:
                        continue
                    coverage = mask[(ty - y0) * mask_w + (tx - x0)]
                    if coverage == 0:
                        continue
                    idx = (py * 4 + px) * 4
                    rgba[idx] = (rgba[idx] * (255 - coverage)
                                 + TEXT_COLOR[0] * coverage) // 255
                    rgba[idx + 1] = (rgba[idx + 1] * (255 - coverage)
                                     + TEXT_COLOR[1] * coverage) // 255
                    rgba[idx + 2] = (rgba[idx + 2] * (255 - coverage)
                                     + TEXT_COLOR[2] * coverage) // 255
                    rgba[idx + 3] = max(rgba[idx + 3], coverage)
            tile = [tuple(rgba[i * 4:i * 4 + 4]) for i in range(16)]
            encoded = endian_transform(encode_bc3_block(tile), endian)
            if encoded != original:
                changed = True
            result[offset:offset + BC3_BLOCK] = encoded
    return bytes(result), changed


# --- target location --------------------------------------------------------


def locate_target(data1_path: str, target) -> dict:
    """Validate one target entry and return its geometry and byte location."""
    _, entries = read_data1(data1_path)
    matches = [e for e in entries if e[0] == target["outer"]]
    if len(matches) != 1:
        raise CreditPatchError(f"expected exactly one {target['outer']!r} entry")
    _, outer_offset, outer_length = matches[0]
    with open(data1_path, "rb") as handle:
        handle.seek(outer_offset)
        bigf = handle.read(outer_length)
    digest = sha256(bigf)
    if digest == target.get("applied_sha256"):
        state = "applied"
    elif digest == target["source_sha256"]:
        state = "source"
    elif target.get("applied_sha256") is None:
        # Synthetic fixtures without a pinned applied hash: accept any other
        # digest as a modified build so profile verification can proceed.
        state = "modified"
    else:
        raise CreditPatchError(
            f"{target['outer']} is not the supported revision; refusing")
    texture_offset, texture_length = inner_entry(bigf, target["inner"])
    texture = bigf[texture_offset:texture_offset + texture_length]
    info = xpr2_info(texture)
    if (info["width"], info["height"]) != (target["width"], target["height"]):
        raise CreditPatchError(
            f"{target['outer']} texture is {info['width']}x{info['height']}, "
            f"expected {target['width']}x{target['height']}")
    return {
        "state": state,
        "texture_abs": outer_offset + texture_offset + info["data_offset"],
        "data_size": info["data_size"],
        "width": info["width"],
        "height": info["height"],
        "pitch_blocks": info["pitch_blocks"],
        "format": info["format"],
        "endian": info["endian"],
    }


def plan_target(data1_path: str, target):
    """Return (located, original_bytes, patched_bytes, changed)."""
    located = locate_target(data1_path, target)
    with open(data1_path, "rb") as handle:
        handle.seek(located["texture_abs"])
        original = handle.read(located["data_size"])
    if located["state"] == "applied":
        return located, original, original, False
    mask = render_text_mask(TEXT, target["text_height"])
    patched, changed = patch_texture(
        original, located["width"], located["height"], located["pitch_blocks"],
        located["endian"], mask, target["text_xy"])
    return located, original, patched, changed


# --- profile build ----------------------------------------------------------


def default_gamedata() -> str:
    """Resolve the current app's GameData link, or '' if none is available."""
    root = os.environ.get("FIFA_BUILD_ROOT") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "macos")
    candidates = (
        os.path.join(root, "out", "FIFA Street.app", "Contents", "MacOS", "GameData"),
        os.path.join(os.path.expanduser("~"), "Applications", "FIFA Street.app",
                     "Contents", "MacOS", "GameData"),
    )
    for candidate in candidates:
        if os.path.isdir(candidate):
            return os.path.realpath(candidate)
    return ""


def _canonical(path: str) -> str:
    """Absolute, symlink-resolved path; tolerates missing leaf components."""
    path = os.path.abspath(path)
    parent, leaf = os.path.split(path)
    if os.path.exists(path):
        return os.path.realpath(path)
    return os.path.join(os.path.realpath(parent), leaf)


def profile_marker(dest: str) -> str:
    return os.path.join(dest, PROFILE_MARKER)


def is_valid_profile(dest: str) -> bool:
    marker = profile_marker(dest)
    if not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return False
    return (data.get("tool") == "macos_credit_patch"
            and data.get("version") == PROFILE_VERSION
            and os.path.isfile(os.path.join(dest, "data1.big")))


def _check_destination(source: str, dest: str) -> None:
    """Refuse unsafe profile destinations before any filesystem change."""
    if os.path.islink(dest):
        raise CreditPatchError(f"profile path is a symlink; refusing: {dest}")
    if os.path.exists(dest):
        if not os.path.isdir(dest):
            raise CreditPatchError(f"profile path exists and is not a directory: {dest}")
        if not is_valid_profile(dest):
            raise CreditPatchError(
                "existing directory is not a mac-credits profile; refusing to "
                f"overwrite it: {dest}")
    source_real = os.path.realpath(source)
    dest_real = _canonical(dest)
    if dest_real == source_real:
        raise CreditPatchError("profile path is the source GameData")
    if dest_real.startswith(source_real + os.sep):
        raise CreditPatchError("profile path is inside the source GameData")
    if source_real.startswith(dest_real + os.sep):
        raise CreditPatchError("profile path contains the source GameData")


def _clone_file(source: str, dest: str) -> None:
    """APFS copy-on-write clone when available, else a plain copy."""
    result = subprocess.run(["cp", "-c", source, dest],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        shutil.copyfile(source, dest)


def _populate_profile(staging: str, source: str) -> None:
    for name in sorted(os.listdir(source)):
        if name == "data1.big":
            continue
        os.symlink(os.path.join(source, name), os.path.join(staging, name))
    _clone_file(os.path.join(source, "data1.big"), os.path.join(staging, "data1.big"))


def _publish(staging: str, dest: str) -> None:
    """Replace `dest` with the finished `staging` directory, keeping a rollback."""
    parent = os.path.dirname(dest)
    backup = None
    if os.path.exists(dest):
        backup = tempfile.mkdtemp(dir=parent, prefix=".macos-credits-old-")
        os.rmdir(backup)
        os.rename(dest, backup)
    try:
        os.rename(staging, dest)
    except OSError:
        if backup is not None:
            os.rename(backup, dest)
        raise
    if backup is not None:
        shutil.rmtree(backup, ignore_errors=True)


def _entry_bytes(data1_path: str, outer_name: str) -> bytes:
    _, entries = read_data1(data1_path)
    matches = [e for e in entries if e[0] == outer_name]
    if len(matches) != 1:
        raise CreditPatchError(f"expected exactly one {outer_name!r} entry")
    _, offset, length = matches[0]
    with open(data1_path, "rb") as handle:
        handle.seek(offset)
        return handle.read(length)


def _verify_profile(dest: str) -> None:
    data1 = os.path.join(dest, "data1.big")
    for target in TARGETS:
        located = locate_target(data1, target)
        if located["state"] == "source":
            raise CreditPatchError(
                f"{target['outer']} was not updated in the built profile")


def build_profile(source: str, dest: str, dry_run: bool = False) -> str:
    if not source:
        raise CreditPatchError("no --gamedata given and no app GameData link found")
    source = os.path.realpath(source)
    data1 = os.path.join(source, "data1.big")
    if not os.path.isfile(data1):
        raise CreditPatchError(f"no data1.big under {source}")

    # Validate the whole source and compute the patched bytes before touching
    # any filesystem, so a malformed source aborts with nothing created.
    plans = []
    for target in TARGETS:
        located, original, patched, changed = plan_target(data1, target)
        if located["state"] == "applied":
            raise CreditPatchError(f"{target['outer']} already carries the credit")
        if not changed:
            raise CreditPatchError(f"{target['outer']} was not modified by the mask")
        plans.append((target, located, patched))

    _check_destination(source, dest)
    if dry_run:
        return (f"Would build a {len(plans)}-target mac-credits profile at {dest} "
                f"from {source}")

    dest = os.path.abspath(dest)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    staging = tempfile.mkdtemp(dir=parent, prefix=".macos-credits-build-")
    os.chmod(staging, 0o755)
    try:
        _populate_profile(staging, source)
        with open(os.path.join(staging, "data1.big"), "r+b") as handle:
            for _target, located, patched in plans:
                handle.seek(located["texture_abs"])
                handle.write(patched)
            handle.flush()
            os.fsync(handle.fileno())
        _verify_profile(staging)
        staged_data1 = os.path.join(staging, "data1.big")
        marker = {
            "tool": "macos_credit_patch",
            "version": PROFILE_VERSION,
            "source": source,
            "text": TEXT,
            "targets": [
                {"outer": target["outer"], "inner": target["inner"],
                 "width": target["width"], "height": target["height"],
                 "applied_sha256": sha256(_entry_bytes(staged_data1, target["outer"]))}
                for target in TARGETS
            ],
        }
        with open(os.path.join(staging, PROFILE_MARKER), "w", encoding="utf-8") as handle:
            json.dump(marker, handle, indent=2, sort_keys=True)
            handle.write("\n")
        _publish(staging, dest)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return f"Built mac-credits profile at {dest}"


def check(source: str) -> str:
    if not source:
        raise CreditPatchError("no --gamedata given and no app GameData link found")
    source = os.path.realpath(source)
    data1 = os.path.join(source, "data1.big")
    if not os.path.isfile(data1):
        raise CreditPatchError(f"no data1.big under {source}")
    lines = []
    for target in TARGETS:
        located = locate_target(data1, target)
        lines.append(
            f"{target['outer']}: {located['width']}x{located['height']} "
            f"format={located['format']} endian={located['endian']} "
            f"pitch={located['pitch_blocks']} blocks, data={located['data_size']} "
            f"bytes, state={located['state']}")
    return "\n".join(lines)


# --- preview ----------------------------------------------------------------


def _write_png(path: str, width: int, height: int, rgba: bytes) -> None:
    import zlib

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * width * 4:(y + 1) * width * 4]

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def preview(source: str, out_dir: str) -> str:
    if not source:
        raise CreditPatchError("no --gamedata given and no app GameData link found")
    source = os.path.realpath(source)
    data1 = os.path.join(source, "data1.big")
    if not os.path.isfile(data1):
        raise CreditPatchError(f"no data1.big under {source}")
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for target in TARGETS:
        located, original, patched, _changed = plan_target(data1, target)
        stem = os.path.basename(target["outer"]).removesuffix(".big")
        for label, texture in (("before", original), ("after", patched)):
            rgba = decode_texture(texture, located["width"], located["height"],
                                  located["pitch_blocks"], located["endian"])
            path = os.path.join(out_dir, f"{stem}_{label}.png")
            _write_png(path, located["width"], located["height"], rgba)
            written.append(path)
    return "\n".join(written)


# --- CLI --------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--gamedata", default=None,
                        help="GameData directory (default: the app's GameData link)")

    sub.add_parser("check", parents=[common], help="validate the assets only")
    p_build = sub.add_parser("build-profile", parents=[common],
                             help="build a preservation profile")
    p_build.add_argument("--profile", required=True,
                         help="destination profile directory")
    p_build.add_argument("--dry-run", action="store_true",
                         help="report what would happen without writing anything")
    p_preview = sub.add_parser("preview", parents=[common],
                               help="write before/after PNG decodes")
    p_preview.add_argument("--out", required=True, help="output directory")

    args = parser.parse_args(argv)
    source = args.gamedata or default_gamedata()

    try:
        if args.command == "check":
            print(check(source))
        elif args.command == "build-profile":
            print(build_profile(source, args.profile, dry_run=args.dry_run))
        else:
            print(preview(source, args.out))
    except CreditPatchError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
