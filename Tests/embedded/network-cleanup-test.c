// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Hardware-free check of the Wi-Fi teardown in network_bootstrap.c (#129).
//
// The stub driver is asynchronous like the real one: disconnect and stop queue
// an event, and a queued event reaches the registered handler only when the
// caller waits on the event group. esp_wifi_deinit fails, as the real driver
// times out, when events are still queued or the driver has not stopped. A
// cleanup that deinitializes right after asking for the stop therefore fails
// here, and one that waits for the driver's reports passes.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "esp_stubs.h"
#include "network_bootstrap.h"

esp_event_base_t WIFI_EVENT = "WIFI_EVENT";
esp_event_base_t IP_EVENT = "IP_EVENT";

struct EventGroup { EventBits_t bits; };
typedef struct { esp_event_base_t base; int32_t id; } QueuedEvent;

static QueuedEvent queue[16];
static int queued;
static struct { esp_event_handler_t handler; esp_event_base_t base; } handlers[4];
static EventGroupHandle_t group;
static int associated, started, initialized;
static int connect_calls, wait_calls, deinit_pending_at_call = -1, force_deinit_failure;
static char order[512];
static char warning[160];

static void note(const char *step) {
    if (strlen(order) + strlen(step) + 2 >= sizeof(order)) abort();
    if (order[0] != '\0') strcat(order, ",");
    strcat(order, step);
}
static void post(esp_event_base_t base, int32_t id) {
    if (queued == 16) abort();
    queue[queued++] = (QueuedEvent){ base, id };
}
static void pump(void) {
    while (queued > 0) {
        QueuedEvent event = queue[0];
        memmove(queue, queue + 1, sizeof(queue[0]) * (size_t)(--queued));
        if (event.base == WIFI_EVENT && event.id == WIFI_EVENT_STA_STOP) note("event:stop");
        if (event.base == WIFI_EVENT && event.id == WIFI_EVENT_STA_DISCONNECTED) note("event:disconnected");
        for (int index = 0; index < 4; ++index) {
            if (handlers[index].handler && handlers[index].base == event.base) handlers[index].handler(NULL, event.base, event.id, NULL);
        }
    }
}

int64_t esp_timer_get_time(void) { return 0; }
void vTaskDelay(TickType_t ticks) { (void)ticks; }
void stub_log_warning(const char *tag, const char *format, ...) {
    (void)tag;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(warning, sizeof(warning), format, arguments);
    va_end(arguments);
}
void esp_log_level_set(const char *tag, int level) { (void)tag; (void)level; }
esp_err_t esp_event_handler_register(esp_event_base_t base, int32_t id, esp_event_handler_t handler, void *arg) {
    (void)id; (void)arg;
    for (int index = 0; index < 4; ++index) if (!handlers[index].handler) { handlers[index].handler = handler; handlers[index].base = base; return ESP_OK; }
    return ESP_FAIL;
}
esp_err_t esp_event_handler_unregister(esp_event_base_t base, int32_t id, esp_event_handler_t handler) {
    (void)id;
    note(base == WIFI_EVENT ? "unregister:wifi" : "unregister:ip");
    for (int index = 0; index < 4; ++index) if (handlers[index].handler == handler) handlers[index].handler = NULL;
    return ESP_OK;
}
esp_err_t esp_event_loop_create_default(void) { return ESP_OK; }
esp_err_t esp_event_loop_delete_default(void) { return ESP_OK; }
esp_err_t esp_netif_init(void) { return ESP_OK; }
esp_netif_t *esp_netif_create_default_wifi_sta(void) { return (esp_netif_t *)&group; }
void esp_netif_destroy_default_wifi(void *netif) { (void)netif; }
esp_err_t esp_wifi_init(const wifi_init_config_t *config) { (void)config; initialized = 1; return ESP_OK; }
esp_err_t esp_wifi_deinit(void) {
    note("deinit");
    deinit_pending_at_call = queued;
    if (force_deinit_failure || queued > 0 || started) return ESP_FAIL;
    initialized = 0;
    return ESP_OK;
}
esp_err_t esp_wifi_set_mode(int mode) { (void)mode; return ESP_OK; }
esp_err_t esp_wifi_set_config(int interface, wifi_config_t *config) { (void)interface; (void)config; return ESP_OK; }
esp_err_t esp_wifi_start(void) { started = 1; post(WIFI_EVENT, WIFI_EVENT_STA_START); return ESP_OK; }
esp_err_t esp_wifi_stop(void) { note("stop"); started = 0; post(WIFI_EVENT, WIFI_EVENT_STA_STOP); return ESP_OK; }
esp_err_t esp_wifi_connect(void) { ++connect_calls; associated = 1; post(IP_EVENT, IP_EVENT_STA_GOT_IP); return ESP_OK; }
esp_err_t esp_wifi_disconnect(void) {
    note("disconnect");
    if (associated) { associated = 0; post(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED); }
    return ESP_OK;
}
esp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *record) { (void)record; return associated ? ESP_OK : ESP_FAIL; }
esp_err_t nvs_flash_init(void) { return ESP_OK; }
esp_err_t nvs_flash_erase(void) { return ESP_OK; }
EventGroupHandle_t xEventGroupCreate(void) { group = calloc(1, sizeof(*group)); return group; }
void vEventGroupDelete(EventGroupHandle_t handle) { free(handle); group = NULL; }
EventBits_t xEventGroupSetBits(EventGroupHandle_t handle, EventBits_t bits) { handle->bits |= bits; return handle->bits; }
EventBits_t xEventGroupClearBits(EventGroupHandle_t handle, EventBits_t bits) { handle->bits &= ~bits; return handle->bits; }
EventBits_t xEventGroupWaitBits(EventGroupHandle_t handle, EventBits_t bits, int clear, int all, TickType_t ticks) {
    (void)all; (void)ticks;
    ++wait_calls;
    pump();
    EventBits_t seen = handle->bits & bits;
    if (clear) handle->bits &= ~bits;
    return seen;
}

