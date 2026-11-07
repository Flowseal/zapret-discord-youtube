#pragma once


// this conntrack is not bullet-proof
// its designed to satisfy dpi desync needs only

#include <stdbool.h>
#include <stdint.h>
#include <ctype.h>
#include <sys/types.h>
#include <time.h>
#include <netinet/in.h>

#define __FAVOR_BSD
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>

#include "packet_queue.h"
#include "protocol.h"

//#define HASH_BLOOM 20
#define HASH_NONFATAL_OOM 1
#undef HASH_FUNCTION
#define HASH_FUNCTION HASH_BER
#include "uthash.h"

#define RETRANS_COUNTER_STOP ((uint8_t)-1)

typedef union {
	struct in_addr ip;
	struct in6_addr ip6;
} t_addr;
typedef struct
{
	t_addr src, dst;
	uint16_t sport,dport;
	uint8_t	l3proto; // IPPROTO_IP, IPPROTO_IPV6
	uint8_t l4proto; // IPPROTO_TCP, IPPROTO_UDP
} t_conn;

// this structure helps to reassemble continuous packets streams. it does not support out-of-orders
typedef struct {
	uint8_t *packet;		// allocated for size during reassemble request. requestor must know the message size.
	uint32_t seq;			// current seq number. if a packet comes with an unexpected seq - it fails reassemble session.
	size_t size;			// expected message size. success means that we have received exactly 'size' bytes and have them in 'packet'
	size_t size_present;		// how many bytes already stored in 'packet'
} t_reassemble;

// SYN - SYN or SYN/ACK received
// ESTABLISHED - any except SYN or SYN/ACK received
// FIN - FIN or RST received
typedef enum {SYN=0, ESTABLISHED, FIN} t_connstate;

typedef struct
{
	bool bCheckDone, bCheckResult, bCheckExcluded; // hostlist check result cache

	struct desync_profile *dp;		// desync profile cache
	bool dp_search_complete;

	// common state
	time_t t_start, t_last;
	uint64_t pcounter_orig, pcounter_reply;	// packet counter
	uint64_t pdcounter_orig, pdcounter_reply; // data packet counter (with payload)
	uint32_t pos_orig, pos_reply;		// TCP: seq_last+payload, ack_last+payload  UDP: sum of all seen payload lenghts including current
	uint32_t seq_last, ack_last;		// TCP: last seen seq and ack  UDP: sum of all seen payload lenghts NOT including current

	// tcp only state, not used in udp
	t_connstate state;
	uint32_t seq0, ack0;			// starting seq and ack
	uint16_t winsize_orig, winsize_reply;	// last seen window size
	uint8_t scale_orig, scale_reply;	// last seen window scale factor. SCALE_NONE if none

	uint8_t req_retrans_counter;		// number of request retransmissions
	bool req_seq_present,req_seq_finalized,req_seq_abandoned;
	uint32_t req_seq_start,req_seq_end;	// sequence interval of the request (to track retransmissions)

	uint8_t incoming_ttl, desync_autottl, orig_autottl, dup_autottl;
	bool b_autottl_discovered;

	bool b_cutoff;				// mark for deletion
	bool b_wssize_cutoff, b_desync_cutoff, b_dup_cutoff, b_orig_mod_cutoff;

	uint16_t ip_id;

	t_l7proto l7proto;
	bool l7proto_discovered;
	char *hostname;
	bool hostname_is_ip;
	bool hostname_discovered;
	bool hostname_ah_check;			// should perform autohostlist checks

	t_reassemble reasm_orig;
	struct rawpacket_tailhead delayed;
	bool delayed_first_gap;
} t_ctrack;

typedef struct
{
	t_ctrack track;
	UT_hash_handle hh;	// makes this structure hashable
	t_conn conn;		// key
} t_conntrack_pool;
typedef struct
{
	// inactivity time to purge an entry in each connection state
	uint32_t timeout_syn,timeout_established,timeout_fin,timeout_udp;
	time_t t_purge_interval, t_last_purge;
	t_conntrack_pool *pool;
} t_conntrack;

void ConntrackPoolInit(t_conntrack *p, time_t purge_interval, uint32_t timeout_syn, uint32_t timeout_established, uint32_t timeout_fin, uint32_t timeout_udp);
void ConntrackPoolDestroy(t_conntrack *p);
bool ConntrackPoolFeed(t_conntrack *p, const struct ip *ip, const struct ip6_hdr *ip6, const struct tcphdr *tcphdr, const struct udphdr *udphdr, size_t len_payload, t_ctrack **ctrack, bool *bReverse);
// do not create, do not update. only find existing
bool ConntrackPoolDoubleSearch(t_conntrack *p, const struct ip *ip, const struct ip6_hdr *ip6, const struct tcphdr *tcphdr, const struct udphdr *udphdr, t_ctrack **ctrack, bool *bReverse);
bool ConntrackPoolDrop(t_conntrack *p, const struct ip *ip, const struct ip6_hdr *ip6, const struct tcphdr *tcphdr, const struct udphdr *udphdr);
void CaonntrackExtractConn(t_conn *c, bool bReverse, const struct ip *ip, const struct ip6_hdr *ip6, const struct tcphdr *tcphdr, const struct udphdr *udphdr);
void ConntrackPoolDump(const t_conntrack *p);
void ConntrackPoolPurge(t_conntrack *p);
void ConntrackClearHostname(t_ctrack *track);

bool ReasmInit(t_reassemble *reasm, size_t size_requested, uint32_t seq_start);
bool ReasmResize(t_reassemble *reasm, size_t new_size);
void ReasmClear(t_reassemble *reasm);
// false means reassemble session has failed and we should ReasmClear() it
bool ReasmFeed(t_reassemble *reasm, uint32_t seq, const void *payload, size_t len);
// check if it has enough space to buffer 'len' bytes
bool ReasmHasSpace(t_reassemble *reasm, size_t len);
inline static bool ReasmIsEmpty(t_reassemble *reasm) {return !reasm->size;}
inline static bool ReasmIsFull(t_reassemble *reasm) {return !ReasmIsEmpty(reasm) && (reasm->size==reasm->size_present);}
