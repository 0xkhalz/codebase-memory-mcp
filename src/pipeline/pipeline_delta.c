/*
 * pipeline_delta.c — delta-repair staging primitives (closure route only).
 *
 * The dedicated incremental subsystem: instead of loading the whole previous
 * graph into RAM and dumping a complete new generation, the closure route
 * CLONES the live database (copy-on-write where the filesystem offers it),
 * PATCHES exactly the repaired node/edge set into the clone inside one
 * transaction, and publishes through the same sealed-staging finalize leg as
 * the dump path. The general indexing pipeline is untouched; these
 * primitives exist only for the closure orchestration in
 * pipeline_incremental.c.
 *
 * Id discipline carries the design: node ids are AUTOINCREMENT and never
 * reused, the small in-RAM gbuf is pre-seeded with PROXY nodes carrying
 * their real database ids, and fresh nodes are numbered above the previous
 * generation's MAX(id) — so "id > max_db_id" is the complete, marker-free
 * definition of what the patch inserts, and every edge endpoint id is
 * database-valid by construction.
 *
 * FTS policy: the nodes_fts table is contentless, so purged rows cannot be
 * deleted individually on existing databases; their rowids can never alias
 * a live node again (AUTOINCREMENT), so dead entries simply drop out of the
 * rowid join at query time. The patch inserts rows for exactly the new
 * nodes, via the same cbm_camel_split SQL function the wholesale rebuild
 * uses.
 */
#include "foundation/constants.h"
#include "pipeline/pipeline_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "foundation/compat_fs.h"
#include "foundation/log.h"
#include "sqlite3.h"
#include "store/store.h"

enum { DELTA_IN_CHUNK = 200 };

/* Assemble "?,?,...,?" for a chunked IN list. buf must hold 2*count. */
static void delta_placeholders(char *buf, int count) {
    int pos = 0;
    for (int i = 0; i < count; i++) {
        buf[pos++] = '?';
        if (i + 1 < count) {
            buf[pos++] = ',';
        }
    }
    buf[pos] = '\0';
}

int cbm_delta_stage_clone(const char *final_db_path, char **out_stage_path) {
    *out_stage_path = NULL;
    char *stage = cbm_pipeline_create_staging_path(final_db_path);
    if (!stage) {
        return CBM_NOT_FOUND;
    }
    if (cbm_clone_or_copy_file(final_db_path, stage) != 0) {
        cbm_pipeline_discard_stage(stage);
        free(stage);
        return CBM_NOT_FOUND;
    }
    *out_stage_path = stage;
    return 0;
}

/* Snapshot inbound cross-file edges into the given files from OUTSIDE them,
 * keyed by endpoint qualified names — the same semantics as the gbuf-based
 * capture, expressed as one indexed query per chunk. Edge types a full
 * reindex recomputes wholesale are excluded for the same reasons recorded
 * there (restoring a stale copy could produce edges a full build would not). */
static bool delta_edge_type_is_recomputed(const char *type) {
    return type && (strcmp(type, "SIMILAR_TO") == 0 || strcmp(type, "SEMANTICALLY_RELATED") == 0 ||
                    strcmp(type, "FILE_CHANGES_WITH") == 0 || strcmp(type, "DATA_FLOWS") == 0);
}

