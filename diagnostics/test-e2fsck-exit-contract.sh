#!/bin/bash
# Tests the e2fsck exit-code contract underpinning the WSL sparse-VHD trim fix.
# Validates that:
#   exit 0 = clean filesystem (no changes)
#   exit 1 = repaired filesystem (FILE SYSTEM WAS MODIFIED)
#   exit >1 = fatal error
# The PR fix changes UtilExecCommandLine({0}) -> ({0,1}) so that a repaired
# ext4 does not falsely cause trim to be reported as failed to the service.

PASS=0; FAIL=0

check() {
    local desc="$1"; shift
    local expected="$1"; shift
    "$@" >/dev/null 2>&1
    local actual=$?
    if [ "$actual" -eq "$expected" ]; then
        echo "PASS [$desc]: exit $actual"
        PASS=$((PASS+1))
    else
        echo "FAIL [$desc]: expected exit $expected, got $actual"
        FAIL=$((FAIL+1))
    fi
}

make_image() {
    local path=$1; local mb=${2:-32}
    dd if=/dev/zero of="$path" bs=1M count="$mb" status=none
    mkfs.ext4 -q "$path"
}

corrupt_block_bitmap() {
    # Clears the first byte of the block bitmap so e2fsck must repair it.
    python3 -c "
import struct, sys
path = sys.argv[1]
with open(path,'r+b') as f:
    f.seek(1024)
    sb=f.read(1024)
    bs=1024<<struct.unpack_from('<I',sb,24)[0]
    f.seek(bs)            # GDT at block 1 (for block_size>=2048, block 0 for 1024)
    gdt=f.read(64)
    bb=struct.unpack_from('<I',gdt,0)[0]
    f.seek(bb*bs)
    bm=bytearray(f.read(bs))
    bm[0]=0x00
    f.seek(bb*bs)
    f.write(bytes(bm))
" "$1"
}

echo "=== e2fsck exit-code contract test ==="
echo ""

# Test 1: clean fs -> exit 0
IMG1=$(mktemp /tmp/e2_XXXXXX.img)
make_image "$IMG1"
check "clean fs exits 0" 0 e2fsck -f -y -E discard "$IMG1"

# Test 2: corrupt block bitmap -> e2fsck repairs -> exits 1
IMG2=$(mktemp /tmp/e2_XXXXXX.img)
make_image "$IMG2"
corrupt_block_bitmap "$IMG2"
check "repaired fs exits 1" 1 e2fsck -f -y -E discard "$IMG2"

# Test 3: after repair, re-run -> exits 0 (filesystem is now clean)
check "post-repair re-run exits 0" 0 e2fsck -f -y -E discard "$IMG2"

# Test 4: fatal error (invalid image) -> exits 8
IMG3=$(mktemp /tmp/e2_XXXXXX.img)
dd if=/dev/urandom of="$IMG3" bs=1M count=1 status=none
check "invalid image exits 8" 8 e2fsck -f -y "$IMG3"

echo ""
echo "=== Impact on ResponseCode logic ==="
echo ""
echo "BEFORE fix (ExpectedStatuses={0}):"
echo "  e2fsck exits 1 -> UtilExecCommandLine returns -1 -> trim reported FAILED to service (BUG)"
echo "  e2fsck exits 0 -> UtilExecCommandLine returns  0 -> trim reported SUCCESS"
echo ""
echo "AFTER fix (ExpectedStatuses={0,1}):"
echo "  e2fsck exits 1 -> UtilExecCommandLine returns  0 -> trim reported SUCCESS (FIXED)"
echo "  e2fsck exits 0 -> UtilExecCommandLine returns  0 -> trim reported SUCCESS"
echo "  e2fsck exits 8 -> UtilExecCommandLine returns -1 -> trim reported FAILED (correct)"
echo ""

echo "Results: $PASS passed, $FAIL failed"
rm -f "$IMG1" "$IMG2" "$IMG3"
[ "$FAIL" -eq 0 ] && echo "ALL PASSED" && exit 0 || { echo "FAILURES DETECTED"; exit 1; }
