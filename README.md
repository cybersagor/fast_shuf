# ⚡ fast_shuf

> Shuffled **27.9 GB** · **361 million lines** in **8 minutes 59 seconds**. No external tools. Pure bash.

---

## Why

`shuf` chokes on files larger than RAM. `sort -R` is painfully slow. Nothing else does the job without pulling in Python, Go, or third-party binaries.

`fast_shuf` splits, shuffles all chunks in parallel across every CPU thread, randomizes chunk order, then merges — with live progress bars and ETA at every step.

---

## Benchmarks

| File Size | Lines | Threads | Time |
|---|---|---|---|
| 27.9 GB | 361,110,000 | 16 | **8m 59s** |

_Ryzen 7 7700 · 32 GB RAM · NVMe SSD_

---

## Usage

```bash
chmod +x fast_shuf.sh

# Auto mode (recommended)
./fast_shuf.sh -i urls.txt -o urls_shuffled.txt

# Explicit control
./fast_shuf.sh -i urls.txt -o urls_shuffled.txt -t 16 -c 2000000

# Preview config without running
./fast_shuf.sh -i urls.txt -o urls_shuffled.txt --dry-run

# Reproducible shuffle
./fast_shuf.sh -i urls.txt -o urls_shuffled.txt --seed 42

# Keep temp chunks after completion
./fast_shuf.sh -i urls.txt -o urls_shuffled.txt --keep
```

---

## Options

| Flag | Default | Description |
|---|---|---|
| `-i, --input` | _(required)_ | Input file |
| `-o, --output` | _(required)_ | Output file |
| `-t, --threads` | `nproc` (auto) | Parallel threads |
| `-c, --chunk` | auto-calculated | Lines per chunk |
| `-T, --tmpdir` | `/tmp/fast_shuf_PID` | Temp directory |
| `-s, --seed` | none | Seed for reproducible output |
| `-k, --keep` | false | Keep temp chunks |
| `-d, --dry-run` | false | Show config, don't run |

---

## How It Works

```
Input File
    │
    ▼
 split ──────────────────────────────────────────────┐
    │                                                 │
    ├── chunk_000000  ──► shuf ─┐                    │
    ├── chunk_000001  ──► shuf ─┤                    │
    ├── chunk_000002  ──► shuf ─┤  (all parallel)    │
    ├── ...           ──► shuf ─┤                    │
    └── chunk_000063  ──► shuf ─┘                    │
                                │                    │
                     randomize chunk order           │
                                │                    │
                     cat | shuf (in-memory           │
                     if RAM > file size)             │
                                │                    │
                                ▼                    │
                          Output File ◄──────────────┘
```

**RAM mode** (auto): if free RAM exceeds file size, a final full `shuf` pass runs entirely in memory for true uniform randomness.

**Disk mode** (fallback): chunk-order is randomized before merge for good inter-chunk entropy without loading everything into RAM.

---

## Requirements

- bash 4+
- GNU coreutils (`split`, `shuf`, `wc`, `xargs`, `awk`, `stat`)
- That's it.

---

## Output

```
━━━ Summary ━━━

  Input   : urls.txt (27.95 GB, 361,110,000 lines)
  Output  : urls_shuffled.txt (27.95 GB)
  Chunks  : 64 × ~415 MB
  Threads : 16
  RAM shuf: true

  Timing  :
    Split   : 36s
    Shuffle : 3m 12s
    Merge   : 5m 11s
    Total   : 8m 59s

  Throughput: ~53 MB/s avg

✓ Done.
```

---

## License

Bug Bounty University
