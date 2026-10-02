# HDR+ sharpen cut - rewrites the gain columns of the two active detail stages in
# hdrp_mc.xml (parsed by /odm/lib64/libhdrp.so at /Config/RAWNR/{lanczos_de,
# DetailAddBack/Layer0..2/CurrentLayer}/{exp,iso}%d + CHANGEREFRAWNR mirrors).
# -v cut = percent the gains are reduced by (0..90); 0 leaves the file untouched.
# -v cnt = file the number of rewritten rows is written to (the caller only
# mounts when that count proves the whole schema was seen).
# A row is only rewritten when its token count matches the schema exactly, so a
# ROM that changed the layout yields a byte-identical file instead of garbage.
# Threshold columns ([0,255] groups, k, detail/subn counts) are never touched.
BEGIN {
    nd = split("13 14 15 18 19 20 21", di, " ")   # DetailAddBack weights+scale
    nl = split("5 6 7 10 11 16 17 18", li, " ")   # lanczos_de [0,512] gains
    f = (100 - cut) / 100
}
cut + 0 == 0 { print; next }
/^<Config>/ { print $0 "<!--shp" cut "-->"; next }
/<DetailAddBack>/    { dab = 1 }
/<\/DetailAddBack>/  { dab = 0 }
/<lanczos_de>/       { lz = 1 }
/<\/lanczos_de>/     { lz = 0 }
/^ *<(exp|iso)[0-9]+>/ && (dab || lz) {
    pre = $0; sub(/>.*/, "", pre)
    tag = $0; sub(/^ *</, "", tag); sub(/>.*/, "", tag)
    body = $0; sub(/^[^>]*>/, "", body); sub(/<.*$/, "", body)
    n = split(body, a, " ")
    if (dab) {
        if (n != 47) { print; next }
        for (k = 1; k <= nd; k++) a[di[k]] = sprintf("%g", a[di[k]] * f)
    } else {
        if (n != 18) { print; next }
        for (k = 1; k <= nl; k++) a[li[k]] = sprintf("%d", a[li[k]] * f + 0.5)
    }
    out = a[1]
    for (k = 2; k <= n; k++) out = out " " a[k]
    print pre ">" out "</" tag ">"
    done++
    next
}
{ print }
END { if (cnt != "") print (done + 0) > cnt }
