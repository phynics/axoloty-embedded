// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef TEST_SDKCONFIG_H
#define TEST_SDKCONFIG_H
#define CONFIG_ESP_MAIN_TASK_STACK_SIZE 8192
// The host tests exercise the real trace implementation, which the default
// sdkconfig enables. A production build sets this to n and gets the stub.
#define CONFIG_HEAP_TRACING_STANDALONE 1
#endif
