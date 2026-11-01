// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// A line-driven Zenoh client for the largest-frame check (frame-probe.mjs).
//
//   zenoh-frame-io <endpoint> <subscribe-key-expression>
//
// Prints `ready` once the session is open and the subscriber declared, then one
// `rx <key> <payload-hex>` line per sample. Reads `put <key> <payload-hex>` and
// `quit` from standard input. It publishes whatever bytes it is given, which is
// the point: the runtime API a host peer uses never emits a frame it does not
// consider legal.
//
// Build against zenoh-c:  cc zenoh-frame-io.c -I<zenoh-c>/include -L<zenoh-c>/lib -lzenohc

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zenoh.h>

static void print_sample(z_loaned_sample_t *sample, void *context) {
    (void)context;
    z_view_string_t key_view;
    z_keyexpr_as_view_string(z_sample_keyexpr(sample), &key_view);
    const z_loaned_string_t *key = z_view_string_loan(&key_view);
    z_owned_slice_t bytes;
    if (z_bytes_to_slice(z_sample_payload(sample), &bytes) != Z_OK) return;
    const uint8_t *data = z_slice_data(z_slice_loan(&bytes));
    size_t length = z_slice_len(z_slice_loan(&bytes));
    printf("rx %.*s ", (int)z_string_len(key), z_string_data(key));
    for (size_t index = 0; index < length; ++index) printf("%02x", data[index]);
    printf("\n");
    fflush(stdout);
    z_slice_drop(z_slice_move(&bytes));
}

static int hex_value(int character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: zenoh-frame-io <endpoint> <subscribe-key-expression>\n");
        return 64;
    }
    char endpoints[600];
    snprintf(endpoints, sizeof(endpoints), "[\"%s\"]", argv[1]);

    z_owned_config_t config;
    z_config_default(&config);
    if (zc_config_insert_json5(z_loan_mut(config), "mode", "\"client\"") < 0 ||
        zc_config_insert_json5(z_loan_mut(config), "connect/endpoints", endpoints) < 0 ||
        zc_config_insert_json5(z_loan_mut(config), "scouting/multicast/enabled", "false") < 0) {
        fprintf(stderr, "cannot configure the session\n");
        return 1;
    }
    z_owned_session_t session;
    if (z_open(&session, z_move(config), NULL) < 0) {
        fprintf(stderr, "cannot open the session\n");
        return 1;
    }
    z_view_keyexpr_t filter;
    if (z_view_keyexpr_from_str(&filter, argv[2]) < 0) {
        fprintf(stderr, "bad key expression\n");
        return 1;
    }
    z_owned_closure_sample_t callback;
    z_closure(&callback, print_sample, NULL, NULL);
    z_owned_subscriber_t subscriber;
    if (z_declare_subscriber(z_loan(session), &subscriber, z_loan(filter), z_move(callback), NULL) < 0) {
        fprintf(stderr, "cannot declare the subscriber\n");
        return 1;
    }
    printf("ready\n");
    fflush(stdout);

    static char line[16 * 1024];
    while (fgets(line, sizeof(line), stdin)) {
        if (strncmp(line, "quit", 4) == 0) break;
        if (strncmp(line, "put ", 4) != 0) continue;
        char *key = line + 4;
        char *space = strchr(key, ' ');
        if (!space) continue;
        *space = '\0';
        char *hex = space + 1;
        size_t hex_length = strcspn(hex, "\r\n");
        size_t length = hex_length / 2;
        uint8_t *payload = malloc(length ? length : 1);
        for (size_t index = 0; index < length; ++index) {
            payload[index] = (uint8_t)(hex_value(hex[2 * index]) * 16 + hex_value(hex[2 * index + 1]));
        }
        z_view_keyexpr_t target;
        if (z_view_keyexpr_from_str(&target, key) < 0) {
            fprintf(stderr, "bad put key\n");
            free(payload);
            continue;
        }
        z_owned_bytes_t body;
        z_bytes_copy_from_buf(&body, payload, length);
        free(payload);
        if (z_put(z_loan(session), z_loan(target), z_move(body), NULL) < 0) fprintf(stderr, "put failed\n");
    }
    z_drop(z_move(subscriber));
    z_drop(z_move(session));
    return 0;
}
