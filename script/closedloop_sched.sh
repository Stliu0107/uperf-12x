#!/system/bin/sh
#
# Copyright (C) 2021-2026 12X
#
# Frame-target closed loop scheduler:
# - Joint score: tail latency + energy (cost/pwr)
# - Record app switches with simultaneous cost/pwr
# - Record in-app balance/powersave mode switches
# - Keep max 5000 records (ring by truncation)
#

BASEDIR="$(dirname $(readlink -f "$0"))"
. $BASEDIR/pathinfo.sh
. $BASEDIR/libcommon.sh

STATE_FILE="$USER_PATH/cur_powermode.txt"
PID_FILE="$USER_PATH/closedloop_sched.pid"
DATA_DIR="$USER_PATH/closedloop_data"
EVENT_LOG="$USER_PATH/closedloop_events.csv"
BASELINE_LOG="$USER_PATH/closedloop_baseline.csv"

MAX_RECORDS=5000
LOOP_INTERVAL=2
EVAL_INTERVAL=10
MIN_SWITCH_INTERVAL=18

BOOT_DELAY_SECONDS=120
BOOT_EVAL_INTERVAL=60
BOOT_EVAL_COUNT=30

SCREENOFF_EVAL_INTERVAL=180
SCREENOFF_EVAL_COUNT=50

LOG_HEADER="ts,event,app,from,to,mode,cost,pwr,p95,p99,target_ms,joint_score,phase,baseline,reason"

is_pid_alive() {
    [ -n "$1" ] || return 1
    kill -0 "$1" 2>/dev/null
}

start_lock() {
    mkdir -p "$USER_PATH"
    if [ -f "$PID_FILE" ]; then
        old_pid="$(cat "$PID_FILE" 2>/dev/null)"
        if is_pid_alive "$old_pid"; then
            exit 0
        fi
    fi
    echo "$$" >"$PID_FILE"
}

trim_records() {
    [ -f "$EVENT_LOG" ] || return 0
    total="$(wc -l <"$EVENT_LOG" 2>/dev/null)"
    [ -n "$total" ] || return 0
    if [ "$total" -gt $((MAX_RECORDS + 1)) ]; then
        {
            head -n 1 "$EVENT_LOG"
            tail -n "$MAX_RECORDS" "$EVENT_LOG"
        } >"$EVENT_LOG.tmp" && mv -f "$EVENT_LOG.tmp" "$EVENT_LOG"
    fi
}

append_event() {
    echo "$1" >>"$EVENT_LOG"
    trim_records
}

init_logs() {
    mkdir -p "$DATA_DIR"

    if [ ! -f "$EVENT_LOG" ]; then
        echo "$LOG_HEADER" >"$EVENT_LOG"
    else
        first_line="$(head -n 1 "$EVENT_LOG" 2>/dev/null)"
        if [ "$first_line" != "$LOG_HEADER" ]; then
            mv -f "$EVENT_LOG" "$EVENT_LOG.bak.$(date +%s)"
            echo "$LOG_HEADER" >"$EVENT_LOG"
        fi
    fi

    echo "phase,core,cost_median,pwr_median,sample_count,generated_at" >"$BASELINE_LOG"

    rm -f "$DATA_DIR"/*.dat 2>/dev/null
    trim_records
}

read_mode() {
    if [ -f "$STATE_FILE" ]; then
        tr -d '\r\n' <"$STATE_FILE"
    else
        echo "balance"
    fi
}

detect_target_ms() {
    hz="$(/system/bin/dumpsys display 2>/dev/null | sed -n 's/.*refreshRate=\([0-9.]*\).*/\1/p' | head -n 1)"
    if [ -z "$hz" ]; then
        hz="$(/system/bin/settings get system peak_refresh_rate 2>/dev/null)"
    fi
    echo "$hz" | grep -Eq '^[0-9]+([.][0-9]+)?$' || hz="60"
    awk -v r="$hz" 'BEGIN{
        if (r >= 119) print "8.33";
        else if (r >= 89) print "11.11";
        else print "16.67";
    }'
}

