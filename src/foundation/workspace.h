#ifndef CBM_FOUNDATION_WORKSPACE_H
#define CBM_FOUNDATION_WORKSPACE_H

#include <stdbool.h>
#include <stddef.h>

/*
 * Workspace boundary policy — classify a directory as an indexing root.
 *
 * This is the breadth half of the boundary: it rejects roots that are too broad
 * or too sensitive to be indexed as a unit. It is NOT the authorization half.
 * Whether a caller may index a given tree at all is answered by the user-level
 * grant store, because that is the only input a caller cannot write. A verdict
 * of CBM_WS_ALLOW here means "this path is not obviously too broad", never
 * "this path is authorized".
 *
 * Every function takes an ALREADY-CANONICALIZED absolute path. Classifying
 * before symlink resolution lets `/a/b/c/d/e/link -> /` present as a deep path
 * and launder straight through, so callers must resolve first.
 *
 * home_dir and cache_dir are passed in rather than read from the environment so
 * the policy is a pure function and can be tested without touching the host.
 * Either may be NULL, which disables the checks that depend on it.
 */

typedef enum {
    CBM_WS_ALLOW = 0,
    /* Fewer path components than the platform minimum — e.g. "/etc", "/home". */
    CBM_WS_DENY_TOO_SHALLOW,
    /* A filesystem root, a drive root, a UNC share root, or a path that is or
     * contains the cbm cache directory. Never overridable. */
    CBM_WS_DENY_ABSOLUTE,
    /* The home directory itself, or a credential/system directory. Overridable
     * by an explicit human action, never by a manifest or a tool call. */
    CBM_WS_DENY_SENSITIVE,
} cbm_ws_verdict_t;

/* Classify canonical_path as a candidate indexing root. */
cbm_ws_verdict_t cbm_workspace_classify_root(const char *canonical_path, const char *home_dir,
                                             const char *cache_dir);

/* Stable, human-facing reason for a verdict. Never NULL. */
const char *cbm_workspace_verdict_reason(cbm_ws_verdict_t verdict);

/* True when an explicit human action may override this verdict. Absolute denials
 * and shallow paths are never overridable; sensitive ones are. */
bool cbm_workspace_verdict_is_overridable(cbm_ws_verdict_t verdict);

/* Number of path components below the volume root, ignoring repeated and
 * trailing separators. "/" is 0, "/etc" is 1, "C:/repos" is 1, "//srv/share" is
 * 0 (the share root itself). Exposed for tests. */
int cbm_workspace_path_depth(const char *canonical_path);

#endif /* CBM_FOUNDATION_WORKSPACE_H */
