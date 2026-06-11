#!/usr/bin/env bash
# ============================================================
#  apply_hooks.sh — SukiSU-Ultra Manual Hook Patcher (Robust)
#
#  Uses grep -n to find EXACT line numbers, then inserts
#  hook code at precise positions. Avoids sed range-matching
#  bugs that cause insertions in wrong functions.
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[HOOK]${NC} $*"; }
ok()    { echo -e "${GREEN}  [OK]${NC} $*"; }
skip()  { echo -e "${YELLOW}  [SKIP]${NC} $*"; }
fail()  { echo -e "${RED}  [FAIL]${NC} $*"; }

# Helper: Find first line number matching pattern
find_line() {
    grep -n "$2" "$1" | head -1 | cut -d: -f1
}

# Helper: Find first line matching pattern AFTER a given line
find_line_after() {
    local file="$1" start="$2" pattern="$3"
    tail -n +"$start" "$file" | grep -n "$pattern" | head -1 | awk -F: -v s="$start" '{print $1 + s - 1}'
}

echo ""
echo "============================================"
echo "  SukiSU-Ultra Manual Hook Patcher"
echo "============================================"
echo ""

# ═══════════════════════════════════════════════
# 1. fs/exec.c — Hook do_execveat_common()
# ═══════════════════════════════════════════════
FILE="fs/exec.c"
info "Patching $FILE ..."

if grep -q "ksu_handle_execveat" "$FILE"; then
    skip "already patched."
else
    FUNC_LINE=$(find_line "$FILE" "^static int do_execveat_common")
    if [ -z "$FUNC_LINE" ]; then
        fail "do_execveat_common not found in $FILE"
    else
        EXTERN_BLOCK='#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n\t\t\tvoid *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n\t\t\t\t void *argv, void *envp, int *flags);\n#endif'
        sed -i "${FUNC_LINE}i\\${EXTERN_BLOCK}" "$FILE"

        FUNC_LINE=$(find_line "$FILE" "^static int do_execveat_common")
        RETURN_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "return .*__do_execve\|return .*do_execveat\|return retval")
        if [ -z "$RETURN_LINE" ]; then
            BRACE_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "^{")
            RETURN_LINE=$(find_line_after "$FILE" "$BRACE_LINE" "return ")
        fi

        if [ -n "$RETURN_LINE" ]; then
            HOOK_CODE='#ifdef CONFIG_KSU\n\tif (unlikely(ksu_execveat_hook))\n\t\tksu_handle_execveat(\&fd, \&filename, \&argv, \&envp, \&flags);\n\telse\n\t\tksu_handle_execveat_sucompat(\&fd, \&filename, \&argv, \&envp, \&flags);\n#endif'
            sed -i "${RETURN_LINE}i\\${HOOK_CODE}" "$FILE"
            ok "Patched at line $RETURN_LINE (before return)"
        else
            fail "Could not find return statement in do_execveat_common"
        fi
    fi
fi

# ═══════════════════════════════════════════════
# 2. fs/open.c — Hook do_faccessat()
# ═══════════════════════════════════════════════
FILE="fs/open.c"
info "Patching $FILE ..."

if grep -q "ksu_handle_faccessat" "$FILE"; then
    skip "already patched."
else
    FUNC_LINE=$(find_line "$FILE" "^long do_faccessat")
    if [ -z "$FUNC_LINE" ]; then
        FUNC_LINE=$(find_line "$FILE" "SYSCALL_DEFINE3(faccessat")
        TARGET="SYSCALL_DEFINE3"
    else
        TARGET="do_faccessat"
    fi

    if [ -z "$FUNC_LINE" ]; then
        fail "Neither do_faccessat nor SYSCALL_DEFINE3(faccessat) found"
    else
        EXTERN='#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t int *flags);\n#endif'
        sed -i "${FUNC_LINE}i\\${EXTERN}" "$FILE"

        if [ "$TARGET" = "do_faccessat" ]; then
            FUNC_LINE=$(find_line "$FILE" "^long do_faccessat")
        else
            FUNC_LINE=$(find_line "$FILE" "SYSCALL_DEFINE3(faccessat")
        fi

        INSERT_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "if (mode & ~S_IRWXO)")
        if [ -n "$INSERT_LINE" ]; then
            HOOK='#ifdef CONFIG_KSU\n\tksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\n#endif'
            sed -i "${INSERT_LINE}i\\${HOOK}" "$FILE"
            ok "Patched at line $INSERT_LINE (before mode check) [target: $TARGET]"
        else
            fail "Could not find 'if (mode & ~S_IRWXO)' in $TARGET"
        fi
    fi
fi

# ═══════════════════════════════════════════════
# 3. fs/read_write.c — Hook vfs_read()
# ═══════════════════════════════════════════════
FILE="fs/read_write.c"
info "Patching $FILE ..."

if grep -q "ksu_handle_vfs_read" "$FILE"; then
    skip "already patched."