screen_is_off() {
    if /system/bin/dumpsys display 2>/dev/null | grep -qE 'mScreenState=OFF|mGlobalDisplayState=OFF|state=OFF'; then
        echo "true"
        return
    fi
    if /system/bin/dumpsys power 2>/dev/null | grep -qE 'Display Power: state=OFF|mWakefulness=Asleep'; then
        echo "true"
        return
    fi
    echo "false"
}

is_pkg_like() {
    echo "$1" | grep -qE '^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+$'
}

pkg_from_cpuset() {
    for node in /dev/cpuset/top-app/cgroup.procs /dev/cpuset/top-app/tasks; do
        [ -f "$node" ] || continue
        for pid in $(cat "$node" 2>/dev/null); do
            [ -r "/proc/$pid/cmdline" ] || continue
            proc_name="$(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null | head -n 1)"
            proc_name="${proc_name%%:*}"
            is_pkg_like "$proc_name" || continue
            echo "$proc_name"
            return 0
        done
    done
    return 1
}

pkg_from_dumpsys() {
    pkg="$(/system/bin/dumpsys activity activities 2>/dev/null | sed -n -e 's/.*topResumedActivity=.* \([^ /}]*\)\/.*/\1/p' -e 's/.*mResumedActivity: .* \([^ /}]*\)\/.*/\1/p' | head -n 1)"
    if is_pkg_like "$pkg"; then
        echo "$pkg"
        return 0
    fi

    pkg="$(/system/bin/dumpsys window windows 2>/dev/null | sed -n -e 's/.*mCurrentFocus=.* \([^ /}]*\)\/.*/\1/p' -e 's/.*mFocusedApp=.* \([^ /}]*\)\/.*/\1/p' | head -n 1)"
    if is_pkg_like "$pkg"; then
        echo "$pkg"
        return 0
    fi

    pkg="$(/system/bin/dumpsys activity top 2>/dev/null | sed -n 's/.*ACTIVITY \([^ /]*\)\/.*/\1/p' | head -n 1)"
    if is_pkg_like "$pkg"; then
        echo "$pkg"
        return 0
    fi

    return 1
}

get_top_package() {
    pkg=""
    pkg="$(pkg_from_cpuset 2>/dev/null)"
    if ! is_pkg_like "$pkg"; then
        pkg="$(pkg_from_dumpsys 2>/dev/null)"
    fi
    if ! is_pkg_like "$pkg"; then
        pkg="unknown"
    fi
    echo "$pkg"
}

instant_cost_pwr() {
    total_cost="0"
    total_pwr="0"
    n=0

    for cur_path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
        [ -f "$cur_path" ] || continue
        cpu_tmp="${cur_path#/sys/devices/system/cpu/cpu}"
        cpu_id="${cpu_tmp%%/*}"
        max_path="/sys/devices/system/cpu/cpu$cpu_id/cpufreq/cpuinfo_max_freq"
        [ -f "$max_path" ] || continue

        cur="$(cat "$cur_path" 2>/dev/null)"
        max="$(cat "$max_path" 2>/dev/null)"
        echo "$cur" | grep -Eq '^[0-9]+$' || continue
        echo "$max" | grep -Eq '^[0-9]+$' || continue
        [ "$max" -gt 0 ] || continue

        ratio="$(awk -v c="$cur" -v m="$max" 'BEGIN{r=c/m; if(r<0)r=0; if(r>1.5)r=1.5; printf "%.6f", r}')"
        pwr_i="$(awk -v r="$ratio" 'BEGIN{printf "%.6f", r*r*r}')"

        total_cost="$(awk -v a="$total_cost" -v b="$ratio" 'BEGIN{printf "%.6f", a+b}')"
        total_pwr="$(awk -v a="$total_pwr" -v b="$pwr_i" 'BEGIN{printf "%.6f", a+b}')"
        n=$((n + 1))
    done

    echo "$total_cost,$total_pwr,$n"
}

