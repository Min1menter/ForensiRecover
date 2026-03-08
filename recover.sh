
#!/usr/bin/env bash
set -euo pipefail

# =============================
# Usage
# =============================
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <image.img>"
  exit 1
fi

IMAGE="$1"
[[ -f "$IMAGE" ]] || { echo "[-] Image not found: $IMAGE"; exit 1; }

# =============================
# Required tools
# =============================
for cmd in fsstat fls mactime tsk_recover awk sed grep sort uniq wc date tr sha256sum find tee; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[-] Missing tool: $cmd"; exit 1; }
done

# Optional carving tools
HAVE_FOREMOST=0; command -v foremost >/dev/null 2>&1 && HAVE_FOREMOST=1
HAVE_SCALPEL=0;  command -v scalpel  >/dev/null 2>&1 && HAVE_SCALPEL=1

# =============================
# Ask user about carving
# =============================
DO_CARVE=0
echo
read -rp "[?] After recovery, do you want FULL-DISK carving (Foremost + optional Scalpel)? (y/n): " ans
case "$ans" in
  y|Y) DO_CARVE=1 ;;
  *)   DO_CARVE=0 ;;
esac
echo

# =============================
# Output setup
# =============================
OUTDIR="forensic_out_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"

FSSTAT_TXT="$OUTDIR/fsstat.txt"
BODYFILE="$OUTDIR/bodyfile.txt"
TIMELINE_TXT="$OUTDIR/mactime_timeline.txt"
RECOV_DIR="$OUTDIR/recovered_deleted_files"
CARVE_DIR="$OUTDIR/carved_full_disk"
DEDUP_LOG="$OUTDIR/dedup_deleted_files.log"
ERRLOG="$OUTDIR/errors.log"

mkdir -p "$RECOV_DIR" "$CARVE_DIR"
: > "$ERRLOG"
: > "$DEDUP_LOG"

echo "[+] Image  : $IMAGE"
echo "[+] Output : $OUTDIR"
echo

# =============================
# Step 1: fsstat
# =============================
echo "[+] Running fsstat..."
fsstat "$IMAGE" | tee "$FSSTAT_TXT" >/dev/null || true
echo "[+] fsstat saved to $FSSTAT_TXT"
echo
FS_TYPE="$(grep -m1 -E '^File System Type:' "$FSSTAT_TXT" | sed 's/.*: *//')"
SECTOR_SIZE="$(grep -m1 -E '^Sector Size:' "$FSSTAT_TXT" | awk -F':' '{gsub(/ /,"",$2); print $2}')"
CLUSTER_SIZE="$(grep -m1 -E '^Cluster Size:' "$FSSTAT_TXT" | awk -F':' '{gsub(/ /,"",$2); print $2}')"
PART_OFF_BYTES="$(grep -m1 -E '^Partition Offset:' "$FSSTAT_TXT" | awk -F':' '{gsub(/ /,"",$2); print $2}')"

# Defaults if fsstat didn’t return something
SECTOR_SIZE="${SECTOR_SIZE:-512}"
CLUSTER_SIZE="${CLUSTER_SIZE:-0}"
PART_OFF_BYTES="${PART_OFF_BYTES:-0}"

OFFSET_SECTORS="0"
if [[ "$PART_OFF_BYTES" =~ ^[0-9]+$ ]] && [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] && [[ "$SECTOR_SIZE" -gt 0 ]]; then
  if (( PART_OFF_BYTES % SECTOR_SIZE == 0 )); then
    OFFSET_SECTORS=$(( PART_OFF_BYTES / SECTOR_SIZE ))
  fi
fi

# Normalize FS type for -f (TSK expects lowercase like exfat, ntfs, fat, ext)
FS_FLAG="$(echo "${FS_TYPE:-}" | tr '[:upper:]' '[:lower:]' | awk '{print $1}')"
# common cleanup
case "$FS_FLAG" in
  exfat) FS_FLAG="exfat" ;;
  ntfs)  FS_FLAG="ntfs" ;;
  fat*|msdos) FS_FLAG="fat" ;;
  ext* ) FS_FLAG="ext" ;;
  *) FS_FLAG="" ;; # unknown/unneeded
esac

echo "===== fsstat summary ====="
echo "File System Type : ${FS_TYPE:-UNKNOWN}"
echo "Sector Size      : $SECTOR_SIZE"
echo "Cluster Size     : $CLUSTER_SIZE"
echo "Partition Offset : $PART_OFF_BYTES bytes  (= $OFFSET_SECTORS sectors)"
echo "FS flag (-f)     : ${FS_FLAG:-<auto>}"
echo "=========================="
echo

