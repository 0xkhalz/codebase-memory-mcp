/*
 * mem.h — Unified memory management via mimalloc.
 *
 * Provides budget tracking based on actual RSS (not partial vmem tracking).
 * Uses mi_process_info() as the single source of truth for memory pressure.
 * Replaces the old vmem.h budget-tracked virtual memory allocator.
 */
#ifndef CBM_MEM_H
#define CBM_MEM_H

#include <stdbool.h>
#include <stddef.h>

/* Tiered default fraction for MCP startup: 25% on <=16GB, 35% on <=32GB, else 50%. */
double cbm_mem_ram_fraction_for_total(size_t total_ram_bytes);

/* Initialize memory budget = ram_fraction * total_physical_ram.
 * The CBM_MEM_BUDGET_MB env var, when set to a positive integer, overrides
 * this with an explicit budget in MiB (clamped to physical/cgroup RAM).
 * Thread-safe: only the first call takes effect.
 * Configures mimalloc options for reduced upfront memory. */
void cbm_mem_init(double ram_fraction);

/* Worker-only initialization cap carried on the build-bound internal argv.
 * The existing user override is still resolved first; a lower explicit
 * CBM_MEM_BUDGET_MB wins, while a larger/default budget is capped. */
void cbm_mem_init_with_cap(double ram_fraction, size_t hard_cap_bytes);

/* Result of cbm_mem_resolve_budget: the resolved budget plus the metadata
 * cbm_mem_init logs — so the parse/clamp logic lives in exactly ONE place and
 * the caller never re-parses the env string. */
typedef struct {
    size_t budget;      /* resolved budget in bytes */
    const char *source; /* log token: "ram_fraction" | "CBM_MEM_BUDGET_MB" */
    bool clamped;       /* override was valid but exceeded total_ram → clamped down */
    bool invalid;       /* override was present but unparseable / out-of-range / ≤0 */
    bool hard_capped;   /* internal worker hard cap reduced the resolved budget */
} cbm_mem_budget_t;

/* Pure budget resolver shared by cbm_mem_init (exposed for testing).
 * Returns ram_fraction * total_ram, unless `budget_mb` is a STRICTLY valid
 * positive integer string (the CBM_MEM_BUDGET_MB override) — then it returns
 * that many MiB, clamped to total_ram when total_ram > 0. Trailing garbage,
 * overflow (ERANGE), and non-positive values are rejected (invalid=true) and
 * fall back to the fraction-derived value. Reads no globals/env. */
cbm_mem_budget_t cbm_mem_resolve_budget(size_t total_ram, double ram_fraction,
                                        const char *budget_mb);

/* Pure capped variant used by supervised workers and deterministic tests. */
cbm_mem_budget_t cbm_mem_resolve_budget_capped(size_t total_ram, double ram_fraction,
                                               const char *budget_mb, size_t hard_cap_bytes);

/* Current RSS in bytes via mi_process_info().
 * Falls back to OS-specific queries when MI_OVERRIDE=0 (ASan builds). */
size_t cbm_mem_rss(void);

/* Peak RSS in bytes. */
size_t cbm_mem_peak_rss(void);

/* Total budget in bytes. */
size_t cbm_mem_budget(void);

/* TEST HOOK: overwrite the budget directly, bypassing cbm_mem_init's
 * init-once guard (a setenv+re-init dance in tests is a silent no-op once
 * some earlier init won the guard — the poisoned budget then leaks into
 * every later budget consumer in the process). Does NOT flip the init
 * guard: a later cbm_mem_init still initializes normally. Callers must
 * save cbm_mem_budget() first and restore it before their assertions.
 * Never call from production code. */
void cbm_mem_set_budget_for_tests(size_t bytes);

/* Returns true if current RSS exceeds the budget. */
bool cbm_mem_over_budget(void);

/* Per-worker budget hint: budget / num_workers. */
size_t cbm_mem_worker_budget(int num_workers);

/* Return unused pages to the OS. Call between files to bound per-file peak. */
void cbm_mem_collect(void);

