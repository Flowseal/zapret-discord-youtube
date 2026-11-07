#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <sys/socket.h>

bool macsend_preinit(void);
void macsend_cleanup(void);
bool macsend_packet(sa_family_t family, const void *packet, size_t length);
