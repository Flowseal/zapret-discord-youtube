#pragma once

#include <inttypes.h>
#include <stdbool.h>
#include <sys/queue.h>
#include <net/if.h>
#include <sys/socket.h>

struct rawpacket
{
	struct sockaddr_storage dst;
	char ifin[IFNAMSIZ], ifout[IFNAMSIZ];
	uint32_t fwmark;
	size_t len, len_payload;
	uint8_t *packet;
	TAILQ_ENTRY(rawpacket) next;
};
TAILQ_HEAD(rawpacket_tailhead, rawpacket);

void rawpacket_queue_init(struct rawpacket_tailhead *q);
void rawpacket_queue_destroy(struct rawpacket_tailhead *q);
bool rawpacket_queue_empty(const struct rawpacket_tailhead *q);
unsigned int rawpacket_queue_count(const struct rawpacket_tailhead *q);
struct rawpacket *rawpacket_queue(struct rawpacket_tailhead *q,const struct sockaddr_storage* dst,uint32_t fwmark,const char *ifin,const char *ifout,const void *data,size_t len,size_t len_payload);
struct rawpacket *rawpacket_queue_head(struct rawpacket_tailhead *q,const struct sockaddr_storage* dst,uint32_t fwmark,const char *ifin,const char *ifout,const void *data,size_t len,size_t len_payload);
struct rawpacket *rawpacket_dequeue(struct rawpacket_tailhead *q);
void rawpacket_free(struct rawpacket *rp);