append_core_sample() {
    phase="$1"
    total_cost="0"
    total_pwr="0"
    n=0

    for cur_path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
        [ -f "$cur_path" ] || continue
        cpu_tmp="${cur_path#/sys/devices/system/cpu/cpu}"
        cpu_id="${cpu_tmp%%/*}"
        max_path="/sys/devices/system/cpu/cpu$cpu_id/cpufreq/cpuinfo_max_freq"
        [ -f "$max_path" ] || continue

        cur="$(cat "$cur_path" 2>/dev/null)"
        max="$(cat "$max_path" 2>/dev/null)"
        echo "$cur" | grep -Eq '^[0-9]+$' || continue
        echo "$max" | grep -Eq '^[0-9]+$' || continue
        [ "$max" -gt 0 ] || continue

        ratio="$(awk -v c="$cur" -v m="$max" 'BEGIN{r=c/m; if(r<0)r=0; if(r>1.5)r=1.5; printf "%.6f", r}')"
        pwr_i="$(awk -v r="$ratio" 'BEGIN{printf "%.6f", r*r*r}')"

        echo "$ratio" >>"$DATA_DIR/${phase}_cost_core${cpu_id}.dat"
        echo "$pwr_i" >>"$DATA_DIR/${phase}_pwr_core${cpu_id}.dat"

        total_cost="$(awk -v a="$total_cost" -v b="$ratio" 'BEGIN{printf "%.6f", a+b}')"
        total_pwr="$(awk -v a="$total_pwr" -v b="$pwr_i" 'BEGIN{printf "%.6f", a+b}')"
        n=$((n + 1))
    done

    echo "$total_cost,$total_pwr,$n"
}

median_from_file() {
    [ -f "$1" ] || {
        echo "0"
        return
    }
    sort -n "$1" | awk '{a[NR]=$1} END{
        if (NR == 0) {
            print "0";
        } else if (NR % 2 == 1) {
            printf "%.6f", a[(NR+1)/2];
        } else {
            printf "%.6f", (a[NR/2] + a[NR/2+1]) / 2.0;
        }
    }'
}

compute_phase_medians() {
    phase="$1"
    generated_at="$(date '+%Y-%m-%d %H:%M:%S')"
    total_cost_med="0"
    total_pwr_med="0"
    core_n=0

    for cost_file in "$DATA_DIR"/${phase}_cost_core*.dat; do
        [ -f "$cost_file" ] || continue
        tmp_name="${cost_file##*${phase}_cost_core}"
        core_id="${tmp_name%%.dat}"
        pwr_file="$DATA_DIR/${phase}_pwr_core${core_id}.dat"

        cost_med="$(median_from_file "$cost_file")"
        pwr_med="$(median_from_file "$pwr_file")"
        sample_n="$(wc -l <"$cost_file" 2>/dev/null)"
        [ -n "$sample_n" ] || sample_n=0

        echo "$phase,$core_id,$cost_med,$pwr_med,$sample_n,$generated_at" >>"$BASELINE_LOG"

        total_cost_med="$(awk -v a="$total_cost_med" -v b="$cost_med" 'BEGIN{printf "%.6f", a+b}')"
        total_pwr_med="$(awk -v a="$total_pwr_med" -v b="$pwr_med" 'BEGIN{printf "%.6f", a+b}')"
        core_n=$((core_n + 1))
    done

    echo "$total_cost_med,$total_pwr_med,$core_n"
}

read_frame_tail() {
    pkg="$1"
    if [ "$pkg" = "unknown" ]; then
        FRAME_P95="0"
        FRAME_P99="0"
        return
    fi

    out="$(/system/bin/dumpsys gfxinfo "$pkg" 2>/dev/null)"
    FRAME_P95="$(echo "$out" | awk '/95th percentile:/ {gsub("ms","",$3); print $3; exit}')"
    FRAME_P99="$(echo "$out" | awk '/99th percentile:/ {gsub("ms","",$3); print $3; exit}')"

    echo "$FRAME_P95" | grep -Eq '^[0-9]+([.][0-9]+)?$' || FRAME_P95="0"
    echo "$FRAME_P99" | grep -Eq '^[0-9]+([.][0-9]+)?$' || FRAME_P99="0"
}