# =============================
# Step 2: Timeline creation (BEFORE recovery)
# =============================
echo "[+] Creating bodyfile using fls..."
fls -r -m / "$IMAGE" > "$BODYFILE" 2>>"$ERRLOG"
echo "[+] Bodyfile created: $BODYFILE"

echo "[+] Creating timeline using mactime..."
mactime -b "$BODYFILE" > "$TIMELINE_TXT" 2>>"$ERRLOG"
echo "[+] Timeline created: $TIMELINE_TXT"
echo
echo "[!] NOTE: XXX timestamps are normal on exFAT and deleted entries."
echo

# =============================
# Step 3: Deleted-only recovery using tsk_recover
# =============================
echo "[+] Recovering deleted files using tsk_recover..."
echo "[+] Output directory: $RECOV_DIR"
tsk_recover -e "$IMAGE" "$RECOV_DIR" \
  2>&1 | tee "$OUTDIR/tsk_recover_deleted.log"
echo "[+] Deleted-file recovery completed."
echo

# =============================
# Post-carving dedup function
# =============================
dedup_by_hash_delete() {
  local target_dir="$1"
  echo "[*] Post-carving SHA-256 hashing + deduplication"
  echo "[*] Target: $target_dir"
  echo "[*] Duplicate deletions logged in: $DEDUP_LOG"
  echo

  find "$target_dir" -type f \
    ! -name "audit.txt" ! -name "*.log" \
    -print0 \
    | xargs -0 -r sha256sum \
    | awk '
      {
        h=$1; f=$2;
        if (!seen[h]) {
          seen[h]=f;
        } else {
          printf("[DUP] %s\n keep: %s\n del : %s\n\n", h, seen[h], f) >> log;
          system("rm -f \"" f "\"");
          del++;
        }
      }
      END {
        printf("[*] Deduplication complete. Deleted duplicates: %d\n", del) > "/dev/stderr";
      }
    ' log="$DEDUP_LOG" 2>&1 | tee -a "$DEDUP_LOG" >/dev/null || true
}

# =============================
# Full-disk carving
# =============================
carve_full_disk() {
  echo "[*] FULL-DISK carving started"
  echo "[*] Output directory: $CARVE_DIR"
  echo

  # ---------- FOREMOST ----------
  if [[ $HAVE_FOREMOST -eq 1 ]]; then
    echo "[*] Running foremost..."
    foremost -i "$IMAGE" -o "$CARVE_DIR/foremost" \
      2>&1 | tee "$OUTDIR/foremost_full_disk.log" || true
    echo
  else
    echo "[!] foremost not installed, skipping."
    echo
  fi

  # ---------- SCALPEL (prompt separately) ----------
  if [[ $HAVE_SCALPEL -eq 1 ]]; then
    echo "[!] Scalpel uses DEFAULT config file."
    echo "[!] Enable file types in /etc/scalpel/scalpel.conf"
    read -rp "[?] Run Scalpel now? (y/n): " s_ans
    case "$s_ans" in
      y|Y)
        echo "[*] Running scalpel (verbose)..."
        sudo scalpel -o "$CARVE_DIR/scalpel" "$IMAGE" \
          2>&1 | tee "$OUTDIR/scalpel_full_disk.log" || true
        ;;
      *)
        echo "[*] Scalpel skipped by user."
        ;;
    esac
    echo
  else
    echo "[!] scalpel not installed, skipping."
    echo
  fi

  echo "[*] FULL-DISK carving finished."
  echo

  # Deduplicate carved files
  dedup_by_hash_delete "$CARVE_DIR"
}

# =============================
# Run carving if user agreed
# =============================
if [[ $DO_CARVE -eq 1 ]]; then
  carve_full_disk
fi

# =============================
# Final summary
# =============================
echo "================ FINAL SUMMARY ================"
echo "[+] fsstat              : $FSSTAT_TXT"
echo "[+] Timeline (mactime)  : $TIMELINE_TXT"
echo "[+] Deleted recovery    : $RECOV_DIR"
if [[ $DO_CARVE -eq 1 ]]; then
  echo "[+] Carved files        : $CARVE_DIR"
  echo "[+] Dedup log           : $DEDUP_LOG"
fi
echo "[+] Errors              : $ERRLOG"
echo "=============================================="
