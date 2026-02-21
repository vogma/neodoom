// =============================================================================
// System stubs for missing POSIX/newlib functions
// =============================================================================

#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>

// Stub for mkdir - not needed for embedded WAD
int mkdir(const char *pathname, mode_t mode)
{
    (void)pathname;
    (void)mode;
    errno = ENOTSUP;
    return -1;
}

// Stub for remove - not needed for embedded WAD
int remove(const char *pathname)
{
    (void)pathname;
    errno = ENOTSUP;
    return -1;
}

// Stub for rename - not needed for embedded WAD
int rename(const char *oldpath, const char *newpath)
{
    (void)oldpath;
    (void)newpath;
    errno = ENOTSUP;
    return -1;
}