calc_joint_score() {
    awk -v p95="$1" -v p99="$2" -v target="$3" -v cost="$4" -v base_cost="$5" -v pwr="$6" -v base_pwr="$7" 'BEGIN{
        if (target <= 0) target = 16.67;

        t95 = (p95 - target) / target; if (t95 < 0) t95 = 0;
        t99 = (p99 - target) / target; if (t99 < 0) t99 = 0;
        tail = 0.70 * t95 + 0.30 * t99;

        e_cost = 0;
        if (base_cost > 0) {
            e_cost = (cost / base_cost) - 1.0;
            if (e_cost < 0) e_cost = 0;
        }

        e_pwr = 0;
        if (base_pwr > 0) {
            e_pwr = (pwr / base_pwr) - 1.0;
            if (e_pwr < 0) e_pwr = 0;
        }

        energy = 0.50 * e_cost + 0.50 * e_pwr;
        score = 0.65 * tail + 0.35 * energy;
        if (score < 0) score = 0;
        printf "%.6f", score;
    }'
}

should_manage_pkg() {
    echo "$1" | grep -qE '^(unknown|android|com\.android\.|com\.google\.android\.inputmethod)'
    [ "$?" = "0" ] && return 1
    return 0
}

choose_mode() {
    # args: mode score p95 p99 target frame_valid cost base_cost pwr base_pwr
    awk -v mode="$1" -v score="$2" -v p95="$3" -v p99="$4" -v target="$5" -v fv="$6" -v cost="$7" -v bcost="$8" -v pwr="$9" -v bpwr="${10}" 'BEGIN{
        if (fv < 1) {
            print mode;
            exit;
        }

        promote = (score > 0.55 || p95 > target * 1.22 || p99 > target * 1.55) ? 1 : 0;

        demote = 0;
        if (score < 0.30 && p95 < target * 1.08 && p99 < target * 1.25) {
            if (bcost > 0 && bpwr > 0 && cost > bcost * 1.05 && pwr > bpwr * 1.03) {
                demote = 1;
            }
        }

        if (mode == "powersave" && promote) print "balance";
        else if (mode == "balance" && demote) print "powersave";
        else print mode;
    }'
}

start_lock
trap 'rm -f "$PID_FILE"' EXIT
init_logs

TARGET_MS="$(detect_target_ms)"

START_TS="$(date +%s)"
NEXT_BOOT_EVAL_TS=$((START_TS + BOOT_DELAY_SECONDS))
NEXT_EVAL_TS="$START_TS"
LAST_MODE_SWITCH_TS=0
LAST_APP=""
LAST_MODE_OBS="$(read_mode)"
LAST_P95="0"
LAST_P99="0"
LAST_SCORE="0"

BOOT_EVAL_N=0
BOOT_SAMPLE_COST_SUM="0"
BOOT_SAMPLE_PWR_SUM="0"
BOOT_BASE_COST="0"
BOOT_BASE_PWR="0"

SCREENOFF_EVAL_N=0
LAST_SCREENOFF_EVAL_TS=0
SCREENOFF_BASE_COST="0"
SCREENOFF_BASE_PWR="0"

BASE_SOURCE="dynamic"

