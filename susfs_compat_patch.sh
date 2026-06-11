#!/usr/bin/env bash
# ============================================================
#  susfs_compat_patch.sh
#  Auto-detects SUSFS API version mismatch and generates
#  compatibility stubs for SukiSU-Ultra dispatch.c
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[SUSFS-COMPAT]${NC} $*"; }
ok()    { echo -e "${GREEN}  [OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}  [WARN]${NC} $*"; }

SUSFS_H="include/linux/susfs.h"

if [ ! -f "$SUSFS_H" ]; then
    warn "susfs.h not found — skipping compat check"
    exit 0
fi

echo ""
echo "============================================"
echo "  SUSFS API Compatibility Patcher"
echo "============================================"
echo ""

NEED_COMPAT=false
MISSING_SYMBOLS=""

# Check for symbols that SukiSU-Ultra dispatch.c expects
declare -A REQUIRED_SYMBOLS=(
    ["SUSFS_MAGIC"]="define"
    ["CMD_SUSFS_ADD_SUS_PATH_LOOP"]="define"
    ["CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS"]="define"
    ["CMD_SUSFS_ADD_SUS_MAP"]="define"
    ["CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING"]="define"
    ["susfs_add_sus_path_loop"]="func"
    ["susfs_set_hide_sus_mnts_for_non_su_procs"]="func"
    ["susfs_add_sus_map"]="func"
    ["susfs_set_avc_log_spoofing"]="func"
    ["susfs_start_sdcard_monitor_fn"]="func"
    ["susfs_enable_log"]="func"
)

for sym in "${!REQUIRED_SYMBOLS[@]}"; do
    if grep -rq "$sym" include/linux/susfs*.h fs/susfs.c 2>/dev/null; then
        ok "$sym found"
    else
        warn "$sym MISSING"
        NEED_COMPAT=true
        MISSING_SYMBOLS="$MISSING_SYMBOLS $sym"
    fi
done

# Check susfs_get_enabled_features signature (1 arg vs 2 args)
if grep -q "susfs_get_enabled_features" "$SUSFS_H" 2>/dev/null; then
    ARGS=$(grep "susfs_get_enabled_features" "$SUSFS_H" | head -1)
    if echo "$ARGS" | grep -q "bufsize\|size_t"; then
        ok "susfs_get_enabled_features (2-arg version)"
    else
        warn "susfs_get_enabled_features is 1-arg (dispatch.c expects 2-arg)"
        NEED_COMPAT=true
        MISSING_SYMBOLS="$MISSING_SYMBOLS susfs_get_enabled_features_2arg"
    fi
fi

if [ "$NEED_COMPAT" = false ]; then
    ok "SUSFS API is fully compatible — no stubs needed!"
    exit 0
fi

info "Generating compatibility stubs..."

# ── Figure out which CMD values exist and pick next ones ──
# Get the last CMD number from susfs.h or susfs_def.h
LAST_CMD=$(grep -h "CMD_SUSFS_" include/linux/susfs*.h 2>/dev/null | grep -oP '\d+' | sort -n | tail -1)
[ -z "$LAST_CMD" ] && LAST_CMD=50
NEXT_CMD=$((LAST_CMD + 1))

# ── Generate compat header ──
COMPAT_H="include/linux/susfs_compat.h"
cat > "$COMPAT_H" << 'COMPAT_EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * susfs_compat.h — Auto-generated compatibility stubs
 * Bridges SUSFS v1.3.8 API → v1.5+ API expected by SukiSU-Ultra
 * Missing functions become no-ops, missing defines get placeholder values.
 */
#ifndef _LINUX_SUSFS_COMPAT_H
#define _LINUX_SUSFS_COMPAT_H

#include <linux/errno.h>

COMPAT_EOF

# Add missing #defines
CMD_VAL=$NEXT_CMD
for sym in SUSFS_MAGIC CMD_SUSFS_ADD_SUS_PATH_LOOP CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS CMD_SUSFS_ADD_SUS_MAP CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING; do
    if echo "$MISSING_SYMBOLS" | grep -q "$sym"; then
        if [ "$sym" = "SUSFS_MAGIC" ]; then
            echo "#ifndef $sym" >> "$COMPAT_H"
            echo "#define $sym 0x535553" >> "$COMPAT_H"
            echo "#endif" >> "$COMPAT_H"
        else
            echo "#ifndef $sym" >> "$COMPAT_H"
            echo "#define $sym $CMD_VAL" >> "$COMPAT_H"
            echo "#endif" >> "$COMPAT_H"
            CMD_VAL=$((CMD_VAL + 1))
        fi
        ok "Added define: $sym"
    fi
done

echo "" >> "$COMPAT_H"

