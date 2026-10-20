# Front beauty cut - gently rescales the intensity curves in the front camera's
# /odm/etc/camera/hwbeauty/front/hwbeauty_params.xml (the file hwbeauty/device.config
# maps the front sensor modules to, and which the beauty engine parses per Mode x
# ParamterSet(gender/skin/age)). Community complaint: 前置磨皮/美颜很奇怪.
#
# That file's effects are named, integer, per-beauty-level arrays (10 numbers =
# level 1..10). The aggressive ones (SkinSoften reaching 100, FaceSlender 95,
# EyeEnlargement 55 ... in the 11-35 female band) are exactly what reads as
# over-smoothed / plastic / de-shaped. This knob scales those curves toward the
# gentler end by a percent, leaving the structure and selection logic intact.
#
# -v cut    = percent the intensities are reduced by (0..90); 0 leaves the file byte-identical.
# -v cnt    = file the number of rewritten rows is written to (caller only mounts when
#             that count proves the expected schema was seen, so a relayout degrades to
#             "no edit" instead of a half-mangled tuning).
# -v eofnl  = 1 (default) if the source's last line ends with a newline, 0 if not. The
#             caller derives it from the file; it is what makes cut=0 a byte-for-byte
#             round-trip on this file, whose final line ("<HwBeautyParams ...</...>")
#             has no trailing newline.
#
# Safety model (mirrors sharpen.awk): a row is rewritten ONLY when
#   1. its tag is in the intensity whitelist below, AND
#   2. it is a single-line element whose body tokens are ALL integers.
# Anything with a float token is left verbatim, which automatically protects
#   Preview_*  (0.4/0.7 ... preview multipliers, not intensities),
#   SkinQualityRatio, EnvLumaRatioSet ("10  0.7" luma->ratio pairs).
# Index/threshold tags are NOT in the whitelist, so they never change either:
#   SkinToneStyle (a style index), SkinTone, ToneSet, GenderRatio.
# Values are floored at 0. The count is a structural fingerprint (every matched
# whitelist-int row, whether or not its value moved), so it stays stable across
# cut values and the caller's threshold check is reliable. Non-matching lines keep
# their exact bytes (incl. the CRLF/LF mix on this file).
BEGIN {
    nw = split("SkinSoften Deblemish FaceEdgeSmooth RemoveShine RemoveShineLcd SkinToneBright FaceSlender EyeEnlargement NoseSlender Smallhead Depouch LyingSilkworm Blush LipBeauty LipGloss NoseHighlight EyebrowDye EyebrowSaturate EyebrowSharp TeethWhiten EyeBrighten PupilBrighten", wa, " ")
    for (wi = 1; wi <= nw; wi++) wl[wa[wi]] = 1
    f = (100 - cut) / 100
    ORS = ""; sep = ""
}
# one emitted record: join with \n between records, never trailing here
function w(line) { printf "%s%s", sep, line; sep = "\n" }
cut + 0 == 0 { w($0); next }
/^[ \t]*<HwBeautyParams/ { w($0 "<!--bty" cut "-->"); next }
{
    s = $0
    if (s !~ /<[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*>[ \t\r]*-?[0-9]/) { w(s); next }
    if (!match(s, /<[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*>/)) { w(s); next }
    otlen = RLENGTH
    tag = substr(s, RSTART, otlen)
    sub(/^<[ \t]*/, "", tag); sub(/[ \t]*>$/, "", tag)
    if (!(tag in wl)) { w(s); next }
    rest = substr(s, RSTART + otlen)
    p = index(rest, "</")
    if (p == 0) { w(s); next }
    body = substr(rest, 1, p - 1)
    ct = substr(rest, p + 2); sub(/[ \t\r>].*$/, "", ct)
    if (ct != tag) { w(s); next }
    b2 = body; gsub(/\r/, "", b2); gsub(/[ \t]+/, " ", b2); sub(/^ /, "", b2); sub(/ $/, "", b2)
    m = split(b2, a, " ")
    allint = (m >= 2)
    for (i = 1; i <= m && allint; i++) if (a[i] !~ /^-?[0-9]+$/) allint = 0
    if (!allint) { w(s); next }
    for (i = 1; i <= m; i++) { r = int(a[i] * f + 0.5); if (r < 0) r = 0; a[i] = r }
    out = a[1]
    for (i = 2; i <= m; i++) out = out " " a[i]
    prefix = substr(s, 1, RSTART + otlen - 1)
    suffix = substr(s, RSTART + otlen + p - 1)
    w(prefix out suffix)
    done++
    next
}
END {
    if (eofnl != "0") printf "%s", "\n"
    if (cnt != "") print done + 0 > cnt
}