else
    FUNC_LINE=$(find_line "$FILE" "^ssize_t vfs_read(")
    if [ -z "$FUNC_LINE" ]; then
        fail "vfs_read function not found in $FILE"
    else
        info "  Found vfs_read at line $FUNC_LINE"

        EXTERN='#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n\t\t\tsize_t *count_ptr, loff_t **pos);\n#endif'
        sed -i "${FUNC_LINE}i\\${EXTERN}" "$FILE"

        FUNC_LINE=$(find_line "$FILE" "^ssize_t vfs_read(")

        INSERT_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "if (!(file->f_mode & FMODE_READ))")
        if [ -n "$INSERT_LINE" ]; then
            DISTANCE=$((INSERT_LINE - FUNC_LINE))
            if [ "$DISTANCE" -gt 30 ]; then
                fail "FMODE_READ check found at line $INSERT_LINE but too far ($DISTANCE lines). Skipping."
                INSERT_LINE=""
            fi
        fi

        if [ -n "$INSERT_LINE" ]; then
            HOOK='#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_vfs_read(\&file, \&buf, \&count, \&pos);\n#endif'
            sed -i "${INSERT_LINE}i\\${HOOK}" "$FILE"
            ok "Patched at line $INSERT_LINE (before FMODE_READ check)"
        else
            RET_DECL=$(find_line_after "$FILE" "$FUNC_LINE" "ssize_t ret")
            if [ -n "$RET_DECL" ]; then
                HOOK='#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_vfs_read(\&file, \&buf, \&count, \&pos);\n#endif'
                AFTER=$((RET_DECL + 1))
                sed -i "${AFTER}i\\${HOOK}" "$FILE"
                ok "Patched at line $AFTER (after ssize_t ret)"
            else
                fail "Could not find safe insertion point in vfs_read"
            fi
        fi
    fi
fi

# ═══════════════════════════════════════════════
# 4. fs/stat.c — Hook vfs_statx() or vfs_fstatat()
# ═══════════════════════════════════════════════
FILE="fs/stat.c"
info "Patching $FILE ..."

if grep -q "ksu_handle_stat" "$FILE"; then
    skip "already patched."
else
    FUNC_LINE=$(find_line "$FILE" "^int vfs_statx(")
    if [ -n "$FUNC_LINE" ]; then
        FUNC_NAME="vfs_statx"
        FLAG_VAR="flags"
    else
        FUNC_LINE=$(find_line "$FILE" "^int vfs_fstatat(")
        FUNC_NAME="vfs_fstatat"
        FLAG_VAR="flag"
    fi

    if [ -z "$FUNC_LINE" ]; then
        fail "Neither vfs_statx nor vfs_fstatat found in $FILE"
    else
        info "  Found $FUNC_NAME at line $FUNC_LINE"

        EXTERN='#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif'
        sed -i "${FUNC_LINE}i\\${EXTERN}" "$FILE"

        FUNC_LINE=$(find_line "$FILE" "^int ${FUNC_NAME}(")

        INSERT_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "if (")
        if [ -n "$INSERT_LINE" ]; then
            DISTANCE=$((INSERT_LINE - FUNC_LINE))
            if [ "$DISTANCE" -le 20 ]; then
                HOOK="#ifdef CONFIG_KSU\n\tksu_handle_stat(\&dfd, \&filename, \&${FLAG_VAR});\n#endif"
                sed -i "${INSERT_LINE}i\\${HOOK}" "$FILE"
                ok "Patched at line $INSERT_LINE [$FUNC_NAME]"
            else
                fail "First if() too far from $FUNC_NAME ($DISTANCE lines)"
            fi
        else
            fail "No if() found after $FUNC_NAME"
        fi
    fi
fi

# ═══════════════════════════════════════════════
# 5. drivers/input/input.c — Hook input_handle_event()
# ═══════════════════════════════════════════════
FILE="drivers/input/input.c"
info "Patching $FILE ..."

if grep -q "ksu_handle_input_handle_event" "$FILE"; then
    skip "already patched."
else
    FUNC_LINE=$(find_line "$FILE" "^static void input_handle_event")
    if [ -z "$FUNC_LINE" ]; then
        fail "input_handle_event not found in $FILE"
    else
        EXTERN='#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif'
        sed -i "${FUNC_LINE}i\\${EXTERN}" "$FILE"

        FUNC_LINE=$(find_line "$FILE" "^static void input_handle_event")

        INSERT_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "if (disposition != INPUT_IGNORE_EVENT")
        if [ -n "$INSERT_LINE" ]; then
            HOOK='#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\n#endif'
            sed -i "${INSERT_LINE}i\\${HOOK}" "$FILE"
            ok "Patched at line $INSERT_LINE"
        else
            fail "Could not find disposition check in input_handle_event"
        fi
    fi
fi

# ═══════════════════════════════════════════════
# 6. fs/devpts/inode.c — Hook devpts_get_priv()
# ═══════════════════════════════════════════════
FILE="fs/devpts/inode.c"
info "Patching $FILE ..."

if grep -q "ksu_handle_devpts" "$FILE"; then
    skip "already patched."
else
    FUNC_LINE=$(find_line "$FILE" "^void \*devpts_get_priv")
    if [ -z "$FUNC_LINE" ]; then
        fail "devpts_get_priv not found in $FILE"
    else
        EXTERN='#ifdef CONFIG_KSU\nextern int ksu_handle_devpts(struct inode*);\n#endif'
        sed -i "${FUNC_LINE}i\\${EXTERN}" "$FILE"

        FUNC_LINE=$(find_line "$FILE" "^void \*devpts_get_priv")

        INSERT_LINE=$(find_line_after "$FILE" "$FUNC_LINE" "if (dentry->d_sb->s_magic")
        if [ -n "$INSERT_LINE" ]; then
            HOOK='#ifdef CONFIG_KSU\n\tksu_handle_devpts(dentry->d_inode);\n#endif'
            sed -i "${INSERT_LINE}i\\${HOOK}" "$FILE"
            ok "Patched at line $INSERT_LINE"
        else
            fail "Could not find s_magic check in devpts_get_priv"
        fi
    fi
fi

echo ""
echo "============================================"
echo "  Hook patching complete."
echo "============================================"
echo ""
