// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_SWIFT_C_INTEROP_H
#define AXOLOTY_SWIFT_C_INTEROP_H

#if defined(__clang__)
#include <ptrcheck.h>
#define AXOLOTY_C_NOESCAPE __attribute__((noescape))
#define AXOLOTY_NONNULL _Nonnull
#else
// ESP-IDF compiles its C implementation with GCC. These annotations only
// affect Clang's Swift importer; they do not change the C ABI.
#define __counted_by(count)
#define AXOLOTY_C_NOESCAPE
#define AXOLOTY_NONNULL
#endif

#endif
