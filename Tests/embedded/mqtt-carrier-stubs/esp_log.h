// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#ifndef AXOLOTY_STUB_ESP_LOG_H
#define AXOLOTY_STUB_ESP_LOG_H
// The host check counts warnings instead of printing them. The printf
// attribute makes the compiler check the carrier's format strings.
void host_log_warning(const char *tag, const char *format, ...) __attribute__((format(printf, 2, 3)));
#define ESP_LOGW(tag, format, ...) host_log_warning((tag), (format), ##__VA_ARGS__)
#endif
