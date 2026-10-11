#!/usr/bin/env python3
"""Focused tests for scripts/macos_credit_patch.py.

Everything runs on synthetic fixtures, so the suite needs no game data and no
game launch. It verifies the BC3 codec against hand-computed golden vectors and
an independent decoder, the Xenos endian transform against an independent
byte-swap, the tiled addressing against the SDK's row/column formulation, the
XPR2 fetch-constant parsing, mask compositing, and the whole preservation-profile
lifecycle through the real module: refusal cases, no-mutation check/dry-run,
idempotence and a second-target failure that must leave the source and any
previous profile untouched.
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import macos_credit_patch as mcp  # noqa: E402

PASS = 0
XPR2_DATA_OFFSET = 96  # 84-byte XPR2 resource header, padded to a 16-byte boundary


def check(condition, message):
    global PASS
    if not condition:
        raise AssertionError(message)
    PASS += 1


# --- synthetic fixtures -----------------------------------------------------


def build_big(magic: bytes, entries):
    positions = []
    pos = 16
    for name, _ in entries:
        positions.append(pos)
        pos += 9 + len(name.encode())
    header_len = pos
    table = bytearray()
    for name, data in entries:
        table += struct.pack(">II", 0, len(data)) + name.encode() + b"\x00"
    out = bytearray(16) + table
    out[0:4] = magic
    struct.pack_into(">I", out, 8, len(entries))
    struct.pack_into(">I", out, 12, header_len)
    for (name, data), position in zip(entries, positions):
        offset = len(out)
        struct.pack_into(">I", out, position, offset)
        out += data
    struct.pack_into(">I", out, 4, len(out))
    return bytes(out)


def build_fetch_constant(width, height, *, texture_format=20, endian=1,
                         tiled=1, fetch_type=2, dimension=1, pitch_px=None):
    pitch_px = width if pitch_px is None else pitch_px
    d0 = fetch_type | ((pitch_px >> 5) << 22) | (tiled << 31)
    d1 = texture_format | (endian << 6)
    d2 = ((width - 1) & 0x1FFF) | (((height - 1) & 0x1FFF) << 13)
    d5 = dimension << 9
    return struct.pack(">6I", d0, d1, d2, 0, 0, d5)


def build_xpr2(width, height, texture: bytes, **fetch_kwargs):
    header = bytearray(XPR2_DATA_OFFSET)
    header[0:4] = b"XPR2"
    struct.pack_into(">I", header, 4, XPR2_DATA_OFFSET - 12)  # 84-byte resource header
    struct.pack_into(">I", header, 8, len(texture))
    header[0x48:0x48 + 24] = build_fetch_constant(width, height, **fetch_kwargs)
    return bytes(header) + texture


def make_source(path, specs):
    """specs: list of dicts with outer/inner/width/height/text_xy/text_height.

    Returns a list of target dicts with resolved source hashes.
    """
    os.makedirs(path, exist_ok=True)
    outer_entries = []
    targets = []
    for spec in specs:
        texture = bytes(spec["width"] * spec["height"])  # transparent black
        xpr2 = build_xpr2(spec["width"], spec["height"], texture)
        bigf = build_big(b"BIGF", [(spec["inner"], xpr2)])
        outer_entries.append((spec["outer"], bigf))
        targets.append({
            "outer": spec["outer"],
            "inner": spec["inner"],
            "width": spec["width"],
            "height": spec["height"],
            "source_sha256": hashlib.sha256(bigf).hexdigest(),
            "applied_sha256": None,
            "text_xy": spec["text_xy"],
            "text_height": spec["text_height"],
        })
    data1 = build_big(b"BIG4", outer_entries)
    with open(os.path.join(path, "data1.big"), "wb") as handle:
        handle.write(data1)
    with open(os.path.join(path, "data1.bh"), "wb") as handle:
        handle.write(b"index")
    with open(os.path.join(path, "default.xex"), "wb") as handle:
        handle.write(b"xex")
    # Nested real directories, so the profile layout can be exercised the way
    # the runtime walks it (the regression is directories symlinked as files).
    for sub in ("data/loc", "dlc/pack", "$SystemUpdate"):
        os.makedirs(os.path.join(path, sub), exist_ok=True)
    with open(os.path.join(path, "data", "loc", "locale.big"), "wb") as handle:
        handle.write(b"locale-bytes" * 4096)
    with open(os.path.join(path, "dlc", "pack", "pack.big"), "wb") as handle:
        handle.write(b"dlc-pack-bytes")
    return targets


DEFAULT_SPECS = [
    {"outer": "data/a/press.big", "inner": "5", "width": 256, "height": 128,
     "text_xy": (40, 96), "text_height": 9},
    {"outer": "data/b/menu.big", "inner": "8", "width": 512, "height": 256,
     "text_xy": (20, 150), "text_height": 17},
]


def with_targets(targets):
    class Guard:
        def __enter__(self):
            self.saved = mcp.TARGETS
            mcp.TARGETS = tuple(targets)
        def __exit__(self, *exc):
            mcp.TARGETS = self.saved
    return Guard()


# --- independent references -------------------------------------------------


def ref_swap16(data: bytes) -> bytes:
    view = bytearray(data)
    for i in range(0, len(view) - 1, 2):
        view[i], view[i + 1] = view[i + 1], view[i]
    return bytes(view)


def ref_palette_color(c0, c1):
    def expand(c):
        r = (c >> 11) & 0x1F
        g = (c >> 5) & 0x3F
        b = c & 0x1F
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    ca, cb = expand(c0), expand(c1)
    return [ca, cb,
            ((2 * ca[0] + cb[0]) // 3, (2 * ca[1] + cb[1]) // 3, (2 * ca[2] + cb[2]) // 3),
            ((ca[0] + 2 * cb[0]) // 3, (ca[1] + 2 * cb[1]) // 3, (ca[2] + 2 * cb[2]) // 3)]


def ref_decode_bc3(block: bytes):
    """A separate, spec-literal BC3 decoder. Always four color entries."""
    a0, a1 = block[0], block[1]
    if a0 > a1:
        alphas = [a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
    else:
        alphas = [a0, a1, (4 * a0 + a1) // 5, (3 * a0 + 2 * a1) // 5,
                  (2 * a0 + 3 * a1) // 5, (a0 + 4 * a1) // 5, 0, 255]
    abits = int.from_bytes(block[2:8], "little")
    c0, c1 = struct.unpack_from("<HH", block, 8)
    cbits = struct.unpack_from("<I", block, 12)[0]
    colors = ref_palette_color(c0, c1)
    pixels = []
    for i in range(16):
        colour = colors[(cbits >> (2 * i)) & 3]
        pixels.append((colour[0], colour[1], colour[2], alphas[(abits >> (3 * i)) & 7]))
    return pixels


def sdk_tiled_offset(x, y, pitch_blocks, log2_bpp):
    """The SDK's conversion.cpp TiledOffset2DRow/TiledOffset2DColumn pair."""
    def row(yd, width, l2):
        macro = ((yd // 32) * (width // 32)) << (l2 + 7)
        micro = ((yd & 6) << 2) << l2
        return (macro + ((micro & ~0xF) << 1) + (micro & 0xF)
                + ((yd & 8) << (3 + l2)) + ((yd & 1) << 4))

    def col(xd, yd, l2, base):
        macro = (xd // 32) << (l2 + 7)
        micro = (xd & 7) << l2
        off = base + macro + ((micro & ~0xF) << 1) + (micro & 0xF)
        return (((off & ~0x1FF) << 3) + ((off & 0x1C0) << 2) + (off & 0x3F)
                + ((yd & 16) << 7) + (((((yd & 8) >> 2) + (xd >> 3)) & 3) << 6))

    return col(x, y, log2_bpp, row(y, pitch_blocks, log2_bpp)) & ~((1 << log2_bpp) - 1)


# --- tests ------------------------------------------------------------------


def test_archive_primitives():
    bigf = build_big(b"BIGF", [("5", b"hello"), ("6", b"world!")])
    entries = mcp.parse_bigf(bigf)
    check([e[0] for e in entries] == ["5", "6"], "BIGF entry names")
    check([e[2] for e in entries] == [5, 6], "BIGF entry lengths")
    offset, length = mcp.inner_entry(bigf, "6")
    check(bigf[offset:offset + length] == b"world!", "inner_entry slice")
    try:
        mcp.parse_big_directory(b"XXXX" + b"\x00" * 12, 16)
        raise AssertionError("bad magic accepted")
    except mcp.CreditPatchError:
        check(True, "bad BIG magic refused")


def test_fetch_constant_and_xpr2():
    texture = bytes(64 * 32)
    xpr2 = build_xpr2(64, 32, texture)
    info = mcp.xpr2_info(xpr2)
    check(info["width"] == 64 and info["height"] == 32, "xpr2 size")
    check(info["format"] == mcp.FORMAT_DXT4_5, "xpr2 format is DXT5")
    check(info["endian"] == mcp.ENDIAN_8IN16, "xpr2 endian is 8in16")
    check(info["pitch_blocks"] == 16, "xpr2 pitch in blocks")
    check(info["data_offset"] == XPR2_DATA_OFFSET, "xpr2 data offset")

    # A wrong fetch mode is refused rather than silently misread. All four
    # 2-bit endian values are legal, so they are exercised by test_endian_transform.
    for kwargs in ({"texture_format": 18}, {"tiled": 0},
                   {"dimension": 3}, {"fetch_type": 0}):
        bad = build_xpr2(64, 32, texture, **kwargs)
        try:
            mcp.xpr2_info(bad)
            raise AssertionError(f"bad fetch accepted: {kwargs}")
        except mcp.CreditPatchError:
            check(True, f"bad fetch refused: {kwargs}")
    # A data-size/dimension disagreement is refused.
    bad = bytearray(build_xpr2(64, 32, texture))
    struct.pack_into(">I", bad, 8, 64 * 32 + 16)
    try:
        mcp.xpr2_info(bytes(bad))
        raise AssertionError("size mismatch accepted")
    except mcp.CreditPatchError:
        check(True, "xpr2 size mismatch refused")


def test_endian_transform():
    data = bytes(range(32))
    for endian, expected in (
            (mcp.ENDIAN_NONE, data),
            (mcp.ENDIAN_8IN16, ref_swap16(data)),
    ):
        check(mcp.endian_transform(data, endian) == expected, f"endian {endian} value")
        check(mcp.endian_transform(mcp.endian_transform(data, endian), endian) == data,
              f"endian {endian} involution")
    # 8in32 reverses each four-byte group; 16in32 swaps the two halve-words.
    check(mcp.endian_transform(bytes(range(4)), mcp.ENDIAN_8IN32) == bytes((3, 2, 1, 0)),
          "endian 8in32")
    check(mcp.endian_transform(bytes(range(4)), mcp.ENDIAN_16IN32) == bytes((2, 3, 0, 1)),
          "endian 16in32")


def test_bc3_golden_vectors():
    # c0 < c1 with selector 3: BC3 still uses the four-entry palette, so the
    # third interpolated colour is (c0 + 2*c1)/3, not transparent black.
    block = bytes([255, 255, 0, 0, 0, 0, 0, 0]) + struct.pack("<HHI", 0x0000, 0xFFFF, 0xFFFFFFFF)
    pixels = mcp.decode_bc3_block(block)
    check(all(p == (170, 170, 170, 255) for p in pixels),
          "golden c0<c1 selector3 decodes to 170 grey")
    check(mcp.decode_bc3_block(block) == ref_decode_bc3(block),
          "module decoder matches independent decoder on the golden block")

    # c0 > c1 selector 3 uses the (c0 + 2*c1)/3 entry in both decoders.
    block2 = bytes([255, 255, 0, 0, 0, 0, 0, 0]) + struct.pack("<HHI", 0xFFFF, 0x0000, 0xFFFFFFFF)
    check(all(p == (85, 85, 85, 255) for p in mcp.decode_bc3_block(block2)),
          "golden c0>c1 selector3 decodes to 85 grey")

    # Alpha mode with a0 <= a1 exposes the 0/255 entries; index 7 is opaque.
    block3 = bytes([10, 200, 0, 0, 0, 0, 0, 0]) + struct.pack("<HHI", 0xFFFF, 0xFFFF, 0)
    check(mcp.decode_bc3_block(block3)[0][3] == 10, "alpha a0<=a1 index0")
    abits = (7 << 0) | (7 << 3)
    block4 = bytes([10, 200]) + abits.to_bytes(6, "little") + struct.pack("<HHI", 0xFFFF, 0xFFFF, 0)
    check(mcp.decode_bc3_block(block4)[0][3] == 255, "alpha a0<=a1 index7 is opaque")


def test_bc3_roundtrip_against_reference():
    grey = [(204, 204, 204, 255)] * 16
    block = mcp.encode_bc3_block(grey)
    decoded = ref_decode_bc3(block)
    check(all(abs(p[0] - 204) <= 10 and p[3] == 255 for p in decoded),
          "independent decoder accepts encoded grey block")
    # A single bright pixel must survive with a dark neighbourhood.
    mixed = [(0, 0, 0, 0)] * 16
    mixed[5] = (204, 204, 204, 255)
    decoded = ref_decode_bc3(mcp.encode_bc3_block(mixed))
    check(decoded[5][3] > 200 and decoded[5][0] > 150, "bright pixel bright in reference")
    check(max(decoded[i][3] for i in range(16) if i != 5) < 90, "neighbours stay dark")
    # A four-level grey pattern matches the four-entry BC3 palette closely.
    levels = [0, 85, 170, 255]
    ramp = [(levels[i % 4], levels[i % 4], levels[i % 4], 255) for i in range(16)]
    decoded = ref_decode_bc3(mcp.encode_bc3_block(ramp))
    check(sum(abs(a[0] - b[0]) for a, b in zip(decoded, ramp)) // 16 <= 6,
          "four-level grey round-trips within tolerance")


def test_tiling_matches_sdk_reference():
    for width, height in ((1024, 128), (2048, 1024), (256, 256)):
        pitch = width // 4
        mismatches = 0
        for by in range(height // 4):
            for bx in range(pitch):
                if mcp.tiled_offset(bx, by, pitch, 4) != sdk_tiled_offset(bx, by, pitch, 4):
                    mismatches += 1
        check(mismatches == 0, f"tiling matches SDK reference for {width}x{height}")


def test_patch_only_touches_mask_blocks():
    width, height = 256, 128
    texture = bytes(width * height)
    mask = bytes([255] * (12 * 12))
    patched, changed = mcp.patch_texture(
        texture, width, height, width // 4, mcp.ENDIAN_8IN16, (12, 12, mask), (64, 64))
    check(changed, "mask changes a transparent texture")
    pitch = width // 4
    preserved = True
    for by in range(height // 4):
        for bx in range(pitch):
            offset = mcp.tiled_offset(bx, by, pitch, 4)
            inside = 64 <= bx * 4 < 76 and 64 <= by * 4 < 76
            if not inside and patched[offset:offset + 16] != texture[offset:offset + 16]:
                preserved = False
    check(preserved, "every block outside the mask is byte-identical")
    bright = 0
    for by in range(16, 19):
        for bx in range(16, 19):
            offset = mcp.tiled_offset(bx, by, pitch, 4)
            natural = mcp.endian_transform(patched[offset:offset + 16], mcp.ENDIAN_8IN16)
            for pixel in mcp.decode_bc3_block(natural):
                if pixel[0] > 120:
                    bright += 1
    check(bright >= 64, "mask produced bright, correctly endian-decoded pixels")


def test_profile_lifecycle():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "GameData")
        targets = make_source(source, DEFAULT_SPECS)
        dest = os.path.join(tmp, "profile-v2")
        before = open(os.path.join(source, "data1.big"), "rb").read()
        with with_targets(targets):
            message = mcp.build_profile(source, dest)
            check("Built" in message, "build reports success")
            check(mcp.is_valid_profile(dest), "profile marker is valid")
            # Real directories, symlinked files; data1.big is a real cloned file.
            for name in os.listdir(source):
                src = os.path.join(source, name)
                out = os.path.join(dest, name)
                if name == "data1.big":
                    check(not os.path.islink(out) and os.path.isfile(out),
                          "profile data1.big is a real file")
                elif os.path.isdir(src):
                    check(os.path.isdir(out) and not os.path.islink(out),
                          f"profile {name} is a real directory")
                else:
                    check(os.path.islink(out), f"profile {name} is a symlink")
            after = open(os.path.join(source, "data1.big"), "rb").read()
            check(after == before, "source data1.big is untouched")
            built = open(os.path.join(dest, "data1.big"), "rb").read()
            check(built != before, "profile data1.big differs from the source")

            # Idempotence: rebuilding yields identical bytes and stays valid.
            mcp.build_profile(source, dest)
            rebuilt = open(os.path.join(dest, "data1.big"), "rb").read()
            check(rebuilt == built, "rebuild is byte-identical (idempotent)")
            check(mcp.is_valid_profile(dest), "profile still valid after rebuild")

            # A profile that has already been built is a valid destination.
            marker = json.load(open(mcp.profile_marker(dest)))
            check(marker["version"] == mcp.PROFILE_VERSION, "marker version")


def _check_file_link(src, dst, rel):
    check(os.path.islink(dst), f"profile {rel} is a symlink")
    check(os.path.realpath(dst) == os.path.realpath(src),
          f"profile {rel} points at the original")
    with open(src, "rb") as original, open(dst, "rb") as linked:
        check(linked.read() == original.read(), f"profile {rel} bytes match")


def _check_directory_mirror(src_dir, dst_dir, rel):
    check(os.path.isdir(dst_dir) and not os.path.islink(dst_dir),
          f"profile {rel} is a real directory")
    for name in sorted(os.listdir(src_dir)):
        src = os.path.join(src_dir, name)
        dst = os.path.join(dst_dir, name)
        if os.path.isdir(src):
            _check_directory_mirror(src, dst, os.path.join(rel, name))
        else:
            _check_file_link(src, dst, os.path.join(rel, name))


def test_profile_materializes_nested_directories():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "GameData")
        targets = make_source(source, DEFAULT_SPECS)
        # A benign directory symlink (a sibling subtree, not an ancestor) must
        # be followed and materialized too, so its contents stay reachable.
        os.symlink(os.path.join(source, "data", "loc"), os.path.join(source, "alias"))
        dest = os.path.join(tmp, "profile-v2")
        with with_targets(targets):
            mcp.build_profile(source, dest)
            check(not os.path.islink(os.path.join(dest, "data1.big")),
                  "data1.big is a real cloned file")
            for name in sorted(os.listdir(source)):
                if name == "data1.big":
                    continue
                src = os.path.join(source, name)
                dst = os.path.join(dest, name)
                if os.path.isdir(src):
                    _check_directory_mirror(src, dst, name)
                else:
                    _check_file_link(src, dst, name)
            check(os.path.isfile(os.path.join(dest, "data", "loc", "locale.big")),
                  "nested locale.big is present through the profile")


def test_profile_refuses_directory_cycle():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "GameData")
        targets = make_source(source, DEFAULT_SPECS)
        # A symlink back to an ancestor would recurse forever.
        os.symlink(source, os.path.join(source, "data", "self"))
        dest = os.path.join(tmp, "profile")
        with with_targets(targets):
            try:
                mcp.build_profile(source, dest)
                raise AssertionError("directory cycle accepted")
            except mcp.CreditPatchError:
                check(True, "directory cycle refused")
            check(not os.path.exists(dest), "no profile left after cycle refusal")
            stray = [n for n in os.listdir(tmp) if n.startswith(".macos-credits")]
            check(not stray, "no staging left after cycle refusal")


def test_no_mutation_on_check_and_dry_run():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "GameData")
        targets = make_source(source, DEFAULT_SPECS)
        dest = os.path.join(tmp, "profile")
        with with_targets(targets):
            snapshot = {name: os.path.getsize(os.path.join(source, name))
                        for name in os.listdir(source)}
            mcp.check(source)
            check(mcp.build_profile(source, dest, dry_run=True).startswith("Would"),
                  "dry-run reports what it would do")
            check(not os.path.exists(dest), "dry-run created no profile")
            check(sorted(os.listdir(source)) == sorted(snapshot), "source listing unchanged")
            for name, size in snapshot.items():
                check(os.path.getsize(os.path.join(source, name)) == size,
                      f"source {name} size unchanged")
            stray = [n for n in os.listdir(tmp) if n.startswith(".macos-credits")]
            check(not stray, "no staging directories left behind")


def test_refuses_unsafe_destinations():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "GameData")
        targets = make_source(source, DEFAULT_SPECS)
        with with_targets(targets):
            # A symlink profile path is refused.
            link = os.path.join(tmp, "link-profile")
            os.symlink(source, link)
            try:
                mcp.build_profile(source, link)
                raise AssertionError("symlink profile accepted")
            except mcp.CreditPatchError:
                check(True, "symlink profile refused")

            # A profile inside the source is refused.
            try:
                mcp.build_profile(source, os.path.join(source, "profile"))
                raise AssertionError("source-descendant profile accepted")
            except mcp.CreditPatchError:
                check(True, "source-descendant profile refused")

            # The source itself is refused.
            try:
                mcp.build_profile(source, source)
                raise AssertionError("profile == source accepted")
            except mcp.CreditPatchError:
                check(True, "profile == source refused")

            # An arbitrary existing directory is refused.
            arbitrary = os.path.join(tmp, "existing")
            os.makedirs(arbitrary)
            with open(os.path.join(arbitrary, "keep"), "w") as handle:
                handle.write("do not delete")
            try:
                mcp.build_profile(source, arbitrary)
                raise AssertionError("arbitrary directory accepted")
            except mcp.CreditPatchError:
                check(True, "arbitrary directory refused")
            check(os.path.isfile(os.path.join(arbitrary, "keep")),
                  "arbitrary directory left untouched")


def test_second_target_failure_leaves_everything():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "GameData")
        targets = make_source(source, DEFAULT_SPECS)
        dest = os.path.join(tmp, "profile-v2")
        with with_targets(targets):
            mcp.build_profile(source, dest)
            good = open(os.path.join(dest, "data1.big"), "rb").read()
            source_before = open(os.path.join(source, "data1.big"), "rb").read()

            # Corrupt the second target's XPR2 so its preparation fails.
            bad = bytearray(source_before)
            _, entries = mcp.read_data1(os.path.join(source, "data1.big"))
            offset, length = [e[1:] for e in entries if e[0] == DEFAULT_SPECS[1]["outer"]][0]
            bad[offset:offset + length] = bytes(length)  # zeroed -> wrong revision
            with open(os.path.join(source, "data1.big"), "wb") as handle:
                handle.write(bad)

            try:
                mcp.build_profile(source, dest)
                raise AssertionError("malformed second target accepted")
            except mcp.CreditPatchError:
                check(True, "malformed second target refused")
            check(open(os.path.join(dest, "data1.big"), "rb").read() == good,
                  "existing profile untouched after failure")
            stray = [n for n in os.listdir(tmp) if n.startswith(".macos-credits")]
            check(not stray, "no staging left after failure")


def test_render_mask_is_deterministic():
    w1, h1, m1 = mcp.render_text_mask(mcp.TEXT, 9)
    w2, h2, m2 = mcp.render_text_mask(mcp.TEXT, 9)
    check((w1, h1, m1) == (w2, h2, m2), "mask bytes are deterministic")
    check(h1 == 9 and w1 > 80, "mask has a sensible size")
    check(any(b > 128 for b in m1) and any(b == 0 for b in m1),
          "mask has ink and background")


def main():
    test_archive_primitives()
    test_fetch_constant_and_xpr2()
    test_endian_transform()
    test_bc3_golden_vectors()
    test_bc3_roundtrip_against_reference()
    test_tiling_matches_sdk_reference()
    test_patch_only_touches_mask_blocks()
    test_profile_lifecycle()
    test_profile_materializes_nested_directories()
    test_profile_refuses_directory_cycle()
    test_no_mutation_on_check_and_dry_run()
    test_refuses_unsafe_destinations()
    test_second_target_failure_leaves_everything()
    test_render_mask_is_deterministic()
    print(f"ok: {PASS} checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
