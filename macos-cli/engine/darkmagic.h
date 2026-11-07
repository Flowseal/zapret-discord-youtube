#pragma once

#include "nfqws.h"
#include "checksum.h"
#include "packet_queue.h"
#include "pools.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/param.h>
#include <netinet/in.h>

#define __FAVOR_BSD
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>

#ifndef IPV6_FREEBIND
#define IPV6_FREEBIND           78
#endif

#ifdef __CYGWIN__
#define INITGUID
#include "windivert/windivert.h"
#endif

#ifndef IPPROTO_DIVERT
#define IPPROTO_DIVERT 258
#endif

#ifndef AF_DIVERT
#define	AF_DIVERT	44	/* divert(4) */
#endif
#ifndef PF_DIVERT
#define PF_DIVERT AF_DIVERT
#endif

// returns netorder value
uint32_t net32_add(uint32_t netorder_value, uint32_t cpuorder_increment);
uint32_t net16_add(uint16_t netorder_value, uint16_t cpuorder_increment);

#define FOOL_NONE	0x00
#define FOOL_MD5SIG	0x01
#define FOOL_BADSUM	0x02
#define FOOL_TS		0x04
#define FOOL_BADSEQ	0x08
#define FOOL_HOPBYHOP	0x10
#define FOOL_HOPBYHOP2	0x20
#define FOOL_DESTOPT	0x40
#define FOOL_IPFRAG1	0x80
#define FOOL_DATANOACK	0x100

#define SCALE_NONE ((uint8_t)-1)

#define VERDICT_PASS	0
#define VERDICT_MODIFY	1
#define VERDICT_DROP	2
#define VERDICT_MASK	3
#define VERDICT_NOCSUM	4
#define VERDICT_GARBAGE	8

#define IP4_TOS(ip_header) (ip_header ? ip_header->ip_tos : 0)
#define IP4_IP_ID(ip_header) (ip_header ? ip_header->ip_id : 0)
#define IP6_FLOW(ip6_header) (ip6_header ? ip6_header->ip6_ctlun.ip6_un1.ip6_un1_flow : 0)

// seq and wsize have network byte order
bool prepare_tcp_segment4(
	const struct sockaddr_in *src, const struct sockaddr_in *dst,
	uint16_t tcp_flags,
	bool sack,
	uint16_t nmss,
	uint32_t nseq, uint32_t nack_seq,
	uint16_t nwsize,
	uint8_t scale_factor,
	uint32_t *timestamps,
	bool DF,
	uint8_t ttl,
	uint8_t tos,
	uint16_t ip_id,
	uint32_t fooling,
	uint32_t ts_increment,
	uint32_t badseq_increment,
	uint32_t badseq_ack_increment,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen);
bool prepare_tcp_segment6(
	const struct sockaddr_in6 *src, const struct sockaddr_in6 *dst,
	uint16_t tcp_flags,
	bool sack,
	uint16_t nmss,
	uint32_t nseq, uint32_t nack_seq,
	uint16_t nwsize,
	uint8_t scale_factor,
	uint32_t *timestamps,
	uint8_t ttl,
	uint32_t flow_label,
	uint32_t fooling,
	uint32_t ts_increment,
	uint32_t badseq_increment,
	uint32_t badseq_ack_increment,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen);
bool prepare_tcp_segment(
	const struct sockaddr *src, const struct sockaddr *dst,
	uint16_t tcp_flags,
	bool sack,
	uint16_t nmss,
	uint32_t nseq, uint32_t nack_seq,
	uint16_t nwsize,
	uint8_t scale_factor,
	uint32_t *timestamps,
	bool DF,
	uint8_t ttl,
	uint8_t tos,
	uint16_t ip_id,
	uint32_t flow_label,
	uint32_t fooling,
	uint32_t ts_increment,
	uint32_t badseq_increment,
	uint32_t badseq_ack_increment,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen);