while true; do
    now="$(date +%s)"
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    app_pkg="$(get_top_package)"
    mode_now="$(read_mode)"

    inst_metrics="$(instant_cost_pwr)"
    inst_cost="$(echo "$inst_metrics" | cut -d, -f1)"
    inst_pwr="$(echo "$inst_metrics" | cut -d, -f2)"

    if [ -n "$LAST_APP" ] && [ "$app_pkg" != "$LAST_APP" ]; then
        append_event "$ts,APP_SWITCH,$LAST_APP,$LAST_APP,$app_pkg,$mode_now,$inst_cost,$inst_pwr,$LAST_P95,$LAST_P99,$TARGET_MS,$LAST_SCORE,observe,$BASE_SOURCE,switch_with_cost"
    fi
    LAST_APP="$app_pkg"

    if [ "$mode_now" != "$LAST_MODE_OBS" ]; then
        append_event "$ts,MODE_SWITCH,$app_pkg,$LAST_MODE_OBS,$mode_now,$mode_now,$inst_cost,$inst_pwr,$LAST_P95,$LAST_P99,$TARGET_MS,$LAST_SCORE,observe,$BASE_SOURCE,external_or_policy"
        LAST_MODE_OBS="$mode_now"
        LAST_MODE_SWITCH_TS="$now"
    fi

    # Boot baseline eval: starts 2 minutes after boot, every 1 minute, 30 samples.
    if [ "$BOOT_EVAL_N" -lt "$BOOT_EVAL_COUNT" ] && [ "$now" -ge "$NEXT_BOOT_EVAL_TS" ]; then
        smp="$(append_core_sample boot)"
        smp_cost="$(echo "$smp" | cut -d, -f1)"
        smp_pwr="$(echo "$smp" | cut -d, -f2)"

        BOOT_EVAL_N=$((BOOT_EVAL_N + 1))
        NEXT_BOOT_EVAL_TS=$((NEXT_BOOT_EVAL_TS + BOOT_EVAL_INTERVAL))

        BOOT_SAMPLE_COST_SUM="$(awk -v a="$BOOT_SAMPLE_COST_SUM" -v b="$smp_cost" 'BEGIN{printf "%.6f", a+b}')"
        BOOT_SAMPLE_PWR_SUM="$(awk -v a="$BOOT_SAMPLE_PWR_SUM" -v b="$smp_pwr" 'BEGIN{printf "%.6f", a+b}')"

        append_event "$ts,BASE_EVAL,$app_pkg,$mode_now,$mode_now,$mode_now,$smp_cost,$smp_pwr,0,0,$TARGET_MS,0.000000,boot_collect,$BASE_SOURCE,boot_1min_sample_${BOOT_EVAL_N}"

        if [ "$BOOT_EVAL_N" -ge "$BOOT_EVAL_COUNT" ]; then
            med="$(compute_phase_medians boot)"
            BOOT_BASE_COST="$(echo "$med" | cut -d, -f1)"
            BOOT_BASE_PWR="$(echo "$med" | cut -d, -f2)"
            BASE_SOURCE="boot"
            append_event "$ts,BASELINE,$app_pkg,$mode_now,$mode_now,$mode_now,$BOOT_BASE_COST,$BOOT_BASE_PWR,0,0,$TARGET_MS,0.000000,boot_ready,$BASE_SOURCE,boot_median_ready"
        fi
    fi

    # Screen-off final baseline: every 3 minutes only when screen is off, 50 samples.
    if [ "$BOOT_EVAL_N" -ge "$BOOT_EVAL_COUNT" ] && [ "$SCREENOFF_EVAL_N" -lt "$SCREENOFF_EVAL_COUNT" ]; then
        screen_off="$(screen_is_off)"
        if [ "$screen_off" = "true" ]; then
            if [ "$LAST_SCREENOFF_EVAL_TS" -eq 0 ] || [ $((now - LAST_SCREENOFF_EVAL_TS)) -ge "$SCREENOFF_EVAL_INTERVAL" ]; then
                smp_off="$(append_core_sample screenoff)"
                off_cost="$(echo "$smp_off" | cut -d, -f1)"
                off_pwr="$(echo "$smp_off" | cut -d, -f2)"

                SCREENOFF_EVAL_N=$((SCREENOFF_EVAL_N + 1))
                LAST_SCREENOFF_EVAL_TS="$now"

                append_event "$ts,BASE_EVAL,$app_pkg,$mode_now,$mode_now,$mode_now,$off_cost,$off_pwr,0,0,$TARGET_MS,0.000000,screenoff_collect,$BASE_SOURCE,screenoff_3min_sample_${SCREENOFF_EVAL_N}"

                if [ "$SCREENOFF_EVAL_N" -ge "$SCREENOFF_EVAL_COUNT" ]; then
                    med_off="$(compute_phase_medians screenoff)"
                    SCREENOFF_BASE_COST="$(echo "$med_off" | cut -d, -f1)"
                    SCREENOFF_BASE_PWR="$(echo "$med_off" | cut -d, -f2)"
                    BASE_SOURCE="screenoff_final"
                    append_event "$ts,BASELINE,$app_pkg,$mode_now,$mode_now,$mode_now,$SCREENOFF_BASE_COST,$SCREENOFF_BASE_PWR,0,0,$TARGET_MS,0.000000,screenoff_ready,$BASE_SOURCE,screenoff_median_ready"
                fi
            fi
        fi
    fi

    if [ "$BASE_SOURCE" = "screenoff_final" ]; then
        base_cost="$SCREENOFF_BASE_COST"
        base_pwr="$SCREENOFF_BASE_PWR"
    elif [ "$BASE_SOURCE" = "boot" ]; then
        base_cost="$BOOT_BASE_COST"
        base_pwr="$BOOT_BASE_PWR"
    elif [ "$BOOT_EVAL_N" -gt 0 ]; then
        base_cost="$(awk -v s="$BOOT_SAMPLE_COST_SUM" -v n="$BOOT_EVAL_N" 'BEGIN{if(n>0) printf "%.6f", s/n; else print "0"}')"
        base_pwr="$(awk -v s="$BOOT_SAMPLE_PWR_SUM" -v n="$BOOT_EVAL_N" 'BEGIN{if(n>0) printf "%.6f", s/n; else print "0"}')"
    else
        base_cost="$inst_cost"
        base_pwr="$inst_pwr"
    fi

    if [ "$now" -ge "$NEXT_EVAL_TS" ]; then
        NEXT_EVAL_TS=$((now + EVAL_INTERVAL))

        read_frame_tail "$app_pkg"
        frame_valid=0
        if awk -v a="$FRAME_P95" -v b="$FRAME_P99" 'BEGIN{exit !((a+0)>0 || (b+0)>0)}'; then
            frame_valid=1
        fi

        score="$(calc_joint_score "$FRAME_P95" "$FRAME_P99" "$TARGET_MS" "$inst_cost" "$base_cost" "$inst_pwr" "$base_pwr")"

        LAST_P95="$FRAME_P95"
        LAST_P99="$FRAME_P99"
        LAST_SCORE="$score"

        append_event "$ts,EVAL,$app_pkg,$mode_now,$mode_now,$mode_now,$inst_cost,$inst_pwr,$FRAME_P95,$FRAME_P99,$TARGET_MS,$score,closedloop,$BASE_SOURCE,pwr_tail_joint"

        if should_manage_pkg "$app_pkg"; then
            if [ "$mode_now" = "balance" ] || [ "$mode_now" = "powersave" ]; then
                desired_mode="$(choose_mode "$mode_now" "$score" "$FRAME_P95" "$FRAME_P99" "$TARGET_MS" "$frame_valid" "$inst_cost" "$base_cost" "$inst_pwr" "$base_pwr")"
                if [ "$desired_mode" != "$mode_now" ] && [ $((now - LAST_MODE_SWITCH_TS)) -ge "$MIN_SWITCH_INTERVAL" ]; then
                    echo "$desired_mode" >"$STATE_FILE"
                    append_event "$ts,MODE_SWITCH,$app_pkg,$mode_now,$desired_mode,$desired_mode,$inst_cost,$inst_pwr,$FRAME_P95,$FRAME_P99,$TARGET_MS,$score,closedloop,$BASE_SOURCE,closed_loop"
                    LAST_MODE_OBS="$desired_mode"
                    LAST_MODE_SWITCH_TS="$now"
                fi
            fi
        fi
    fi

    sleep "$LOOP_INTERVAL"
done
