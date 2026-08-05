/*
 * workspace.c — workspace boundary policy. See workspace.h for the contract and
 * for why this is only the breadth half of the boundary.
 */
#include "foundation/workspace.h"

#include <string.h>

enum {
    /* POSIX: two components, so every top-level tree is refused in one rule with
     * no list to maintain — "/etc", "/home", "/Users", "/var", "/opt", "/srv".
     * Depth alone cannot do this on Windows, where the equivalent system trees
     * and a perfectly ordinary workspace are both one component below the drive
     * ("C:/Windows" and "D:/repos"), so Windows uses one component plus the
     * named system directories below. Windows' top-level set is small and stable
     * enough for a list; POSIX's is not. */
    WS_MIN_DEPTH_POSIX = 2,
    WS_MIN_DEPTH_WINDOWS = 1,
};

static bool ws_is_sep(char c) {
    return c == '/' || c == '\\';
}

/* Length of the volume prefix: "/" on POSIX, "C:/" for a drive, "//srv/share"
 * for a UNC share. Returns 0 when the path is not absolute. */
static size_t ws_volume_prefix_len(const char *path) {
    if (!path || !path[0]) {
        return 0;
    }
    /* UNC: two separators, a host, then a share. */
    if (ws_is_sep(path[0]) && ws_is_sep(path[1])) {
        size_t i = 2;
        while (path[i] && !ws_is_sep(path[i])) { /* host */
            i++;
        }
        while (ws_is_sep(path[i])) {
            i++;
        }
        while (path[i] && !ws_is_sep(path[i])) { /* share */
            i++;
        }
        return i;
    }
    if (ws_is_sep(path[0])) {
        return 1;
    }
    /* Drive-letter root, with or without a trailing separator. */
    if (path[1] == ':' &&
        ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))) {
        return ws_is_sep(path[2]) ? 3 : 2;
    }
    return 0;
}

static bool ws_is_unc(const char *path) {
    return path && ws_is_sep(path[0]) && ws_is_sep(path[1]);
}

static bool ws_is_windows_style(const char *path) {
    if (!path || !path[0]) {
        return false;
    }
    return path[1] == ':' &&
           ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'));
}

int cbm_workspace_path_depth(const char *canonical_path) {
    size_t prefix = ws_volume_prefix_len(canonical_path);
    if (prefix == 0) {
        return 0;
    }
    int depth = 0;
    const char *p = canonical_path + prefix;
    while (*p) {
        while (ws_is_sep(*p)) {
            p++;
        }
        if (!*p) {
            break;
        }
        depth++;
        while (*p && !ws_is_sep(*p)) {
            p++;
        }
    }
    return depth;
}

/* Case-insensitive on Windows-style paths, exact elsewhere: NTFS is
 * case-insensitive, so ".SSH" must not slip past a case-sensitive compare. */
static bool ws_component_equals(const char *component, size_t len, const char *name,
                                bool fold_case) {
    if (strlen(name) != len) {
        return false;
    }
    for (size_t i = 0; i < len; i++) {
        char a = component[i];
        char b = name[i];
        if (fold_case) {
            if (a >= 'A' && a <= 'Z') {
                a = (char)(a - 'A' + 'a');
            }
            if (b >= 'A' && b <= 'Z') {
                b = (char)(b - 'A' + 'a');
            }
        }
        if (a != b) {
            return false;
        }
    }
    return true;
}

/* Directory and file names that carry credentials. Matched against every
 * component, so both "…/.ssh" and "…/.ssh/sub" are refused. Additive by design:
 * a pull request appending a name here needs no design authority. */
static const char *const WS_CREDENTIAL_NAMES[] = {
    ".ssh",
    ".aws",
    ".gnupg",
    ".gpg",
    ".kube",
    ".docker",
    ".netrc",
    "_netrc",
    ".git-credentials",
    ".azure",
    ".gcloud",
    "Keychains",
    ".password-store",
    ".authinfo",
};

/* Windows top-level trees below the drive. Small and stable enough to list,
 * which is what lets Windows use a shallower depth minimum. */
static const char *const WS_WINDOWS_SYSTEM_DIRS[] = {
    "Windows", "Users", "ProgramData", "Program Files", "Program Files (x86)",
};

static bool ws_any_component_matches(const char *path, const char *const *names, size_t count,
                                     bool fold_case) {
    size_t prefix = ws_volume_prefix_len(path);
    const char *p = path + prefix;
    while (*p) {
        while (ws_is_sep(*p)) {
            p++;
        }
        if (!*p) {
            break;
        }
        const char *start = p;
        while (*p && !ws_is_sep(*p)) {
            p++;
        }
        size_t len = (size_t)(p - start);
        for (size_t i = 0; i < count; i++) {
            if (ws_component_equals(start, len, names[i], fold_case)) {
                return true;
            }
        }
    }
    return false;
}

