#ifndef MAC_HANDSFREE_C_PLATFORM_SUPPORT_H
#define MAC_HANDSFREE_C_PLATFORM_SUPPORT_H

#ifdef __cplusplus
extern "C" {
#endif

/// Atomically renames `source` to `destination` only when destination does not exist.
/// Returns 0 on success and -1 with errno set on failure.
int mac_handsfree_rename_noreplace(const char *source, const char *destination);

/// Atomically exchanges two existing paths.
/// Returns 0 on success and -1 with errno set on failure.
int mac_handsfree_rename_exchange(const char *first, const char *second);

#ifdef __cplusplus
}
#endif

#endif
