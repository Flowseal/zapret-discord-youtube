#pragma once

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <netinet/in.h>

#define __FAVOR_BSD
#include <netinet/ip6.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>

uint16_t csum_partial(const void *buff, size_t len);
uint16_t csum_tcpudp_magic(uint32_t saddr, uint32_t daddr, size_t len, uint8_t proto, uint16_t sum);
uint16_t csum_ipv6_magic(const void *saddr, const void *daddr, size_t len, uint8_t proto, uint16_t sum);

uint16_t ip4_compute_csum(const void *buff, size_t len);
void ip4_fix_checksum(struct ip *ip);

void tcp4_fix_checksum(struct tcphdr *tcp,size_t len, const struct in_addr *src_addr, const struct in_addr *dest_addr);
void tcp6_fix_checksum(struct tcphdr *tcp,size_t len, const struct in6_addr *src_addr, const struct in6_addr *dest_addr);
void tcp_fix_checksum(struct tcphdr *tcp,size_t len,const struct ip *ip,const struct ip6_hdr *ip6hdr);

void udp4_fix_checksum(struct udphdr *udp,size_t len, const struct in_addr *src_addr, const struct in_addr *dest_addr);
void udp6_fix_checksum(struct udphdr *udp,size_t len, const struct in6_addr *src_addr, const struct in6_addr *dest_addr);
void udp_fix_checksum(struct udphdr *udp,size_t len,const struct ip *ip,const struct ip6_hdr *ip6hdr);