/* Bounded, rate-limited page return for a long-lived process's maintenance
 * tick. No-op on POSIX, where every free already returns its pages
 * (purge_delay=0); on Windows it trims the CRT heap, which otherwise keeps
 * freed pages committed no matter which code path freed them (#581). Safe to
 * call from a hot loop: at most one trim per second, process-wide. */
void cbm_mem_collect_periodic(void);

/* ── Memory map: where does the process's memory actually live? ──────
 *
 * A growth diagnostic that is honest about what it cannot see. Walking the
 * allocator reports live bytes for the CALLING thread's heap only, so a leak
 * on another thread — or memory never routed through the allocator — would be
 * invisible to a naive per-subsystem tally. Every consumer therefore gets
 * three independent totals plus an explicit residual, so an incomplete map
 * announces itself instead of looking balanced:
 *
 *   os_committed_bytes  what the OS charges the process
 *   live_bytes          allocator blocks live on THIS thread's heap
 *   residual            os_committed - live_bytes (other threads, allocator
 *                       retention, or non-allocator memory)
 *
 * Reading the triple localises growth without guessing:
 *   live grows                → leak on this thread's heap; buckets say which size
 *   residual grows, live flat → another thread's heap, retention, or OS/CRT memory
 *   both flat but RSS grows   → mapped files or stacks, not the heap
 *
 * The bucket histogram splits live bytes by size class, so a distinctive class
 * ("thousands of 384-byte blocks appeared") identifies the allocation without
 * per-callsite instrumentation.
 */
enum { CBM_MEM_MAP_BUCKETS = 8 };

typedef struct {
    size_t os_committed_bytes;
    size_t os_rss_bytes;
    size_t live_bytes;
    size_t live_blocks;
    size_t area_committed_bytes;
    size_t area_reserved_bytes;
    /* Live bytes by size class: <=64, <=256, <=1K, <=4K, <=16K, <=64K, <=1M, rest */
    size_t bucket_bytes[CBM_MEM_MAP_BUCKETS];
    size_t bucket_blocks[CBM_MEM_MAP_BUCKETS];
} cbm_mem_map_t;

/* Inclusive upper bound of each size class; the last bucket is open-ended and
 * reports 0. */
size_t cbm_mem_map_bucket_limit(int bucket);

/* Snapshot the current memory map. Returns false only when out is NULL. If the
 * allocator declines the walk, the OS totals are still filled and live_bytes
 * stays 0, so the residual carries the whole process and the caller can SEE
 * that the walk contributed nothing rather than reading 0 as "no leak". */
bool cbm_mem_map_collect(cbm_mem_map_t *out);

/* ── Phase map: WHICH code path does the memory stay in? ─────────────
 *
 * The allocator walk answers "how much and what size"; it cannot answer "who".
 * When the growth does not route through the allocator at all — the Windows
 * case in #581 — attribution has to come from the one metric that does see it:
 * OS committed bytes. Marks bracket a critical path, and each mark attributes
 * the committed-bytes delta since the previous mark to the previous label. Over
 * many requests the label whose total climbs monotonically is where memory
 * stays.
 *
 * Deliberately coarse and honest about it:
 *   - OS committed is process-wide, so a concurrently-busy thread lands noise
 *     in whichever label is open. Signal comes from ACCUMULATION over many
 *     passes, never from a single delta.
 *   - Marks must bracket the WHOLE path with no unlabelled gaps, or the leak
 *     hides in the gap. Label the tail explicitly.
 *   - Off unless CBM_MEM_PHASES=1, so the hot path pays one atomic load.
 */
void cbm_mem_phase_mark(const char *label);

/* Drop all accumulated phase totals (call once at the start of a measurement). */
void cbm_mem_phase_reset(void);

/* Write the phase table as a JSON array of {label, bytes, hits}, biggest total
 * first. Returns bytes written (0 when disabled or empty). */
int cbm_mem_phase_report_json(char *out, size_t size);

#endif /* CBM_MEM_H */