bool prepare_udp_segment4(
	const struct sockaddr_in *src, const struct sockaddr_in *dst,
	bool DF,
	uint8_t ttl,
	uint8_t tos,
	uint16_t ip_id,
	uint32_t fooling,
	const uint8_t *padding, size_t padding_size,
	int padlen,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen);
bool prepare_udp_segment6(
	const struct sockaddr_in6 *src, const struct sockaddr_in6 *dst,
	uint8_t ttl,
	uint32_t flow_label,
	uint32_t fooling,
	const uint8_t *padding, size_t padding_size,
	int padlen,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen);
bool prepare_udp_segment(
	const struct sockaddr *src, const struct sockaddr *dst,
	bool DF,
	uint8_t ttl,
	uint8_t tos,
	uint16_t ip_id,
	uint32_t flow_label,
	uint32_t fooling,
	const uint8_t *padding, size_t padding_size,
	int padlen,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen);

bool ip6_insert_simple_hdr(uint8_t type, uint8_t *data_pkt, size_t len_pkt, uint8_t *buf, size_t *buflen);

// ipv4: ident==-1 - copy ip_id from original ipv4 packet
bool ip_frag4(
	const uint8_t *pkt, size_t pkt_size,
	size_t frag_pos, uint32_t ident,
	uint8_t *pkt1, size_t *pkt1_size,
	uint8_t *pkt2, size_t *pkt2_size);
bool ip_frag6(
	const uint8_t *pkt, size_t pkt_size,
	size_t frag_pos, uint32_t ident,
	uint8_t *pkt1, size_t *pkt1_size,
	uint8_t *pkt2, size_t *pkt2_size);
bool ip_frag(
	const uint8_t *pkt, size_t pkt_size,
	size_t frag_pos, uint32_t ident,
	uint8_t *pkt1, size_t *pkt1_size,
	uint8_t *pkt2, size_t *pkt2_size);

bool rewrite_ttl(struct ip *ip, struct ip6_hdr *ip6, uint8_t ttl);
uint16_t get_tcp_flags(const struct tcphdr *tcp);
void apply_tcp_flags(struct tcphdr *tcp, uint16_t fl);

void extract_ports(const struct tcphdr *tcphdr, const struct udphdr *udphdr, uint8_t *proto, uint16_t *sport, uint16_t *dport);
void extract_endpoints(const struct ip *ip,const struct ip6_hdr *ip6hdr,const struct tcphdr *tcphdr,const struct udphdr *udphdr, struct sockaddr_storage *src, struct sockaddr_storage *dst);
uint8_t *tcp_find_option(struct tcphdr *tcp, uint8_t kind);
uint32_t *tcp_find_timestamps(struct tcphdr *tcp);
uint8_t tcp_find_scale_factor(const struct tcphdr *tcp);
uint16_t tcp_find_mss(struct tcphdr *tcp);
bool tcp_has_sack(struct tcphdr *tcp);

bool tcp_has_fastopen(const struct tcphdr *tcp);

bool ip_has_df(const struct ip *ip);

#ifdef __CYGWIN__
extern uint32_t w_win32_error;

bool win_dark_init(const struct str_list_head *ssid_filter, const struct str_list_head *nlm_filter);
bool win_dark_deinit(void);
bool logical_net_filter_match(void);
bool nlm_list(bool bAll);
bool windivert_init(const char *filter);
bool windivert_recv(uint8_t *packet, size_t *len, WINDIVERT_ADDRESS *wa);
bool windivert_send(const uint8_t *packet, size_t len, const WINDIVERT_ADDRESS *wa);
#else
// should pre-do it if dropping privileges. otherwise its not necessary
bool rawsend_preinit(bool bind_fix4, bool bind_fix6);
#endif

// auto creates internal socket and uses it for subsequent calls
bool rawsend(const struct sockaddr* dst,uint32_t fwmark,const char *ifout,const void *data,size_t len);
bool rawsend_rp(const struct rawpacket *rp);
// return trues if all packets were send successfully
bool rawsend_queue(struct rawpacket_tailhead *q);
// cleans up socket autocreated by rawsend
void rawsend_cleanup(void);