int cbm_delta_snapshot_inbound(cbm_store_t *store, const char *project, const char *const *paths,
                               int path_count, cbm_delta_saved_edge_t **out, int *out_count) {
    *out = NULL;
    *out_count = 0;
    if (path_count <= 0) {
        return 0;
    }
    sqlite3 *db = cbm_store_get_db(store);
    if (!db) {
        return CBM_NOT_FOUND;
    }
    cbm_delta_saved_edge_t *items = NULL;
    int count = 0;
    int cap = 0;
    for (int off = 0; off < path_count; off += DELTA_IN_CHUNK) {
        int chunk = path_count - off;
        if (chunk > DELTA_IN_CHUNK) {
            chunk = DELTA_IN_CHUNK;
        }
        char ph[2 * DELTA_IN_CHUNK + 1];
        delta_placeholders(ph, chunk);
        char sql[CBM_SZ_4K];
        int n = snprintf(sql, sizeof(sql),
                         "SELECT src.qualified_name, tgt.qualified_name, e.type, e.properties"
                         " FROM edges e"
                         " JOIN nodes tgt ON e.target_id = tgt.id"
                         " JOIN nodes src ON e.source_id = src.id"
                         " WHERE e.project = ?1 AND tgt.file_path IN (%s)"
                         " AND src.file_path NOT IN (%s)"
                         " AND src.file_path <> '' AND src.file_path IS NOT NULL",
                         ph, ph);
        if (n < 0 || (size_t)n >= sizeof(sql)) {
            cbm_delta_free_snapshot(items, count);
            return CBM_NOT_FOUND;
        }
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql, CBM_NOT_FOUND, &stmt, NULL) != SQLITE_OK) {
            cbm_delta_free_snapshot(items, count);
            return CBM_NOT_FOUND;
        }
        sqlite3_bind_text(stmt, 1, project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
        for (int i = 0; i < chunk; i++) {
            sqlite3_bind_text(stmt, 2 + i, paths[off + i], CBM_NOT_FOUND, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2 + chunk + i, paths[off + i], CBM_NOT_FOUND, SQLITE_TRANSIENT);
        }
        int step_rc;
        while ((step_rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            const char *type = (const char *)sqlite3_column_text(stmt, 2);
            if (delta_edge_type_is_recomputed(type)) {
                continue;
            }
            if (count >= cap) {
                int ncap = cap ? cap * 2 : 64;
                cbm_delta_saved_edge_t *grown = realloc(items, (size_t)ncap * sizeof(*items));
                if (!grown) {
                    sqlite3_finalize(stmt);
                    cbm_delta_free_snapshot(items, count);
                    return CBM_NOT_FOUND;
                }
                items = grown;
                cap = ncap;
            }
            const char *sq = (const char *)sqlite3_column_text(stmt, 0);
            const char *tq = (const char *)sqlite3_column_text(stmt, 1);
            const char *props = (const char *)sqlite3_column_text(stmt, 3);
            cbm_delta_saved_edge_t *e = &items[count];
            e->source_qn = strdup(sq ? sq : "");
            e->target_qn = strdup(tq ? tq : "");
            e->type = strdup(type ? type : "");
            e->props = strdup(props ? props : "{}");
            if (!e->source_qn || !e->target_qn || !e->type || !e->props) {
                free(e->source_qn);
                free(e->target_qn);
                free(e->type);
                free(e->props);
                sqlite3_finalize(stmt);
                cbm_delta_free_snapshot(items, count);
                return CBM_NOT_FOUND;
            }
            count++;
        }
        sqlite3_finalize(stmt);
        if (step_rc != SQLITE_DONE) {
            cbm_delta_free_snapshot(items, count);
            return CBM_NOT_FOUND;
        }
    }
    *out = items;
    *out_count = count;
    return 0;
}

void cbm_delta_free_snapshot(cbm_delta_saved_edge_t *items, int count) {
    if (!items) {
        return;
    }
    for (int i = 0; i < count; i++) {
        free(items[i].source_qn);
        free(items[i].target_qn);
        free(items[i].type);
        free(items[i].props);
    }
    free(items);
}

int cbm_delta_purge(cbm_store_t *store, const char *project, const char *const *paths,
                    int path_count) {
    if (path_count <= 0) {
        return 0;
    }
    sqlite3 *db = cbm_store_get_db(store);
    if (!db) {
        return CBM_NOT_FOUND;
    }
    for (int off = 0; off < path_count; off += DELTA_IN_CHUNK) {
        int chunk = path_count - off;
        if (chunk > DELTA_IN_CHUNK) {
            chunk = DELTA_IN_CHUNK;
        }
        char ph[2 * DELTA_IN_CHUNK + 1];
        delta_placeholders(ph, chunk);
        char sql[CBM_SZ_1K];
        int n = snprintf(sql, sizeof(sql),
                         "DELETE FROM nodes WHERE project = ?1 AND file_path IN (%s)", ph);
        if (n < 0 || (size_t)n >= sizeof(sql)) {
            return CBM_NOT_FOUND;
        }
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql, CBM_NOT_FOUND, &stmt, NULL) != SQLITE_OK) {
            return CBM_NOT_FOUND;
        }
        sqlite3_bind_text(stmt, 1, project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
        for (int i = 0; i < chunk; i++) {
            sqlite3_bind_text(stmt, 2 + i, paths[off + i], CBM_NOT_FOUND, SQLITE_TRANSIENT);
        }
        int rc = sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        if (rc != SQLITE_DONE) {
            return CBM_NOT_FOUND;
        }
    }
    return 0;
}

