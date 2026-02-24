#ifndef WAD_SD_LOADER_H
#define WAD_SD_LOADER_H

#include <stdint.h>

#define DOOM_WAD_FILE_NAME "DOOM1.WAD"
#define DOOM_WAD_DST_ADDR  0x15000000u
#define DOOM_WAD_MAX_BYTES (8u * 1024u * 1024u)

int wad_sd_loader_load(void);
int wad_sd_loader_is_ready(void);
uint32_t wad_sd_loader_get_addr(void);
uint32_t wad_sd_loader_get_size(void);
int wad_sd_loader_path_matches(const char *path);

#endif // WAD_SD_LOADER_H