#ifdef BSD
int socket_divert(sa_family_t family);
#endif

const char *proto_name(uint8_t proto);
uint16_t family_from_proto(uint8_t l3proto);
void print_ip(const struct ip *ip);
void print_ip6hdr(const struct ip6_hdr *ip6hdr, uint8_t proto);
void print_tcphdr(const struct tcphdr *tcphdr);
void print_udphdr(const struct udphdr *udphdr);
void str_ip(char *s, size_t s_len, const struct ip *ip);
void str_ip6hdr(char *s, size_t s_len, const struct ip6_hdr *ip6hdr, uint8_t proto);
void str_srcdst_ip6(char *s, size_t s_len, const void *saddr,const void *daddr);
void str_tcphdr(char *s, size_t s_len, const struct tcphdr *tcphdr);
void str_udphdr(char *s, size_t s_len, const struct udphdr *udphdr);

bool proto_check_ipv4(const uint8_t *data, size_t len);
void proto_skip_ipv4(uint8_t **data, size_t *len);
bool proto_check_ipv6(const uint8_t *data, size_t len);
void proto_skip_ipv6(uint8_t **data, size_t *len, uint8_t *proto_type, uint8_t **last_header_type);
bool proto_check_tcp(const uint8_t *data, size_t len);
void proto_skip_tcp(uint8_t **data, size_t *len);
bool proto_check_udp(const uint8_t *data, size_t len);
void proto_skip_udp(uint8_t **data, size_t *len);
struct dissect
{
	uint8_t *data_pkt;
	size_t len_pkt;
	struct ip *ip;
	struct ip6_hdr *ip6;
	uint8_t proto;
	struct tcphdr *tcp;
	struct udphdr *udp;
	size_t transport_len;
	uint8_t *data_payload;
	size_t len_payload;
};
void proto_dissect_l3l4(uint8_t *data, size_t len,struct dissect *dis);

bool tcp_synack_segment(const struct tcphdr *tcphdr);
bool tcp_syn_segment(const struct tcphdr *tcphdr);
bool tcp_ack_segment(const struct tcphdr *tcphdr);
// scale_factor=SCALE_NONE - do not change
void tcp_rewrite_wscale(struct tcphdr *tcp, uint8_t scale_factor);
void tcp_rewrite_winsize(struct tcphdr *tcp, uint16_t winsize, uint8_t scale_factor);

typedef struct
{
	int8_t delta;
	uint8_t min, max;
} autottl;
#define AUTOTTL_ENABLED(a) ((a).delta || (a).min || (a).max)

uint8_t hop_count_guess(uint8_t ttl);
uint8_t autottl_eval(uint8_t hop_count, const autottl *attl);
void do_nat(bool bOutbound, struct ip *ip, struct ip6_hdr *ip6, struct tcphdr *tcphdr, struct udphdr *udphdr, const struct sockaddr_in *target4, const struct sockaddr_in6 *target6);

void verdict_tcp_csum_fix(uint8_t verdict, struct tcphdr *tcphdr, size_t transport_len, struct ip *ip, struct ip6_hdr *ip6hdr);
void verdict_udp_csum_fix(uint8_t verdict, struct udphdr *udphdr, size_t transport_len, struct ip *ip, struct ip6_hdr *ip6hdr);

void dbgprint_socket_buffers(int fd);
bool set_socket_buffers(int fd, int rcvbuf, int sndbuf);


#ifdef HAS_FILTER_SSID

struct wlan_interface
{
	int ifindex;
	char ifname[IFNAMSIZ], ssid[33];
};
#define WLAN_INTERFACE_MAX 16
struct wlan_interface_collection
{
	int count;
	struct wlan_interface wlan[WLAN_INTERFACE_MAX];
};

extern struct wlan_interface_collection wlans;

void wlan_info_deinit(void);
bool wlan_info_init(void);
bool wlan_info_get_rate_limited(void);
const char *wlan_ssid_search_ifname(const char *ifname);
const char *wlan_ssid_search_ifidx(int ifidx);

#endif
