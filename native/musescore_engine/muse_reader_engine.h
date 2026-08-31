#pragma once

#include <stddef.h>

#if defined(_WIN32)
#define MUSE_READER_EXPORT __declspec(dllexport)
#elif defined(__GNUC__)
#define MUSE_READER_EXPORT __attribute__((visibility("default")))
#else
#define MUSE_READER_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opens a score and returns a UTF-8 JSON document owned by the engine.
 * The caller must release it with muse_reader_free_json().
 */
MUSE_READER_EXPORT const char* muse_reader_open_json(const char* utf8_path);

MUSE_READER_EXPORT void muse_reader_free_json(const char* json);

MUSE_READER_EXPORT const char* muse_reader_last_error(void);

#ifdef __cplusplus
}
#endif
