// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "axoloty_application_entry_v1.h"

static int32_t write_log(void *context, const uint8_t *bytes, uint32_t length) {
    (void)context; (void)bytes; (void)length;
    return AXOLOTY_ABI_STATUS_OK;
}

static int require(int condition, const char *label) {
    if (condition) return 0;
    fprintf(stderr, "FAIL %s\n", label);
    return 1;
}

int main(void) {
    int failures = 0;
    uint8_t *short_platform_storage = calloc(1, 2 * sizeof(uint32_t));
    uint8_t *short_carrier_storage = calloc(1, 2 * sizeof(uint32_t));
    if (!short_platform_storage || !short_carrier_storage) return 2;
    axoloty_platform_v1 *short_platform = (axoloty_platform_v1 *)short_platform_storage;
    axoloty_carrier_v1 *short_carrier = (axoloty_carrier_v1 *)short_carrier_storage;
    short_platform->abi_version = AXOLOTY_PLATFORM_ABI_V1;
    short_platform->struct_size = 2 * sizeof(uint32_t);
    short_carrier->abi_version = AXOLOTY_CARRIER_ABI_V1;
    short_carrier->struct_size = 2 * sizeof(uint32_t);
    failures += require(axoloty_platform_v1_validate_requirements(short_platform, 0, 0),
                        "short physical platform header accepted for zero requirements");
    failures += require(axoloty_carrier_v1_validate_requirements(short_carrier, 0, 0),
                        "short physical carrier header accepted for zero requirements");
    short_platform->struct_size = sizeof(uint32_t);
    short_carrier->struct_size = sizeof(uint32_t);
    failures += require(!axoloty_platform_v1_validate_requirements(short_platform, 0, 0),
                        "platform header size below frozen prefix rejected");
    failures += require(!axoloty_carrier_v1_validate_requirements(short_carrier, 0, 0),
                        "carrier header size below frozen prefix rejected");
    short_platform->struct_size = 2 * sizeof(uint32_t);
    short_carrier->struct_size = 2 * sizeof(uint32_t);
    failures += require(!axoloty_platform_v1_validate_requirements(
                            short_platform, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "short physical allocation rejected before capabilities/function access");

    axoloty_platform_v1 table = {
        .abi_version = AXOLOTY_PLATFORM_ABI_V1,
        .struct_size = sizeof(axoloty_platform_v1),
        .capabilities = AXOLOTY_PLATFORM_CAP_LOG,
        .context = NULL,
        .write_log = write_log,
    };
    failures += require(axoloty_platform_v1_validate_requirements(
                            &table, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "required bit and function accepted");
    table.capabilities = 0;
    failures += require(!axoloty_platform_v1_validate_requirements(
                            &table, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "missing required capability bit rejected");
    table.capabilities = AXOLOTY_PLATFORM_CAP_LOG;
    table.write_log = NULL;
    failures += require(!axoloty_platform_v1_validate_requirements(
                            &table, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "missing required function rejected");
    table.write_log = write_log;
    table.struct_size = offsetof(axoloty_platform_v1, write_log);
    failures += require(!axoloty_platform_v1_validate_requirements(
                            &table, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "short required function prefix rejected");
    table.struct_size = sizeof(axoloty_platform_v1);
    table.abi_version = 99;
    failures += require(!axoloty_platform_v1_validate_requirements(
                            &table, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "unsupported version rejected");

    const size_t extended_size = sizeof(axoloty_platform_v1) + 16;
    uint8_t *extended_storage = calloc(1, extended_size);
    if (!extended_storage) return 2;
    memcpy(extended_storage, &table, sizeof(table));
    axoloty_platform_v1 *extended = (axoloty_platform_v1 *)extended_storage;
    extended->abi_version = AXOLOTY_PLATFORM_ABI_V1;
    extended->struct_size = (uint32_t)extended_size;
    extended->capabilities = AXOLOTY_PLATFORM_CAP_LOG;
    extended->write_log = write_log;
    failures += require(axoloty_platform_v1_validate_requirements(
                            extended, AXOLOTY_PLATFORM_CAP_LOG, UINT64_C(1) << 3),
                        "larger same-v1 tail accepted");

    free(extended_storage);
    free(short_carrier_storage);
    free(short_platform_storage);
    if (failures) return 1;
    puts("PASS ABI header, subset, size-prefix and tail cases");
    return 0;
}