/* Labels whose nodes resolution or the restricted post-passes may reference
 * as edge endpoints. Everything else stays on disk; an unexpected reference
 * to an unseeded QN surfaces as a fresh node whose INSERT then violates the
 * UNIQUE(project, qualified_name) constraint, failing the patch — and the
 * orchestration's fallback to a full rebuild self-heals. Fail-closed, never
 * silently wrong. */
static const char *const DELTA_PRESEED_LABELS[] = {
    "Function", "Method",   "Class",    "Struct",     "Interface", "Enum",   "Type",
    "Trait",    "Protocol", "Variable", "Field",      "File",      "Module", "Package",
    "Folder",   "Project",  "EnvVar",   "Dependency", "Route",
};

int64_t cbm_delta_preseed(cbm_store_t *store, const char *project, cbm_gbuf_t *gbuf) {
    sqlite3 *db = cbm_store_get_db(store);
    if (!db) {
        return -1;
    }
    int64_t max_id = 0;
    {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM nodes WHERE project = ?1",
                               CBM_NOT_FOUND, &stmt, NULL) != SQLITE_OK) {
            return -1;
        }
        sqlite3_bind_text(stmt, 1, project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            max_id = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }

    enum { PRESEED_LABEL_COUNT = sizeof(DELTA_PRESEED_LABELS) / sizeof(DELTA_PRESEED_LABELS[0]) };
    char ph[2 * PRESEED_LABEL_COUNT + 1];
    delta_placeholders(ph, PRESEED_LABEL_COUNT);
    char sql[CBM_SZ_1K];
    int n = snprintf(sql, sizeof(sql),
                     "SELECT id, label, name, qualified_name, file_path FROM nodes"
                     " WHERE project = ?1 AND label IN (%s) ORDER BY id",
                     ph);
    if (n < 0 || (size_t)n >= sizeof(sql)) {
        return -1;
    }
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, CBM_NOT_FOUND, &stmt, NULL) != SQLITE_OK) {
        return -1;
    }
    sqlite3_bind_text(stmt, 1, project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    for (int i = 0; i < PRESEED_LABEL_COUNT; i++) {
        sqlite3_bind_text(stmt, 2 + i, DELTA_PRESEED_LABELS[i], CBM_NOT_FOUND, SQLITE_STATIC);
    }
    int step_rc;
    int64_t seeded = 0;
    while ((step_rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        int64_t id = sqlite3_column_int64(stmt, 0);
        const char *label = (const char *)sqlite3_column_text(stmt, 1);
        const char *name = (const char *)sqlite3_column_text(stmt, 2);
        const char *qn = (const char *)sqlite3_column_text(stmt, 3);
        const char *fp = (const char *)sqlite3_column_text(stmt, 4);
        /* Pin the gbuf id to the database id: proxies ARE their rows. */
        cbm_gbuf_set_next_id(gbuf, id);
        int64_t got = cbm_gbuf_upsert_node(gbuf, label, name, qn, fp ? fp : "", 0, 0, "{}");
        if (got != id) {
            /* A QN collision inside the preseed set would silently split
             * identity between RAM and disk; the run cannot be trusted. */
            sqlite3_finalize(stmt);
            cbm_log_error("delta.preseed_id_mismatch", "qn", qn ? qn : "");
            return -1;
        }
        seeded++;
    }
    sqlite3_finalize(stmt);
    if (step_rc != SQLITE_DONE) {
        return -1;
    }
    cbm_gbuf_set_next_id(gbuf, max_id + 1);
    char seeded_buf[32];
    snprintf(seeded_buf, sizeof(seeded_buf), "%lld", (long long)seeded);
    cbm_log_info("delta.preseed", "proxies", seeded_buf);
    return max_id;
}

/* Patch visitor state: inserts everything above the id watermark. */
typedef struct {
    sqlite3 *db;
    const char *project;
    int64_t max_db_id;
    sqlite3_stmt *node_stmt;
    sqlite3_stmt *edge_stmt;
    bool failed;
    int64_t nodes;
    int64_t edges;
} delta_patch_ctx_t;

static void delta_patch_node(const cbm_gbuf_node_t *node, void *userdata) {
    delta_patch_ctx_t *ctx = (delta_patch_ctx_t *)userdata;
    if (ctx->failed || node->id <= ctx->max_db_id) {
        return;
    }
    sqlite3_reset(ctx->node_stmt);
    sqlite3_bind_int64(ctx->node_stmt, 1, node->id);
    sqlite3_bind_text(ctx->node_stmt, 2, ctx->project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    sqlite3_bind_text(ctx->node_stmt, 3, node->label, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    sqlite3_bind_text(ctx->node_stmt, 4, node->name, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    sqlite3_bind_text(ctx->node_stmt, 5, node->qualified_name, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    sqlite3_bind_text(ctx->node_stmt, 6, node->file_path ? node->file_path : "", CBM_NOT_FOUND,
                      SQLITE_TRANSIENT);
    sqlite3_bind_int(ctx->node_stmt, 7, node->start_line);
    sqlite3_bind_int(ctx->node_stmt, 8, node->end_line);
    sqlite3_bind_text(ctx->node_stmt, 9, node->properties_json ? node->properties_json : "{}",
                      CBM_NOT_FOUND, SQLITE_TRANSIENT);
    if (sqlite3_step(ctx->node_stmt) != SQLITE_DONE) {
        ctx->failed = true;
        cbm_log_error("delta.patch_node_failed", "qn",
                      node->qualified_name ? node->qualified_name : "");
        return;
    }
    ctx->nodes++;
}

static void delta_patch_edge(const cbm_gbuf_edge_t *edge, void *userdata) {
    delta_patch_ctx_t *ctx = (delta_patch_ctx_t *)userdata;
    if (ctx->failed) {
        return;
    }
    if (edge->source_id <= ctx->max_db_id && edge->target_id <= ctx->max_db_id) {
        return; /* both endpoints pre-existed: nothing new to record */
    }
    sqlite3_reset(ctx->edge_stmt);
    sqlite3_bind_text(ctx->edge_stmt, 1, ctx->project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    sqlite3_bind_int64(ctx->edge_stmt, 2, edge->source_id);
    sqlite3_bind_int64(ctx->edge_stmt, 3, edge->target_id);
    sqlite3_bind_text(ctx->edge_stmt, 4, edge->type, CBM_NOT_FOUND, SQLITE_TRANSIENT);
    sqlite3_bind_text(ctx->edge_stmt, 5, edge->properties_json ? edge->properties_json : "{}",
                      CBM_NOT_FOUND, SQLITE_TRANSIENT);
    if (sqlite3_step(ctx->edge_stmt) != SQLITE_DONE) {
        ctx->failed = true;
        cbm_log_error("delta.patch_edge_failed", "type", edge->type ? edge->type : "");
        return;
    }
    ctx->edges++;
}

int cbm_delta_patch(cbm_store_t *store, const char *project, cbm_gbuf_t *gbuf, int64_t max_db_id,
                    const cbm_delta_saved_edge_t *snapshot, int snapshot_count) {
    sqlite3 *db = cbm_store_get_db(store);
    if (!db) {
        return CBM_NOT_FOUND;
    }
    if (cbm_store_begin(store) != CBM_STORE_OK) {
        return CBM_NOT_FOUND;
    }
    delta_patch_ctx_t ctx = {.db = db, .project = project, .max_db_id = max_db_id};
    if (sqlite3_prepare_v2(db,
                           "INSERT INTO nodes (id, project, label, name, qualified_name,"
                           " file_path, start_line, end_line, properties)"
                           " VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                           CBM_NOT_FOUND, &ctx.node_stmt, NULL) != SQLITE_OK ||
        sqlite3_prepare_v2(db,
                           "INSERT OR IGNORE INTO edges (project, source_id, target_id, type,"
                           " properties) VALUES (?1,?2,?3,?4,?5)",
                           CBM_NOT_FOUND, &ctx.edge_stmt, NULL) != SQLITE_OK) {
        sqlite3_finalize(ctx.node_stmt);
        sqlite3_finalize(ctx.edge_stmt);
        cbm_store_rollback(store);
        return CBM_NOT_FOUND;
    }
    cbm_gbuf_foreach_node(gbuf, delta_patch_node, &ctx);
    if (!ctx.failed) {
        cbm_gbuf_foreach_edge(gbuf, delta_patch_edge, &ctx);
    }
    sqlite3_finalize(ctx.node_stmt);
    sqlite3_finalize(ctx.edge_stmt);

    /* Re-link the snapshotted inbound edges by qualified name. A target
     * whose QN no longer exists simply matches no row — full-reindex
     * semantics for deleted symbols, dedup by the UNIQUE edge constraint. */
    if (!ctx.failed && snapshot_count > 0) {
        sqlite3_stmt *relink = NULL;
        if (sqlite3_prepare_v2(db,
                               "INSERT OR IGNORE INTO edges (project, source_id, target_id,"
                               " type, properties)"
                               " SELECT ?1, s.id, t.id, ?2, ?3 FROM nodes s, nodes t"
                               " WHERE s.project = ?1 AND s.qualified_name = ?4"
                               " AND t.project = ?1 AND t.qualified_name = ?5",
                               CBM_NOT_FOUND, &relink, NULL) != SQLITE_OK) {
            ctx.failed = true;
        } else {
            for (int i = 0; i < snapshot_count && !ctx.failed; i++) {
                sqlite3_reset(relink);
                sqlite3_bind_text(relink, 1, project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
                sqlite3_bind_text(relink, 2, snapshot[i].type, CBM_NOT_FOUND, SQLITE_TRANSIENT);
                sqlite3_bind_text(relink, 3, snapshot[i].props, CBM_NOT_FOUND, SQLITE_TRANSIENT);
                sqlite3_bind_text(relink, 4, snapshot[i].source_qn, CBM_NOT_FOUND,
                                  SQLITE_TRANSIENT);
                sqlite3_bind_text(relink, 5, snapshot[i].target_qn, CBM_NOT_FOUND,
                                  SQLITE_TRANSIENT);
                if (sqlite3_step(relink) != SQLITE_DONE) {
                    ctx.failed = true;
                }
            }
            sqlite3_finalize(relink);
        }
    }

    /* Row-level FTS for exactly the new nodes, through the same tokenizer
     * function the wholesale rebuild uses. */
    if (!ctx.failed) {
        sqlite3_stmt *fts = NULL;
        if (sqlite3_prepare_v2(db,
                               "INSERT INTO nodes_fts (rowid, name, qualified_name, label,"
                               " file_path)"
                               " SELECT id, cbm_camel_split(name), qualified_name, label,"
                               " file_path FROM nodes WHERE project = ?1 AND id > ?2",
                               CBM_NOT_FOUND, &fts, NULL) == SQLITE_OK) {
            sqlite3_bind_text(fts, 1, project, CBM_NOT_FOUND, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fts, 2, max_db_id);
            if (sqlite3_step(fts) != SQLITE_DONE) {
                ctx.failed = true;
            }
            sqlite3_finalize(fts);
        } else {
            /* FTS5 may be compiled out; the table then never existed and
             * search runs without it — matching the dump path's behavior. */
            cbm_log_warn("delta.fts_insert_unavailable", "project", project);
        }
    }

    if (ctx.failed) {
        cbm_store_rollback(store);
        return CBM_NOT_FOUND;
    }
    if (cbm_store_commit(store) != CBM_STORE_OK) {
        return CBM_NOT_FOUND;
    }
    char nodes_buf[32];
    char edges_buf[32];
    snprintf(nodes_buf, sizeof(nodes_buf), "%lld", (long long)ctx.nodes);
    snprintf(edges_buf, sizeof(edges_buf), "%lld", (long long)ctx.edges);
    cbm_log_info("delta.patch", "nodes", nodes_buf, "edges", edges_buf);
    return 0;
}
