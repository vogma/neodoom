// =============================================================================
// SDRAM-backed WAD file backend for NEORV32
// =============================================================================

#include <stdint.h>
#include <string.h>

#include "w_file.h"
#include "z_zone.h"
#include "wad_sd_loader.h"

typedef struct
{
    wad_file_t wad;
    const unsigned char *data;
    unsigned int size;
} sdram_wad_file_t;

extern wad_file_class_t sdram_wad_file;

static wad_file_t *W_SDRAM_OpenFile(char *path)
{
    sdram_wad_file_t *result;
    unsigned int wad_size;
    const unsigned char *wad_data;

    if (!wad_sd_loader_is_ready()) {
        return NULL;
    }

    if (!wad_sd_loader_path_matches(path)) {
        return NULL;
    }

    wad_size = wad_sd_loader_get_size();
    wad_data = (const unsigned char *)(uintptr_t)wad_sd_loader_get_addr();

    result = Z_Malloc(sizeof(sdram_wad_file_t), PU_STATIC, 0);
    result->wad.file_class = &sdram_wad_file;
    result->wad.mapped = (byte *)wad_data;
    result->wad.length = wad_size;
    result->data = wad_data;
    result->size = wad_size;

    return &result->wad;
}

static void W_SDRAM_CloseFile(wad_file_t *wad)
{
    Z_Free(wad);
}

static size_t W_SDRAM_Read(wad_file_t *wad, unsigned int offset,
                           void *buffer, size_t buffer_len)
{
    sdram_wad_file_t *sdram_wad = (sdram_wad_file_t *)wad;

    if (offset >= sdram_wad->size) {
        return 0;
    }

    if (offset + buffer_len > sdram_wad->size) {
        buffer_len = sdram_wad->size - offset;
    }

    memcpy(buffer, sdram_wad->data + offset, buffer_len);
    return buffer_len;
}

wad_file_class_t sdram_wad_file =
{
    W_SDRAM_OpenFile,
    W_SDRAM_CloseFile,
    W_SDRAM_Read,
};

// Override stdc backend with SDRAM backend.
wad_file_class_t stdc_wad_file =
{
    W_SDRAM_OpenFile,
    W_SDRAM_CloseFile,
    W_SDRAM_Read,
};
