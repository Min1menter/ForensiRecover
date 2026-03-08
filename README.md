# ForensiRecover

A Bash-based digital forensics and file recovery automation tool for disk image analysis. It combines file system inspection, forensic timeline generation, deleted file recovery, optional full-disk carving, and SHA-256 based deduplication into one workflow.

## Features

- Runs `fsstat` to inspect file system metadata and extract values like file system type, sector size, cluster size, and partition offset.
- Builds a forensic timeline using `fls` and `mactime`.
- Recovers deleted files using `tsk_recover`.
- Supports optional full-disk carving with `Foremost` and `Scalpel`.
- Removes duplicate recovered/carved files using SHA-256 hashing.
- Saves logs and outputs in a timestamped output directory.
- Validates required tools before execution.

## Technologies Used

- Bash
- Linux/Unix command-line tools
- The Sleuth Kit (`fsstat`, `fls`, `mactime`, `tsk_recover`)
- Foremost
- Scalpel
- SHA-256 (`sha256sum`)
- awk, sed, grep, sort, uniq, find, tee

## Project Workflow

1. Accepts a disk image as input.
2. Checks that required forensic and shell tools are installed.
3. Extracts file system details using `fsstat`.
4. Creates a bodyfile and generates a MAC timeline.
5. Recovers deleted files from the image.
6. Optionally performs full-disk carving.
7. Deduplicates carved files using hash comparison.
8. Stores all outputs and logs in a structured output folder.

## Usage

```bash
chmod +x recover.sh
./recover.sh image.img
```

## Output Structure

The script creates a timestamped directory similar to:

```text
forensic_out_YYYYMMDD_HHMMSS/
├── fsstat.txt
├── bodyfile.txt
├── mactime_timeline.txt
├── recovered_deleted_files/
├── carved_full_disk/
├── dedup_deleted_files.log
├── errors.log
├── tsk_recover_deleted.log
├── foremost_full_disk.log
└── scalpel_full_disk.log
```

## Requirements

Make sure these tools are installed:

```bash
fsstat
fls
mactime
tsk_recover
sha256sum
awk
sed
grep
sort
uniq
find
tee
```

Optional:

```bash
foremost
scalpel
```

Please feel free to use this tool, and for any kind of error, please feel free to contact.😌😌