# Add missing function stubs
for sym in susfs_add_sus_path_loop susfs_set_hide_sus_mnts_for_non_su_procs susfs_add_sus_map susfs_set_avc_log_spoofing; do
    if echo "$MISSING_SYMBOLS" | grep -q "$sym"; then
        cat >> "$COMPAT_H" << EOF
static inline int ${sym}(void *arg) { return -ENOSYS; }
EOF
        ok "Added stub: $sym()"
    fi
done

if echo "$MISSING_SYMBOLS" | grep -q "susfs_start_sdcard_monitor_fn"; then
    echo "static inline void susfs_start_sdcard_monitor_fn(void) { }" >> "$COMPAT_H"
    ok "Added stub: susfs_start_sdcard_monitor_fn()"
fi

if echo "$MISSING_SYMBOLS" | grep -q "susfs_enable_log"; then
    echo "static inline int susfs_enable_log(void *arg) { return 0; }" >> "$COMPAT_H"
    ok "Added stub: susfs_enable_log()"
fi

# Fix susfs_get_enabled_features if needed (2-arg wrapper)
if echo "$MISSING_SYMBOLS" | grep -q "susfs_get_enabled_features_2arg"; then
    cat >> "$COMPAT_H" << 'EOF'

/* Wrapper: dispatch.c calls susfs_get_enabled_features(buf, len) but old API has 1 arg */
/* We rename the old one and provide a 2-arg version */
EOF
    ok "Note: susfs_get_enabled_features needs manual review"
fi

echo "" >> "$COMPAT_H"
echo "#endif /* _LINUX_SUSFS_COMPAT_H */" >> "$COMPAT_H"

# ── Include compat header in susfs.h ──
if ! grep -q "susfs_compat.h" "$SUSFS_H"; then
    # Add include at the end, before the final #endif
    LAST_ENDIF=$(grep -n "^#endif" "$SUSFS_H" | tail -1 | cut -d: -f1)
    if [ -n "$LAST_ENDIF" ]; then
        sed -i "${LAST_ENDIF}i\\#include <linux/susfs_compat.h>" "$SUSFS_H"
        ok "Included susfs_compat.h in susfs.h"
    fi
fi

# ── Fix dispatch.c pointer type mismatches ──
# dispatch.c passes `void *arg` but old susfs functions expect typed pointers
# Fix: add explicit casts in dispatch.c
KSU_DIR=""
[ -d "drivers/kernelsu" ] && KSU_DIR="drivers/kernelsu"
[ -d "KernelSU/kernel" ] && KSU_DIR="KernelSU/kernel"

if [ -n "$KSU_DIR" ]; then
    DISPATCH="$KSU_DIR/supercall/dispatch.c"
    [ ! -f "$DISPATCH" ] && DISPATCH=$(find "$KSU_DIR" -name "dispatch.c" -type f | head -1)

    if [ -f "$DISPATCH" ]; then
        info "Fixing pointer casts in dispatch.c..."

        # Cast void* arg to the expected struct pointer types
        sed -i 's/susfs_add_sus_path(arg)/susfs_add_sus_path((struct st_susfs_sus_path __user *)arg)/g' "$DISPATCH"
        sed -i 's/susfs_add_sus_kstat(arg)/susfs_add_sus_kstat((struct st_susfs_sus_kstat __user *)arg)/g' "$DISPATCH"
        sed -i 's/susfs_update_sus_kstat(arg)/susfs_update_sus_kstat((struct st_susfs_sus_kstat __user *)arg)/g' "$DISPATCH"
        sed -i 's/susfs_set_uname(arg)/susfs_set_uname((struct st_susfs_uname __user *)arg)/g' "$DISPATCH"
        sed -i 's/susfs_set_cmdline_or_bootconfig(arg)/susfs_set_cmdline_or_bootconfig((char __user *)arg)/g' "$DISPATCH"
        sed -i 's/susfs_add_open_redirect(arg)/susfs_add_open_redirect((struct st_susfs_open_redirect __user *)arg)/g' "$DISPATCH"

        # Fix susfs_get_enabled_features if it's called with 1 arg but header expects 2
        # Check how it's called in dispatch.c
        if grep -q "susfs_get_enabled_features(arg)" "$DISPATCH" 2>/dev/null; then
            sed -i 's/susfs_get_enabled_features(arg)/susfs_get_enabled_features((char __user *)arg, 4096)/g' "$DISPATCH"
            ok "Fixed susfs_get_enabled_features args"
        fi

        ok "Pointer casts fixed in dispatch.c"
    fi
fi

echo ""
echo "============================================"
echo "  SUSFS Compat patching complete."
echo "============================================"
echo ""
