#!/system/bin/sh
#
# Copyright (C) 2021-2026 12X
#
# Runtime loader for closedloop scheduler payload chunks.
#

BASEDIR="$(dirname "$(readlink -f "$0")")"
PAYLOAD_DIR="$BASEDIR/closedloop_payload"
RUNTIME_B64="$BASEDIR/.closedloop_sched.runtime.b64"
RUNTIME_SH="$BASEDIR/.closedloop_sched.runtime.sh"

decode_base64_file() {
    in_file="$1"
    out_file="$2"

    if command -v base64 >/dev/null 2>&1; then
        base64 -d "$in_file" >"$out_file" 2>/dev/null && return 0
    fi

    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        [ -x "$bb" ] || continue
        "$bb" base64 -d "$in_file" >"$out_file" 2>/dev/null && return 0
    done

    return 1
}

if [ ! -d "$PAYLOAD_DIR" ]; then
    echo "[closedloop] missing payload dir: $PAYLOAD_DIR" >&2
    exit 1
fi

: >"$RUNTIME_B64" || {
    echo "[closedloop] cannot create payload cache: $RUNTIME_B64" >&2
    exit 1
}

for part in "$PAYLOAD_DIR"/part*.b64; do
    [ -f "$part" ] || continue
    cat "$part" >>"$RUNTIME_B64"
done

if [ ! -s "$RUNTIME_B64" ]; then
    echo "[closedloop] payload is empty" >&2
    exit 1
fi

if ! decode_base64_file "$RUNTIME_B64" "$RUNTIME_SH"; then
    echo "[closedloop] base64 decode failed" >&2
    exit 1
fi

chmod 0755 "$RUNTIME_SH" 2>/dev/null
rm -f "$RUNTIME_B64" 2>/dev/null

exec /system/bin/sh "$RUNTIME_SH" "$@"
