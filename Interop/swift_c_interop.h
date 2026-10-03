// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_SWIFT_C_INTEROP_H
#define AXOLOTY_SWIFT_C_INTEROP_H

// The annotations below exist for Clang's Swift importer and nothing else.
// `_Nonnull` and `__counted_by` are declared in Clang's `ptrcheck.h` resource
// header, and that header only ships with Clang 21 and later: Ubuntu's `clang`
// package (clang-14 on jammy) and any earlier Clang has no such file.
//
// The guard therefore asks whether the header is there rather than whether the
// compiler is Clang. That matters for who loses what. The Swift importer is
// always the toolchain's own Clang 21, so every Swift-facing declaration keeps
// its annotations. Only a plain C compilation under a Clang older than 21
// degrades, and there it degrades to exactly what ESP-IDF's GCC build already
// sees. Testing `defined(__clang__)` alone instead makes the host seam checks
// unbuildable on any machine whose `clang` predates 21.
#if defined(__clang__) && defined(__has_include)
#if __has_include(<ptrcheck.h>)
#include <ptrcheck.h>
#define AXOLOTY_C_NOESCAPE __attribute__((noescape))
#define AXOLOTY_NONNULL _Nonnull
#define AXOLOTY_HAVE_SWIFT_ANNOTATIONS 1
#endif
#endif

#if !defined(AXOLOTY_HAVE_SWIFT_ANNOTATIONS)
// ESP-IDF compiles its C implementation with GCC. These annotations only
// affect Clang's Swift importer; they do not change the C ABI.
#define __counted_by(count)
#define AXOLOTY_C_NOESCAPE
#define AXOLOTY_NONNULL
#endif

#endif
