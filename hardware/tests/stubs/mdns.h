// Host stand-in for ESP-IDF's mdns component: records what mdns.c advertises (test_main.c checks it).
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef int esp_err_t;
#define ESP_OK 0
typedef struct { const char *key, *value; } mdns_txt_item_t;

typedef struct {
  char instance[96], type[16], keys[20][16], values[20][80];
  uint16_t port;
  size_t n;
} mdns_stub_service;
extern mdns_stub_service mdns_stub[4];
extern int mdns_stub_count;
extern char mdns_stub_host[32];

esp_err_t mdns_init(void);
esp_err_t mdns_hostname_set(const char *name);
esp_err_t mdns_instance_name_set(const char *name);
esp_err_t mdns_service_add(const char *instance, const char *type, const char *proto, uint16_t port,
                           mdns_txt_item_t *txt, size_t n);