static void fail(const char *message) {
    fprintf(stderr, "network-cleanup-test: %s (order: %s)\n", message, order);
    exit(1);
}
static void reset(void) {
    memset(handlers, 0, sizeof(handlers));
    queued = 0; associated = started = initialized = 0;
    connect_calls = wait_calls = 0; deinit_pending_at_call = -1; force_deinit_failure = 0;
    order[0] = '\0'; warning[0] = '\0';
}
static void bring_up(void) {
    reset();
    if (axoloty_network_prepare(10000) != 3U) fail("the stub network did not come up");
    order[0] = '\0';
    connect_calls = 0;
}

int main(void) {
    // An associated station: disconnect, wait for the report, stop, wait for the
    // report, and only then take the handler away and deinitialize.
    bring_up();
    if (axoloty_network_cleanup() != 1U) fail("a clean teardown reported failure");
    const char *expected = "disconnect,event:disconnected,stop,event:stop,unregister:wifi,unregister:ip,deinit";
    if (strcmp(order, expected) != 0) { fprintf(stderr, "expected: %s\n", expected); fail("teardown order"); }
    if (deinit_pending_at_call != 0) fail("deinit ran with driver events still queued");
    if (connect_calls != 0) fail("teardown asked the driver to reconnect");
    if (warning[0] != '\0') fail("a clean teardown logged a warning");

    // A station that is not associated has no disconnect to wait for.
    bring_up();
    associated = 0;
    wait_calls = 0;
    if (axoloty_network_cleanup() != 1U) fail("teardown of an unassociated station failed");
    if (wait_calls != 1) fail("teardown waited for a disconnect that was not coming");
    if (strstr(order, "event:disconnected") != NULL) fail("a disconnect event appeared for an unassociated station");

    // A failure of the driver is reported to the caller and on the log.
    bring_up();
    force_deinit_failure = 1;
    if (axoloty_network_cleanup() != 0U) fail("a failed deinit reported success");
    if (strstr(warning, "deinit=-1") == NULL) fail("a failed deinit was not logged");

    // Reconnection while running is unchanged: a lost association is retried.
    bring_up();
    post(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED);
    pump();
    if (connect_calls != 1) fail("a lost association was not retried");
    axoloty_network_cleanup();

    puts("network cleanup tests passed");
    return 0;
}