/* True when b is a or lives under a. Compares on a separator boundary so
 * "/a/bc" is not treated as living under "/a/b". */
static bool ws_is_ancestor_or_equal(const char *a, const char *b) {
    if (!a || !b || !a[0] || !b[0]) {
        return false;
    }
    size_t la = strlen(a);
    while (la > 1 && ws_is_sep(a[la - 1])) {
        la--;
    }
    if (strncmp(a, b, la) != 0) {
        return false;
    }
    return b[la] == '\0' || ws_is_sep(b[la]);
}

static bool ws_paths_equal(const char *a, const char *b) {
    return ws_is_ancestor_or_equal(a, b) && ws_is_ancestor_or_equal(b, a);
}

cbm_ws_verdict_t cbm_workspace_classify_root(const char *canonical_path, const char *home_dir,
                                             const char *cache_dir) {
    if (!canonical_path || !canonical_path[0] || ws_volume_prefix_len(canonical_path) == 0) {
        /* A relative or empty path is not a usable root; refuse it the same way
         * as a volume root rather than letting it fall through as allowed. */
        return CBM_WS_DENY_ABSOLUTE;
    }

    bool windows_style = ws_is_windows_style(canonical_path);
    int depth = cbm_workspace_path_depth(canonical_path);

    /* A volume, drive or share root, whatever the platform. */
    if (depth == 0) {
        return CBM_WS_DENY_ABSOLUTE;
    }

    /* Order matters below, and not for cosmetic reasons.
     *
     * The home directory normally CONTAINS the cache directory, so testing the
     * cache first would report every $HOME as "holds the cache" — and, worse,
     * would make it absolutely denied when the design says a person may override
     * it. Home is therefore classified first.
     *
     * Depth comes before the cache test for the same kind of reason: "/Users" is
     * both too broad and an ancestor of the cache, and "too broad, name a
     * project directory below it" is the reason that actually helps the reader. */
    if (home_dir && home_dir[0] && ws_paths_equal(canonical_path, home_dir)) {
        return CBM_WS_DENY_SENSITIVE;
    }

    /* Below a drive or a UNC share the first component is already user space
     * ("D:/repos", "//srv/share/proj"), so one component is enough there. Below a
     * POSIX root it is a system tree, so require two. */
    int min_depth =
        (windows_style || ws_is_unc(canonical_path)) ? WS_MIN_DEPTH_WINDOWS : WS_MIN_DEPTH_POSIX;
    if (depth < min_depth) {
        return CBM_WS_DENY_TOO_SHALLOW;
    }

    /* Indexing a tree that holds the cache would pull every other project's
     * graph database into this project's index. Never overridable. */
    if (cache_dir && cache_dir[0] && ws_is_ancestor_or_equal(canonical_path, cache_dir)) {
        return CBM_WS_DENY_ABSOLUTE;
    }

    if (ws_any_component_matches(canonical_path, WS_CREDENTIAL_NAMES,
                                 sizeof(WS_CREDENTIAL_NAMES) / sizeof(WS_CREDENTIAL_NAMES[0]),
                                 windows_style)) {
        return CBM_WS_DENY_SENSITIVE;
    }

    if (windows_style &&
        ws_any_component_matches(canonical_path, WS_WINDOWS_SYSTEM_DIRS,
                                 sizeof(WS_WINDOWS_SYSTEM_DIRS) / sizeof(WS_WINDOWS_SYSTEM_DIRS[0]),
                                 true)) {
        return CBM_WS_DENY_SENSITIVE;
    }

    return CBM_WS_ALLOW;
}

const char *cbm_workspace_verdict_reason(cbm_ws_verdict_t verdict) {
    switch (verdict) {
    case CBM_WS_ALLOW:
        return "allowed";
    case CBM_WS_DENY_TOO_SHALLOW:
        return "path is too broad to index as one root; name a project directory below it";
    case CBM_WS_DENY_ABSOLUTE:
        return "path is a volume root or holds the codebase-memory cache; it cannot be indexed";
    case CBM_WS_DENY_SENSITIVE:
        return "path is a home or credential directory";
    default:
        break;
    }
    return "refused";
}

bool cbm_workspace_verdict_is_overridable(cbm_ws_verdict_t verdict) {
    return verdict == CBM_WS_DENY_SENSITIVE;
}
