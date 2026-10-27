// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ABI_STATUS_V1_H
#define AXOLOTY_ABI_STATUS_V1_H

#include <stdint.h>

#define AXOLOTY_ABI_V1 1u

/* Status values are int32_t constants, not compiler-sized C enums. */
#define AXOLOTY_ABI_STATUS_OK ((int32_t)0)
#define AXOLOTY_ABI_STATUS_NO_EVENT ((int32_t)1)
#define AXOLOTY_ABI_STATUS_CLOSED ((int32_t)2)
#define AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL ((int32_t)3)
#define AXOLOTY_ABI_STATUS_INVALID_ARGUMENT ((int32_t)-1)
#define AXOLOTY_ABI_STATUS_FAILED ((int32_t)-2)
// Heap-trace records were lost; a reported allocation count would be incomplete.
#define AXOLOTY_ABI_STATUS_TRACE_OVERFLOW ((int32_t)-3)

#endif
