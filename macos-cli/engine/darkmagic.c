#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/param.h>
#include <errno.h>
#include <fcntl.h>

#ifndef IP_NODEFRAG
// for very old toolchains
#define IP_NODEFRAG     22
#endif

#include "darkmagic.h"
#include "helpers.h"
#include "params.h"
#include "nfqws.h"
#ifdef __APPLE__
#include "macsend.h"
#endif

#ifdef __CYGWIN__
#include <wlanapi.h>
#include <netlistmgr.h>

#ifndef ERROR_INVALID_IMAGE_HASH
#define ERROR_INVALID_IMAGE_HASH __MSABI_LONG(577)
#endif

#endif

#ifdef __linux__
#include <linux/nl80211.h>
#include <linux/genetlink.h>
#include <libmnl/libmnl.h>
#include <net/if.h>
#define _LINUX_IF_H // prevent conflict between linux/if.h and net/if.h in old gcc 4.x
#include <linux/wireless.h>
#include <sys/ioctl.h>
#endif

uint32_t net32_add(uint32_t netorder_value, uint32_t cpuorder_increment)
{
	return htonl(ntohl(netorder_value)+cpuorder_increment);
}
uint32_t net16_add(uint16_t netorder_value, uint16_t cpuorder_increment)
{
	return htons(ntohs(netorder_value)+cpuorder_increment);
}

bool ip_has_df(const struct ip *ip)
{
	return ip && !!(ntohs(ip->ip_off) & IP_DF);
}

uint8_t *tcp_find_option(struct tcphdr *tcp, uint8_t kind)
{
	uint8_t *t = (uint8_t*)(tcp+1);
	uint8_t *end = (uint8_t*)tcp + (tcp->th_off<<2);
	while(t<end)
	{
		switch(*t)
		{
			case 0: // end
				return NULL;
			case 1: // noop
				t++;
				break;
			default: // kind,len,data
				if ((t+1)>=end || t[1]<2 || (t+t[1])>end)
					return NULL;
				if (*t==kind)
					return t;
				t+=t[1];
				break;
		}
	}
	return NULL;
}
uint32_t *tcp_find_timestamps(struct tcphdr *tcp)
{
	uint8_t *t = tcp_find_option(tcp,8);
	return (t && t[1]==10) ? (uint32_t*)(t+2) : NULL;
}
uint8_t tcp_find_scale_factor(const struct tcphdr *tcp)
{
	uint8_t *scale = tcp_find_option((struct tcphdr*)tcp,3); // tcp option 3 - scale factor
	if (scale && scale[1]==3) return scale[2];
	return SCALE_NONE;
}
bool tcp_has_fastopen(const struct tcphdr *tcp)
{
	uint8_t *opt;
	// new style RFC7413
	opt = tcp_find_option((struct tcphdr*)tcp, 34);
	if (opt) return true;
	// old style RFC6994
	opt = tcp_find_option((struct tcphdr*)tcp, 254);
	return opt && opt[1]>=4 && opt[2]==0xF9 && opt[3]==0x89;
}
uint16_t tcp_find_mss(struct tcphdr *tcp)
{
	uint8_t *t = tcp_find_option(tcp,2);
	return (t && t[1]==4) ? *(uint16_t*)(t+2) : 0;
}
bool tcp_has_sack(struct tcphdr *tcp)
{
	uint8_t *t = tcp_find_option(tcp,4);
	return !!t;
}

// n prefix (nsport, nwsize) means network byte order
static void fill_tcphdr(
	struct tcphdr *tcp, uint32_t fooling, uint16_t tcp_flags,
	bool sack,
	uint16_t nmss,
	uint32_t nseq, uint32_t nack_seq,
	uint16_t nsport, uint16_t ndport,
	uint16_t nwsize, uint8_t scale_factor,
	uint32_t *timestamps,
	uint32_t ts_increment,
	uint32_t badseq_increment,
	uint32_t badseq_ack_increment,
	uint16_t data_len)
{
	char *tcpopt = (char*)(tcp+1);
	uint8_t t=0;

	memset(tcp,0,sizeof(*tcp));
	tcp->th_sport = nsport;
	tcp->th_dport = ndport;
	if (fooling & FOOL_BADSEQ)
	{
		tcp->th_seq = net32_add(nseq,badseq_increment);
		tcp->th_ack = net32_add(nack_seq,badseq_ack_increment);
	}
	else
	{
		tcp->th_seq = nseq;
		tcp->th_ack = nack_seq;
	}
	tcp->th_off = 5;
	if ((fooling & FOOL_DATANOACK) && !(tcp_flags & (TH_SYN|TH_RST)) && data_len)
		tcp_flags &= ~TH_ACK;
	tcp->th_flags = (uint8_t)tcp_flags;
	tcp->th_x2 = (tcp_flags>>8) & 0xF;
	tcp->th_win     = nwsize;
	if (nmss)
	{
		tcpopt[t++] = 2; // kind
		tcpopt[t++] = 4; // len
		*(uint16_t*)(tcpopt+t) = nmss;
		t+=2;
	}
	if (sack)
	{
		tcpopt[t++] = 4; // kind
		tcpopt[t++] = 2; // len
	}
	if (fooling & FOOL_MD5SIG)
	{
		tcpopt[t] = 19; // kind
		tcpopt[t+1] = 18; // len
		*(uint32_t*)(tcpopt+t+2)=random();
		*(uint32_t*)(tcpopt+t+6)=random();
		*(uint32_t*)(tcpopt+t+10)=random();
		*(uint32_t*)(tcpopt+t+14)=random();
		t+=18;
	}
	if (timestamps)
	{
		tcpopt[t] = 8; // kind
		tcpopt[t+1] = 10; // len
		memcpy(tcpopt+t+2,timestamps,8);
		// forge TSval, keep TSecr
		if (fooling & FOOL_TS) *(uint32_t*)(tcpopt+t+2) = net32_add(*(uint32_t*)(tcpopt+t+2),ts_increment);
		t+=10;
	}
	if (scale_factor!=SCALE_NONE)
	{
		tcpopt[t++]=3;
		tcpopt[t++]=3;
		tcpopt[t++]=scale_factor;
	}
	while (t&3) tcpopt[t++]=1; // noop
	tcp->th_off += t>>2;
	tcp->th_sum = 0;
}
static uint16_t tcpopt_len(bool sack, bool mss, uint32_t fooling, const uint32_t *timestamps, uint8_t scale_factor)
{
	uint16_t t=0;
	if (sack) t+=2;
	if (mss) t+=4;
	if (fooling & FOOL_MD5SIG) t+=18;
	if (timestamps) t+=10;
	if (scale_factor!=SCALE_NONE) t+=3;
	return (t+3)&~3;
}

// n prefix (nsport, nwsize) means network byte order
static void fill_udphdr(struct udphdr *udp, uint16_t nsport, uint16_t ndport, uint16_t len_payload)
{
	udp->uh_sport = nsport;
	udp->uh_dport = ndport;
	udp->uh_ulen = htons(len_payload+sizeof(struct udphdr));
	udp->uh_sum = 0;
}

static void fill_iphdr(struct ip *ip, const struct in_addr *src, const struct in_addr *dst, uint16_t pktlen, uint8_t proto, bool DF, uint8_t ttl, uint8_t tos, uint16_t ip_id)
{
	ip->ip_tos = tos;
	ip->ip_sum = 0;
	ip->ip_off = DF ? htons(IP_DF) : 0;
	ip->ip_v = 4;
	ip->ip_hl = 5;
	ip->ip_len = htons(pktlen);
	ip->ip_id = ip_id;
	ip->ip_ttl = ttl;
	ip->ip_p = proto;
	ip->ip_src = *src;
	ip->ip_dst = *dst;
}
static void fill_ip6hdr(struct ip6_hdr *ip6, const struct in6_addr *src, const struct in6_addr *dst, uint16_t payloadlen, uint8_t proto, uint8_t ttl, uint32_t flow_label)
{
	ip6->ip6_ctlun.ip6_un1.ip6_un1_flow = htonl(ntohl(flow_label) & 0x0FFFFFFF | 0x60000000);
	ip6->ip6_ctlun.ip6_un1.ip6_un1_plen = htons(payloadlen);
	ip6->ip6_ctlun.ip6_un1.ip6_un1_nxt = proto;
	ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim = ttl;
	ip6->ip6_src = *src;
	ip6->ip6_dst = *dst;
}

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
	uint8_t *buf, size_t *buflen)
{
	uint16_t tcpoptlen = tcpopt_len(sack,!!nmss,fooling,timestamps,scale_factor);
	uint16_t ip_payload_len = sizeof(struct tcphdr) + tcpoptlen + len;
	uint16_t pktlen = sizeof(struct ip) + ip_payload_len;
	if (pktlen>*buflen) return false;

	struct ip *ip = (struct ip*)buf;
	struct tcphdr *tcp = (struct tcphdr*)(ip+1);
	uint8_t *payload = (uint8_t*)(tcp+1)+tcpoptlen;

	fill_iphdr(ip, &src->sin_addr, &dst->sin_addr, pktlen, IPPROTO_TCP, DF, ttl, tos, ip_id);
	fill_tcphdr(tcp,fooling,tcp_flags,sack,nmss,nseq,nack_seq,src->sin_port,dst->sin_port,nwsize,scale_factor,timestamps,ts_increment,badseq_increment,badseq_ack_increment,len);

	memcpy(payload,data,len);
	tcp4_fix_checksum(tcp,ip_payload_len,&ip->ip_src,&ip->ip_dst);
	if (fooling & FOOL_BADSUM) tcp->th_sum^=(uint16_t)(1+random()%0xFFFF);

	*buflen = pktlen;
	return true;
}

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
	uint8_t *buf, size_t *buflen)
{
	uint16_t tcpoptlen = tcpopt_len(sack,!!nmss,fooling,timestamps,scale_factor);
	uint16_t transport_payload_len = sizeof(struct tcphdr) + tcpoptlen + len;
	uint16_t ip_payload_len = transport_payload_len +
		8*!!((fooling & (FOOL_HOPBYHOP|FOOL_HOPBYHOP2))==FOOL_HOPBYHOP) +
		16*!!(fooling & FOOL_HOPBYHOP2) +
		8*!!(fooling & FOOL_DESTOPT) +
		8*!!(fooling & FOOL_IPFRAG1);
	uint16_t pktlen = sizeof(struct ip6_hdr) + ip_payload_len;
	if (pktlen>*buflen) return false;

	struct ip6_hdr *ip6 = (struct ip6_hdr*)buf;
	struct tcphdr *tcp = (struct tcphdr*)(ip6+1);
	uint8_t proto = IPPROTO_TCP, *nexttype = NULL;

	if (fooling & (FOOL_HOPBYHOP|FOOL_HOPBYHOP2))
	{
		struct ip6_hbh *hbh = (struct ip6_hbh*)tcp;
		tcp = (struct tcphdr*)((uint8_t*)tcp+8);
		memset(hbh,0,8);
		// extra HOPBYHOP header. standard violation
		if (fooling & FOOL_HOPBYHOP2)
		{
			hbh = (struct ip6_hbh*)tcp;
			tcp = (struct tcphdr*)((uint8_t*)tcp+8);
			memset(hbh,0,8);
		}
		hbh->ip6h_nxt = IPPROTO_TCP;
		nexttype = &hbh->ip6h_nxt;
		proto = IPPROTO_HOPOPTS;
	}
	if (fooling & FOOL_DESTOPT)
	{
		struct ip6_dest *dest = (struct ip6_dest*)tcp;
		tcp = (struct tcphdr*)((uint8_t*)tcp+8);
		memset(dest,0,8);
		dest->ip6d_nxt = IPPROTO_TCP;
		if (nexttype)
			*nexttype = IPPROTO_DSTOPTS;
		else
			proto = IPPROTO_DSTOPTS;
		nexttype = &dest->ip6d_nxt;
	}
	if (fooling & FOOL_IPFRAG1)
	{
		struct ip6_frag *frag = (struct ip6_frag*)tcp;
		tcp = (struct tcphdr*)((uint8_t*)tcp+sizeof(struct ip6_frag));
		frag->ip6f_nxt = IPPROTO_TCP;
		frag->ip6f_ident = htonl(1+random()%0xFFFFFFFF);
		frag->ip6f_reserved = 0;
		frag->ip6f_offlg = 0;
		if (nexttype)
			*nexttype = IPPROTO_FRAGMENT;
		else
			proto = IPPROTO_FRAGMENT;
	}

	uint8_t *payload = (uint8_t*)(tcp+1)+tcpoptlen;

	fill_ip6hdr(ip6, &src->sin6_addr, &dst->sin6_addr, ip_payload_len, proto, ttl, flow_label);
	fill_tcphdr(tcp,fooling,tcp_flags,sack,nmss,nseq,nack_seq,src->sin6_port,dst->sin6_port,nwsize,scale_factor,timestamps,ts_increment,badseq_increment,badseq_ack_increment,len);

	memcpy(payload,data,len);
	tcp6_fix_checksum(tcp,transport_payload_len,&ip6->ip6_src,&ip6->ip6_dst);
	if (fooling & FOOL_BADSUM) tcp->th_sum^=(1+random()%0xFFFF);

	*buflen = pktlen;
	return true;
}

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
	uint8_t *buf, size_t *buflen)
{
	return (src->sa_family==AF_INET && dst->sa_family==AF_INET) ?
		prepare_tcp_segment4((struct sockaddr_in *)src,(struct sockaddr_in *)dst,tcp_flags,sack,nmss,nseq,nack_seq,nwsize,scale_factor,timestamps,DF,ttl,tos,ip_id,fooling,ts_increment,badseq_increment,badseq_ack_increment,data,len,buf,buflen) :
		(src->sa_family==AF_INET6 && dst->sa_family==AF_INET6) ?
		prepare_tcp_segment6((struct sockaddr_in6 *)src,(struct sockaddr_in6 *)dst,tcp_flags,sack,nmss,nseq,nack_seq,nwsize,scale_factor,timestamps,ttl,flow_label,fooling,ts_increment,badseq_increment,badseq_ack_increment,data,len,buf,buflen) :
		false;
}


// padlen<0 means payload shrinking
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
	uint8_t *buf, size_t *buflen)
{
	if ((len+padlen)<=0) padlen=-(int)len+1; // do not allow payload to be less that 1 byte
	if ((len+padlen)>0xFFFF) padlen=0xFFFF-len; // do not allow payload size to exceed u16 range
	if (padlen<0)
	{
		len+=padlen;
		padlen=0;
	}
	uint16_t datalen = (uint16_t)(len + padlen);
	uint16_t ip_payload_len = sizeof(struct udphdr) + datalen;
	uint16_t pktlen = sizeof(struct ip) + ip_payload_len;
	if (pktlen>*buflen) return false;

	struct ip *ip = (struct ip*)buf;
	struct udphdr *udp = (struct udphdr*)(ip+1);
	uint8_t *payload = (uint8_t*)(udp+1);


	fill_iphdr(ip, &src->sin_addr, &dst->sin_addr, pktlen, IPPROTO_UDP, DF, ttl, tos, ip_id);
	fill_udphdr(udp, src->sin_port, dst->sin_port, datalen);

	memcpy(payload,data,len);
	if (padding)
		fill_pattern(payload+len,padlen,padding,padding_size,0);
	else
		memset(payload+len,0,padlen);
	udp4_fix_checksum(udp,ip_payload_len,&ip->ip_src,&ip->ip_dst);
	if (fooling & FOOL_BADSUM) udp->uh_sum^=(1+random()%0xFFFF);

	*buflen = pktlen;
	return true;
}
bool prepare_udp_segment6(
	const struct sockaddr_in6 *src, const struct sockaddr_in6 *dst,
	uint8_t ttl,
	uint32_t flow_label,
	uint32_t fooling,
	const uint8_t *padding, size_t padding_size,
	int padlen,
	const void *data, uint16_t len,
	uint8_t *buf, size_t *buflen)
{
	if ((len+padlen)<=0) padlen=-(int)len+1; // do not allow payload to be less that 1 byte
	if ((len+padlen)>0xFFFF) padlen=0xFFFF-len; // do not allow payload size to exceed u16 range
	if (padlen<0)
	{
		len+=padlen;
		padlen=0;
	}
	uint16_t datalen = (uint16_t)(len + padlen);
	uint16_t transport_payload_len = sizeof(struct udphdr) + datalen;
	uint16_t ip_payload_len = transport_payload_len +
		8*!!((fooling & (FOOL_HOPBYHOP|FOOL_HOPBYHOP2))==FOOL_HOPBYHOP) +
		16*!!(fooling & FOOL_HOPBYHOP2) +
		8*!!(fooling & FOOL_DESTOPT) +
		8*!!(fooling & FOOL_IPFRAG1);
	uint16_t pktlen = sizeof(struct ip6_hdr) + ip_payload_len;
	if (pktlen>*buflen) return false;

	struct ip6_hdr *ip6 = (struct ip6_hdr*)buf;
	struct udphdr *udp = (struct udphdr*)(ip6+1);
	uint8_t proto = IPPROTO_UDP, *nexttype = NULL;

	if (fooling & (FOOL_HOPBYHOP|FOOL_HOPBYHOP2))
	{
		struct ip6_hbh *hbh = (struct ip6_hbh*)udp;
		udp = (struct udphdr*)((uint8_t*)udp+8);
		memset(hbh,0,8);
		// extra HOPBYHOP header. standard violation
		if (fooling & FOOL_HOPBYHOP2)
		{
			hbh = (struct ip6_hbh*)udp;
			udp = (struct udphdr*)((uint8_t*)udp+8);
			memset(hbh,0,8);
		}
		hbh->ip6h_nxt = IPPROTO_UDP;
		nexttype = &hbh->ip6h_nxt;
		proto = IPPROTO_HOPOPTS;
	}
	if (fooling & FOOL_DESTOPT)
	{
		struct ip6_dest *dest = (struct ip6_dest*)udp;
		udp = (struct udphdr*)((uint8_t*)udp+8);
		memset(dest,0,8);
		dest->ip6d_nxt = IPPROTO_UDP;
		if (nexttype)
			*nexttype = IPPROTO_DSTOPTS;
		else
			proto = IPPROTO_DSTOPTS;
		nexttype = &dest->ip6d_nxt;
	}
	if (fooling & FOOL_IPFRAG1)
	{
		struct ip6_frag *frag = (struct ip6_frag*)udp;
		udp = (struct udphdr*)((uint8_t*)udp+sizeof(struct ip6_frag));
		frag->ip6f_nxt = IPPROTO_UDP;
		frag->ip6f_ident = htonl(1+random()%0xFFFFFFFF);
		frag->ip6f_reserved = 0;
		frag->ip6f_offlg = 0;
		if (nexttype)
			*nexttype = IPPROTO_FRAGMENT;
		else
			proto = IPPROTO_FRAGMENT;
	}

	uint8_t *payload = (uint8_t*)(udp+1);

	fill_ip6hdr(ip6, &src->sin6_addr, &dst->sin6_addr, ip_payload_len, proto, ttl, flow_label);
	fill_udphdr(udp, src->sin6_port, dst->sin6_port, datalen);

	memcpy(payload,data,len);
	if (padding)
		fill_pattern(payload+len,padlen,padding,padding_size,0);
	else
		memset(payload+len,0,padlen);
	udp6_fix_checksum(udp,transport_payload_len,&ip6->ip6_src,&ip6->ip6_dst);
	if (fooling & FOOL_BADSUM) udp->uh_sum^=(1+random()%0xFFFF);

	*buflen = pktlen;
	return true;
}
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
	uint8_t *buf, size_t *buflen)
{
	return (src->sa_family==AF_INET && dst->sa_family==AF_INET) ?
		prepare_udp_segment4((struct sockaddr_in *)src,(struct sockaddr_in *)dst,DF,ttl,tos,ip_id,fooling,padding,padding_size,padlen,data,len,buf,buflen) :
		(src->sa_family==AF_INET6 && dst->sa_family==AF_INET6) ?
		prepare_udp_segment6((struct sockaddr_in6 *)src,(struct sockaddr_in6 *)dst,ttl,flow_label,fooling,padding,padding_size,padlen,data,len,buf,buflen) :
		false;
}

bool ip6_insert_simple_hdr(uint8_t type, uint8_t *data_pkt, size_t len_pkt, uint8_t *buf, size_t *buflen)
{
	if ((len_pkt+8)<=*buflen && len_pkt>=sizeof(struct ip6_hdr))
	{
		struct ip6_hdr *ip6 = (struct ip6_hdr *)buf;
		struct ip6_ext *hdr = (struct ip6_ext*)(ip6+1);
		*ip6 = *(struct ip6_hdr*)data_pkt;
		memset(hdr,0,8);
		memcpy((uint8_t*)hdr+8, data_pkt+sizeof(struct ip6_hdr), len_pkt-sizeof(struct ip6_hdr));
		hdr->ip6e_nxt = ip6->ip6_ctlun.ip6_un1.ip6_un1_nxt;
		ip6->ip6_ctlun.ip6_un1.ip6_un1_nxt = type;
		ip6->ip6_ctlun.ip6_un1.ip6_un1_plen = net16_add(ip6->ip6_ctlun.ip6_un1.ip6_un1_plen, 8);
		*buflen = len_pkt + 8;
		return true;
	}
	return false;
}

// split ipv4 packet into 2 fragments at data payload position frag_pos
bool ip_frag4(
	const uint8_t *pkt, size_t pkt_size,
	size_t frag_pos, uint32_t ident,
	uint8_t *pkt1, size_t *pkt1_size,
	uint8_t *pkt2, size_t *pkt2_size)
{
	uint16_t hdrlen, payload_len;
	// frag_pos must be 8-byte aligned
	if (frag_pos & 7 || pkt_size < sizeof(struct ip)) return false;
	payload_len = htons(((struct ip *)pkt)->ip_len);
	hdrlen = ((struct ip *)pkt)->ip_hl<<2;
	if (payload_len>pkt_size || hdrlen>pkt_size || hdrlen>payload_len) return false;
	payload_len -= hdrlen;
	if (frag_pos>=payload_len || *pkt1_size<(hdrlen+frag_pos) || *pkt2_size<(hdrlen+payload_len-frag_pos)) return false;

	memcpy(pkt1, pkt, hdrlen+frag_pos);
	((struct ip*)pkt1)->ip_off = htons(IP_MF);
	((struct ip*)pkt1)->ip_len = htons(hdrlen+frag_pos);
	if (ident!=(uint32_t)-1) ((struct ip*)pkt1)->ip_id = (uint16_t)ident;
	*pkt1_size=hdrlen+frag_pos;
	ip4_fix_checksum((struct ip *)pkt1);

	memcpy(pkt2, pkt, hdrlen);
	memcpy(pkt2+hdrlen, pkt+hdrlen+frag_pos, payload_len-frag_pos);
	((struct ip*)pkt2)->ip_off = htons((uint16_t)frag_pos>>3 & IP_OFFMASK);
	((struct ip*)pkt2)->ip_len = htons(hdrlen+payload_len-frag_pos);
	if (ident!=(uint32_t)-1) ((struct ip*)pkt2)->ip_id = (uint16_t)ident;
	*pkt2_size=hdrlen+payload_len-frag_pos;
	ip4_fix_checksum((struct ip *)pkt2);

	return true;
}
bool ip_frag6(
	const uint8_t *pkt, size_t pkt_size,
	size_t frag_pos, uint32_t ident,
	uint8_t *pkt1, size_t *pkt1_size,
	uint8_t *pkt2, size_t *pkt2_size)
{
	size_t payload_len, unfragmentable;
	uint8_t *last_header_type;
	uint8_t proto;
	struct ip6_frag *frag;
	const uint8_t *payload;

	if (frag_pos & 7 || pkt_size < sizeof(struct ip6_hdr)) return false;
	payload_len = sizeof(struct ip6_hdr) + htons(((struct ip6_hdr*)pkt)->ip6_ctlun.ip6_un1.ip6_un1_plen);
	if (pkt_size < payload_len) return false;

	payload = pkt;
	proto_skip_ipv6((uint8_t**)&payload, &payload_len, &proto, &last_header_type);
	unfragmentable = payload - pkt;

	//printf("pkt_size=%zu FRAG_POS=%zu payload_len=%zu unfragmentable=%zu dh=%zu\n",pkt_size,frag_pos,payload_len,unfragmentable,last_header_type - pkt);

	if (frag_pos>=payload_len ||
		*pkt1_size<(unfragmentable + sizeof(struct ip6_frag) + frag_pos) ||
		*pkt2_size<(unfragmentable + sizeof(struct ip6_frag) + payload_len - frag_pos))
	{
		return false;
	}

	memcpy(pkt1, pkt, unfragmentable);
	((struct ip6_hdr*)pkt1)->ip6_ctlun.ip6_un1.ip6_un1_plen = htons(unfragmentable - sizeof(struct ip6_hdr) + sizeof(struct ip6_frag) + frag_pos);
	pkt1[last_header_type - pkt] = IPPROTO_FRAGMENT;
	frag = (struct ip6_frag*)(pkt1 + unfragmentable);
	frag->ip6f_nxt = proto;
	frag->ip6f_reserved = 0;
	frag->ip6f_offlg = IP6F_MORE_FRAG;
	frag->ip6f_ident = ident;
	memcpy(frag+1, pkt + unfragmentable, frag_pos);
	*pkt1_size = unfragmentable + sizeof(struct ip6_frag) + frag_pos;

	memcpy(pkt2, pkt, sizeof(struct ip6_hdr));
	((struct ip6_hdr*)pkt2)->ip6_ctlun.ip6_un1.ip6_un1_plen = htons(unfragmentable - sizeof(struct ip6_hdr) + sizeof(struct ip6_frag) + payload_len - frag_pos);
	pkt2[last_header_type - pkt] = IPPROTO_FRAGMENT;
	frag = (struct ip6_frag*)(pkt2 + unfragmentable);
	frag->ip6f_nxt = proto;
	frag->ip6f_reserved = 0;
	frag->ip6f_offlg = htons(frag_pos);
	frag->ip6f_ident = ident;
	memcpy(frag+1, pkt + unfragmentable + frag_pos, payload_len - frag_pos);
	*pkt2_size = unfragmentable + sizeof(struct ip6_frag) + payload_len - frag_pos;

	return true;
}
bool ip_frag(
	const uint8_t *pkt, size_t pkt_size,
	size_t frag_pos, uint32_t ident,
	uint8_t *pkt1, size_t *pkt1_size,
	uint8_t *pkt2, size_t *pkt2_size)
{
	if (proto_check_ipv4(pkt,pkt_size))
		return ip_frag4(pkt,pkt_size,frag_pos,ident,pkt1,pkt1_size,pkt2,pkt2_size);
	else if (proto_check_ipv6(pkt,pkt_size))
		return ip_frag6(pkt,pkt_size,frag_pos,ident,pkt1,pkt1_size,pkt2,pkt2_size);
	else
		return false;
}

bool rewrite_ttl(struct ip *ip, struct ip6_hdr *ip6, uint8_t ttl)
{
	if (ttl)
	{
		if (ip)
		{
			if (ip->ip_ttl!=ttl)
			{
				ip->ip_ttl = ttl;
				ip4_fix_checksum(ip);
				return true;
			}
		}
		else if (ip6)
		{
			if (ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim!=ttl)
			{
				ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim = ttl;
				return true;
			}
		}
	}
	return false;
}

void apply_tcp_flags(struct tcphdr *tcp, uint16_t fl)
{
	if (tcp)
	{
		tcp->th_flags = (uint8_t)fl;
		tcp->th_x2 = (fl>>8) & 0xF;
	}
}
uint16_t get_tcp_flags(const struct tcphdr *tcp)
{
	return tcp->th_flags | (tcp->th_x2<<8);
}



void extract_ports(const struct tcphdr *tcphdr, const struct udphdr *udphdr, uint8_t *proto, uint16_t *sport, uint16_t *dport)
{
	if (sport) *sport  = htons(tcphdr ? tcphdr->th_sport : udphdr ? udphdr->uh_sport : 0);
	if (dport) *dport  = htons(tcphdr ? tcphdr->th_dport : udphdr ? udphdr->uh_dport : 0);
	if (proto) *proto = tcphdr ? IPPROTO_TCP : udphdr ? IPPROTO_UDP : -1;
}

void extract_endpoints(const struct ip *ip,const struct ip6_hdr *ip6hdr,const struct tcphdr *tcphdr,const struct udphdr *udphdr, struct sockaddr_storage *src, struct sockaddr_storage *dst)
{
	if (ip)
	{
		struct sockaddr_in *si;

		if (dst)
		{
			si = (struct sockaddr_in*)dst;
			si->sin_family = AF_INET;
			si->sin_port = tcphdr ? tcphdr->th_dport : udphdr ? udphdr->uh_dport : 0;
			si->sin_addr = ip->ip_dst;
		}

		if (src)
		{
			si = (struct sockaddr_in*)src;
			si->sin_family = AF_INET;
			si->sin_port = tcphdr ? tcphdr->th_sport : udphdr ? udphdr->uh_sport : 0;
			si->sin_addr = ip->ip_src;
		}
	}
	else if (ip6hdr)
	{
		struct sockaddr_in6 *si;

		if (dst)
		{
			si = (struct sockaddr_in6*)dst;
			si->sin6_family = AF_INET6;
			si->sin6_port = tcphdr ? tcphdr->th_dport : udphdr ? udphdr->uh_dport : 0;
			si->sin6_addr = ip6hdr->ip6_dst;
			si->sin6_flowinfo = 0;
			si->sin6_scope_id = 0;
		}

		if (src)
		{
			si = (struct sockaddr_in6*)src;
			si->sin6_family = AF_INET6;
			si->sin6_port = tcphdr ? tcphdr->th_sport : udphdr ? udphdr->uh_sport : 0;
			si->sin6_addr = ip6hdr->ip6_src;
			si->sin6_flowinfo = 0;
			si->sin6_scope_id = 0;
		}
	}
}

const char *proto_name(uint8_t proto)
{
	switch(proto)
	{
		case IPPROTO_TCP:
			return "tcp";
		case IPPROTO_UDP:
			return "udp";
		case IPPROTO_ICMP:
			return "icmp";
		case IPPROTO_ICMPV6:
			return "icmp6";
		case IPPROTO_IGMP:
			return "igmp";
		case IPPROTO_ESP:
			return "esp";
		case IPPROTO_AH:
			return "ah";
		case IPPROTO_IPV6:
			return "6in4";
		case IPPROTO_IPIP:
			return "4in4";
#ifdef IPPROTO_GRE
		case IPPROTO_GRE:
			return "gre";
#endif
#ifdef IPPROTO_SCTP
		case IPPROTO_SCTP:
			return "sctp";
#endif
		default:
			return NULL;
	}
}
static void str_proto_name(char *s, size_t s_len, uint8_t proto)
{
	const char *name = proto_name(proto);
	if (name)
		snprintf(s,s_len,"%s",name);
	else
		snprintf(s,s_len,"%u",proto);
}
uint16_t family_from_proto(uint8_t l3proto)
{
	switch(l3proto)
	{
		case IPPROTO_IP: return AF_INET;
		case IPPROTO_IPV6: return AF_INET6;
		default: return -1;
	}
}

static void str_srcdst_ip(char *s, size_t s_len, const void *saddr,const void *daddr)
{
	char s_ip[16],d_ip[16];
	*s_ip=*d_ip=0;
	inet_ntop(AF_INET, saddr, s_ip, sizeof(s_ip));
	inet_ntop(AF_INET, daddr, d_ip, sizeof(d_ip));
	snprintf(s,s_len,"%s => %s",s_ip,d_ip);
}
void str_ip(char *s, size_t s_len, const struct ip *ip)
{
	char ss[35],s_proto[16];
	str_srcdst_ip(ss,sizeof(ss),&ip->ip_src,&ip->ip_dst);
	str_proto_name(s_proto,sizeof(s_proto),ip->ip_p);
	snprintf(s,s_len,"%s proto=%s ttl=%u",ss,s_proto,ip->ip_ttl);
}
void print_ip(const struct ip *ip)
{
	char s[66];
	str_ip(s,sizeof(s),ip);
	printf("%s",s);
}
void str_srcdst_ip6(char *s, size_t s_len, const void *saddr,const void *daddr)
{
	char s_ip[40],d_ip[40];
	*s_ip=*d_ip=0;
	inet_ntop(AF_INET6, saddr, s_ip, sizeof(s_ip));
	inet_ntop(AF_INET6, daddr, d_ip, sizeof(d_ip));
	snprintf(s,s_len,"%s => %s",s_ip,d_ip);
}
void str_ip6hdr(char *s, size_t s_len, const struct ip6_hdr *ip6hdr, uint8_t proto)
{
	char ss[83],s_proto[16];
	str_srcdst_ip6(ss,sizeof(ss),&ip6hdr->ip6_src,&ip6hdr->ip6_dst);
	str_proto_name(s_proto,sizeof(s_proto),proto);
	snprintf(s,s_len,"%s proto=%s ttl=%u",ss,s_proto,ip6hdr->ip6_hlim);
}
void print_ip6hdr(const struct ip6_hdr *ip6hdr, uint8_t proto)
{
	char s[128];
	str_ip6hdr(s,sizeof(s),ip6hdr,proto);
	printf("%s",s);
}
void str_tcphdr(char *s, size_t s_len, const struct tcphdr *tcphdr)
{
	char flags[7],*f=flags;
	if (tcphdr->th_flags & TH_SYN) *f++='S';
	if (tcphdr->th_flags & TH_ACK) *f++='A';
	if (tcphdr->th_flags & TH_RST) *f++='R';
	if (tcphdr->th_flags & TH_FIN) *f++='F';
	if (tcphdr->th_flags & TH_PUSH) *f++='P';
	if (tcphdr->th_flags & TH_URG) *f++='U';
	*f=0;
	snprintf(s,s_len,"sport=%u dport=%u flags=%s seq=%u ack_seq=%u",htons(tcphdr->th_sport),htons(tcphdr->th_dport),flags,htonl(tcphdr->th_seq),htonl(tcphdr->th_ack));
}
void print_tcphdr(const struct tcphdr *tcphdr)
{
	char s[80];
	str_tcphdr(s,sizeof(s),tcphdr);
	printf("%s",s);
}
void str_udphdr(char *s, size_t s_len, const struct udphdr *udphdr)
{
	snprintf(s,s_len,"sport=%u dport=%u",htons(udphdr->uh_sport),htons(udphdr->uh_dport));
}
void print_udphdr(const struct udphdr *udphdr)
{
	char s[30];
	str_udphdr(s,sizeof(s),udphdr);
	printf("%s",s);
}




bool proto_check_ipv4(const uint8_t *data, size_t len)
{
	return 	len >= 20 && (data[0] & 0xF0) == 0x40 &&
		len >= ((data[0] & 0x0F) << 2);
}
// move to transport protocol
void proto_skip_ipv4(uint8_t **data, size_t *len)
{
	size_t l;

	l = (**data & 0x0F) << 2;
	*data += l;
	*len -= l;
}
bool proto_check_tcp(const uint8_t *data, size_t len)
{
	return len >= 20 && len >= ((data[12] & 0xF0) >> 2);
}
void proto_skip_tcp(uint8_t **data, size_t *len)
{
	size_t l;
	l = ((*data)[12] & 0xF0) >> 2;
	*data += l;
	*len -= l;
}
bool proto_check_udp(const uint8_t *data, size_t len)
{
	return len >= 8 && len>=(data[4]<<8 | data[5]);
}
void proto_skip_udp(uint8_t **data, size_t *len)
{
	*data += 8;
	*len -= 8;
}

bool proto_check_ipv6(const uint8_t *data, size_t len)
{
	return 	len >= 40 && (data[0] & 0xF0) == 0x60 &&
		(len - 40) >= htons(*(uint16_t*)(data + 4)); // payload length
}
// move to transport protocol
// proto_type = 0 => error
void proto_skip_ipv6(uint8_t **data, size_t *len, uint8_t *proto_type, uint8_t **last_header_type)
{
	size_t hdrlen;
	uint8_t HeaderType;

	if (proto_type) *proto_type = 0; // put error in advance

	HeaderType = (*data)[6]; // NextHeader field
	if (proto_type) *proto_type = HeaderType;
	if (last_header_type) *last_header_type = (*data)+6;
	*data += 40; *len -= 40; // skip ipv6 base header
	while (*len > 0) // need at least one byte for NextHeader field
	{
		switch (HeaderType)
		{
		case 0: // Hop-by-Hop Options
		case 43: // routing
		case 60: // Destination Options
		case 135: // mobility
		case 139: // Host Identity Protocol Version v2
		case 140: // Shim6
			if (*len < 2) return; // error
			hdrlen = 8 + ((*data)[1] << 3);
			break;
		case 44: // fragment. length fixed to 8, hdrlen field defined as reserved
			hdrlen = 8;
			break;
		case 51: // authentication
			// special case. length in ah header is in 32-bit words minus 2
			if (*len < 2) return; // error
			hdrlen = 8 + ((*data)[1] << 2);
			break;
		case 59: // no next header
			return; // error
		default:
			// we found some meaningful payload. it can be tcp, udp, icmp or some another exotic shit
			if (proto_type) *proto_type = HeaderType;
			return;
		}
		if (*len < hdrlen) return; // error
		HeaderType = **data;
		if (last_header_type) *last_header_type = *data;
		// advance to the next header location
		*len -= hdrlen;
		*data += hdrlen;
	}
	// we have garbage
}

void proto_dissect_l3l4(uint8_t *data, size_t len,struct dissect *dis)
{
	memset(dis,0,sizeof(*dis));

	dis->data_pkt = data;
	dis->len_pkt = len;

	if (proto_check_ipv4(data, len))
	{
		dis->ip = (struct ip *) data;
		dis->proto = dis->ip->ip_p;
		proto_skip_ipv4(&data, &len);
	}
	else if (proto_check_ipv6(data, len))
	{
		dis->ip6 = (struct ip6_hdr *) data;
		proto_skip_ipv6(&data, &len, &dis->proto, NULL);
	}
	else
	{
		return;
	}

	if (dis->proto==IPPROTO_TCP && proto_check_tcp(data, len))
	{
		dis->tcp = (struct tcphdr *) data;
		dis->transport_len = len;

		proto_skip_tcp(&data, &len);

		dis->data_payload = data;
		dis->len_payload = len;

	}
	else if (dis->proto==IPPROTO_UDP && proto_check_udp(data, len))
	{
		dis->udp = (struct udphdr *) data;
		dis->transport_len = len;

		proto_skip_udp(&data, &len);

		dis->data_payload = data;
		dis->len_payload = len;
	}
}


bool tcp_synack_segment(const struct tcphdr *tcphdr)
{
	/* check for set bits in TCP hdr */
	return ((tcphdr->th_flags & (TH_URG|TH_ACK|TH_PUSH|TH_RST|TH_SYN|TH_FIN)) == (TH_ACK|TH_SYN));
}
bool tcp_syn_segment(const struct tcphdr *tcphdr)
{
	/* check for set bits in TCP hdr */
	return ((tcphdr->th_flags & (TH_URG|TH_ACK|TH_PUSH|TH_RST|TH_SYN|TH_FIN)) == TH_SYN);
}
bool tcp_ack_segment(const struct tcphdr *tcphdr)
{
	/* check for set bits in TCP hdr */
	return ((tcphdr->th_flags & (TH_URG|TH_ACK|TH_PUSH|TH_RST|TH_SYN|TH_FIN)) == TH_ACK);
}

void tcp_rewrite_wscale(struct tcphdr *tcp, uint8_t scale_factor)
{
	uint8_t *scale,scale_factor_old;

	if (scale_factor!=SCALE_NONE)
	{
		scale = tcp_find_option(tcp,3); // tcp option 3 - scale factor
		if (scale && scale[1]==3) // length should be 3
		{
			scale_factor_old=scale[2];
			// do not allow increasing scale factor
			if (scale_factor>=scale_factor_old)
				DLOG("Scale factor %u unchanged\n", scale_factor_old);
			else
			{
				scale[2]=scale_factor;
				DLOG("Scale factor change %u => %u\n", scale_factor_old, scale_factor);
			}
		}
	}
}
// scale_factor=SCALE_NONE - do not change
void tcp_rewrite_winsize(struct tcphdr *tcp, uint16_t winsize, uint8_t scale_factor)
{
	uint16_t winsize_old;

	winsize_old = htons(tcp->th_win); // << scale_factor;
	tcp->th_win = htons(winsize);
	DLOG("Window size change %u => %u\n", winsize_old, winsize);

	tcp_rewrite_wscale(tcp, scale_factor);
}


#ifdef __CYGWIN__

static HANDLE w_filter = NULL;
static OVERLAPPED ovl = { .hEvent = NULL };
static const struct str_list_head *wlan_filter_ssid = NULL, *nlm_filter_net = NULL;
static DWORD logical_net_filter_tick=0;
uint32_t w_win32_error=0;
INetworkListManager* pNetworkListManager=NULL;

static void guid2str(const GUID *guid, char *str)
{
	snprintf(str,37, "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X", guid->Data1, guid->Data2, guid->Data3, guid->Data4[0], guid->Data4[1], guid->Data4[2], guid->Data4[3], guid->Data4[4], guid->Data4[5], guid->Data4[6], guid->Data4[7]);
}
static bool str2guid(const char* str, GUID *guid)
{
	unsigned int u[11],k;

	if (36 != strlen(str) || 11 != sscanf(str, "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X", u+0, u+1, u+2, u+3, u+4, u+5, u+6, u+7, u+8, u+9, u+10))
		return false;
	guid->Data1 = u[0];
	if ((u[1] & 0xFFFF0000) || (u[2] & 0xFFFF0000)) return false;
	guid->Data2 = (USHORT)u[1];
	guid->Data3 = (USHORT)u[2];
	for (k = 0; k < 8; k++)
	{
		if (u[k+3] & 0xFFFFFF00) return false;
		guid->Data4[k] = (UCHAR)u[k+3];
	}
	return true;
}

static const char *sNetworkCards="SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\NetworkCards";
// get adapter name from guid string
static bool AdapterID2Name(const GUID *guid,char *name,DWORD name_len)
{
	char sguid[39],sidx[32],val[256];
	HKEY hkNetworkCards,hkCard;
	DWORD dwIndex,dwLen;
	bool bRet = false;
	WCHAR namew[128];
	DWORD namew_len;

	if (name_len<2) return false;

	if ((w_win32_error = RegOpenKeyExA(HKEY_LOCAL_MACHINE,sNetworkCards,0,KEY_ENUMERATE_SUB_KEYS,&hkNetworkCards)) == ERROR_SUCCESS)
	{
		guid2str(guid, sguid+1);
		sguid[0]='{';
		sguid[37]='}';
		sguid[38]='\0';

		for (dwIndex=0;;dwIndex++)
		{
			dwLen=sizeof(sidx)-1;
			w_win32_error = RegEnumKeyExA(hkNetworkCards,dwIndex,sidx,&dwLen,NULL,NULL,NULL,NULL);
			if (w_win32_error == ERROR_SUCCESS)
			{
				sidx[dwLen]='\0';

				if ((w_win32_error = RegOpenKeyExA(hkNetworkCards,sidx,0,KEY_QUERY_VALUE,&hkCard)) == ERROR_SUCCESS)
				{
					dwLen=sizeof(val)-1;
					if ((w_win32_error = RegQueryValueExA(hkCard,"ServiceName",NULL,NULL,val,&dwLen)) == ERROR_SUCCESS)
					{
						val[dwLen]='\0';
						if (!strcmp(val,sguid))
						{
							namew_len = sizeof(namew)-sizeof(WCHAR);
							if ((w_win32_error = RegQueryValueExW(hkCard,L"Description",NULL,NULL,(LPBYTE)namew,&namew_len)) == ERROR_SUCCESS)
							{
								namew[namew_len/sizeof(WCHAR)]=L'\0';
								if (WideCharToMultiByte(CP_UTF8, 0, namew, -1, name, name_len, NULL, NULL))
									bRet = true;
							}
						}
					}
					RegCloseKey(hkCard);
				}
				if (bRet) break;
			}
			else
				break;
		}
		RegCloseKey(hkNetworkCards);
	}

	return bRet;
}

bool win_dark_init(const struct str_list_head *ssid_filter, const struct str_list_head *nlm_filter)
{
	win_dark_deinit();
	if (LIST_EMPTY(ssid_filter)) ssid_filter=NULL;
	if (LIST_EMPTY(nlm_filter)) nlm_filter=NULL;
	if (nlm_filter)
	{
		if (SUCCEEDED(w_win32_error = CoInitialize(NULL)))
		{
			if (FAILED(w_win32_error = CoCreateInstance(&CLSID_NetworkListManager, NULL, CLSCTX_ALL, &IID_INetworkListManager, (LPVOID*)&pNetworkListManager)))
			{
				CoUninitialize();
				return false;
			}
		}
		else
			return false;
	}
	nlm_filter_net = nlm_filter;
	wlan_filter_ssid = ssid_filter;
	return true;
}
bool win_dark_deinit(void)
{
	if (pNetworkListManager)
	{
		pNetworkListManager->lpVtbl->Release(pNetworkListManager);
		pNetworkListManager = NULL;
	}
	if (nlm_filter_net) CoUninitialize();
	wlan_filter_ssid = nlm_filter_net = NULL;
}


bool nlm_list(bool bAll)
{
	bool bRet = true;

	if (SUCCEEDED(w_win32_error = CoInitialize(NULL)))
	{
		INetworkListManager* pNetworkListManager;
		if (SUCCEEDED(w_win32_error = CoCreateInstance(&CLSID_NetworkListManager, NULL, CLSCTX_ALL, &IID_INetworkListManager, (LPVOID*)&pNetworkListManager)))
		{
			IEnumNetworks* pEnumNetworks;
			if (SUCCEEDED(w_win32_error = pNetworkListManager->lpVtbl->GetNetworks(pNetworkListManager, NLM_ENUM_NETWORK_ALL, &pEnumNetworks)))
			{
				INetwork *pNet;
				INetworkConnection *pConn;
				IEnumNetworkConnections *pEnumConnections;
				VARIANT_BOOL bIsConnected, bIsConnectedInet;
				NLM_NETWORK_CATEGORY category;
				GUID idNet, idAdapter;
				BSTR bstrName;
				char Name[128],Name2[128];
				int connected;
				for (connected = 1; connected >= !bAll; connected--)
				{
					for (;;)
					{
						if (FAILED(w_win32_error = pEnumNetworks->lpVtbl->Next(pEnumNetworks, 1, &pNet, NULL)))
						{
							bRet = false;
							break;
						}
						if (w_win32_error != S_OK) break;
						if (SUCCEEDED(w_win32_error = pNet->lpVtbl->get_IsConnected(pNet, &bIsConnected)) &&
							SUCCEEDED(w_win32_error = pNet->lpVtbl->get_IsConnectedToInternet(pNet, &bIsConnectedInet)) &&
							SUCCEEDED(w_win32_error = pNet->lpVtbl->GetNetworkId(pNet, &idNet)) &&
							SUCCEEDED(w_win32_error = pNet->lpVtbl->GetCategory(pNet, &category)) &&
							SUCCEEDED(w_win32_error = pNet->lpVtbl->GetName(pNet, &bstrName)))
						{
							if (!!bIsConnected == connected)
							{
								if (WideCharToMultiByte(CP_UTF8, 0, bstrName, -1, Name, sizeof(Name), NULL, NULL))
								{
									printf("Name    : %s", Name);
									if (bIsConnected) printf(" (connected)");
									if (bIsConnectedInet) printf(" (inet)");
									printf(" (%s)\n",
										category==NLM_NETWORK_CATEGORY_PUBLIC ? "public" :
										category==NLM_NETWORK_CATEGORY_PRIVATE ? "private" :
										category==NLM_NETWORK_CATEGORY_DOMAIN_AUTHENTICATED ? "domain" :
										"unknown");
									guid2str(&idNet, Name);
									printf("NetID   : %s\n", Name);
									if (connected && SUCCEEDED(w_win32_error = pNet->lpVtbl->GetNetworkConnections(pNet, &pEnumConnections)))
									{
										while ((w_win32_error = pEnumConnections->lpVtbl->Next(pEnumConnections, 1, &pConn, NULL))==S_OK)
										{
											if (SUCCEEDED(w_win32_error = pConn->lpVtbl->GetAdapterId(pConn,&idAdapter)))
											{
												guid2str(&idAdapter, Name);
												if (AdapterID2Name(&idAdapter,Name2,sizeof(Name2)))
													printf("Adapter : %s (%s)\n", Name2, Name);
												else
													printf("Adapter : %s\n", Name);
											}
											pConn->lpVtbl->Release(pConn);
										}
										pEnumConnections->lpVtbl->Release(pEnumConnections);
									}
									printf("\n");
								}
								else
								{
									w_win32_error = HRESULT_FROM_WIN32(GetLastError());
									bRet = false;
								}
							}
							SysFreeString(bstrName);
						}
						else
							bRet = false;
						pNet->lpVtbl->Release(pNet);
						if (!bRet) break;
					}
					if (!bRet) break;
					pEnumNetworks->lpVtbl->Reset(pEnumNetworks);
				}
				pEnumNetworks->lpVtbl->Release(pEnumNetworks);
			}
			else
				bRet = false;
			pNetworkListManager->lpVtbl->Release(pNetworkListManager);
		}
		else
			bRet = false;
	}
	else
		bRet = false;

	CoUninitialize();
	return bRet;
}

static bool nlm_filter_match(const struct str_list_head *nlm_list)
{
	// no filter given. always matches.
	if (!nlm_list || LIST_EMPTY(nlm_list))
	{
		w_win32_error = 0;
		return true;
	}

	bool bRet = true, bMatch = false;
	IEnumNetworks* pEnum;

	if (SUCCEEDED(w_win32_error = pNetworkListManager->lpVtbl->GetNetworks(pNetworkListManager, NLM_ENUM_NETWORK_CONNECTED, &pEnum)))
	{
		INetwork* pNet;
		GUID idNet,g;
		BSTR bstrName;
		char Name[128];
		struct str_list *nlm;
		for (;;)
		{
			if (FAILED(w_win32_error = pEnum->lpVtbl->Next(pEnum, 1, &pNet, NULL)))
			{
				bRet = false;
				break;
			}
			if (w_win32_error != S_OK) break;
			if (SUCCEEDED(w_win32_error = pNet->lpVtbl->GetNetworkId(pNet, &idNet)) &&
				SUCCEEDED(w_win32_error = pNet->lpVtbl->GetName(pNet, &bstrName)))
			{
				if (WideCharToMultiByte(CP_UTF8, 0, bstrName, -1, Name, sizeof(Name), NULL, NULL))
				{
					LIST_FOREACH(nlm, nlm_list, next)
					{
						bMatch = !strcmp(Name,nlm->str) || str2guid(nlm->str,&g) && !memcmp(&idNet,&g,sizeof(GUID));
						if (bMatch) break;
					}
				}
				else
				{
					w_win32_error = HRESULT_FROM_WIN32(GetLastError());
					bRet = false;
				}
				SysFreeString(bstrName);
			}
			else
				bRet = false;
			pNet->lpVtbl->Release(pNet);
			if (!bRet || bMatch) break;
		}
		pEnum->lpVtbl->Release(pEnum);
	}
	else
		bRet = false;
	return bRet && bMatch;
}

static bool wlan_filter_match(const struct str_list_head *ssid_list)
{
	DWORD dwCurVersion;
	HANDLE hClient = NULL;
	PWLAN_INTERFACE_INFO_LIST pIfList = NULL;
	PWLAN_INTERFACE_INFO pIfInfo;
	PWLAN_CONNECTION_ATTRIBUTES pConnectInfo;
	DWORD connectInfoSize, k;
	bool bRes;
	struct str_list *ssid;
	size_t len;

	// no filter given. always matches.
	if (!ssid_list || LIST_EMPTY(ssid_list))
	{
		w_win32_error = 0;
		return true;
	}

	w_win32_error = WlanOpenHandle(2, NULL, &dwCurVersion, &hClient);
	if (w_win32_error != ERROR_SUCCESS) goto fail;
	w_win32_error = WlanEnumInterfaces(hClient, NULL, &pIfList);
	if (w_win32_error != ERROR_SUCCESS) goto fail;
	for (k = 0; k < pIfList->dwNumberOfItems; k++)
	{
		pIfInfo = pIfList->InterfaceInfo + k;
		if (pIfInfo->isState == wlan_interface_state_connected)
		{
			w_win32_error = WlanQueryInterface(hClient,
				&pIfInfo->InterfaceGuid,
				wlan_intf_opcode_current_connection,
				NULL,
				&connectInfoSize,
				(PVOID *)&pConnectInfo,
				NULL);
			if (w_win32_error != ERROR_SUCCESS) goto fail;

//			printf("%s\n", pConnectInfo->wlanAssociationAttributes.dot11Ssid.ucSSID);

			LIST_FOREACH(ssid, ssid_list, next)
			{
				len = strlen(ssid->str);
				if (len==pConnectInfo->wlanAssociationAttributes.dot11Ssid.uSSIDLength && !memcmp(ssid->str,pConnectInfo->wlanAssociationAttributes.dot11Ssid.ucSSID,len))
				{
					WlanFreeMemory(pConnectInfo);
					goto found;
				}
			}

			WlanFreeMemory(pConnectInfo);
		}
	}
	w_win32_error = 0;
fail:
	bRes = false;
ex:
	if (pIfList) WlanFreeMemory(pIfList);
	if (hClient) WlanCloseHandle(hClient, 0);
	return bRes;
found:
	w_win32_error = 0;
	bRes = true;
	goto ex;
}

bool logical_net_filter_match(void)
{
	return wlan_filter_match(wlan_filter_ssid) && nlm_filter_match(nlm_filter_net);
}

static bool logical_net_filter_match_rate_limited(void)
{
	DWORD dwTick = GetTickCount() / 1000;
	if (logical_net_filter_tick == dwTick) return true;
	logical_net_filter_tick = dwTick;
	return logical_net_filter_match();
}

static HANDLE windivert_init_filter(const char *filter, UINT64 flags)
{
	LPSTR errormessage = NULL;
	HANDLE h, hMutex;
	const char *mutex_name = "Global\\winws_windivert_mutex";

	// windivert driver start in windivert.dll has race conditions
	hMutex = CreateMutexA(NULL,TRUE,mutex_name);
	if (hMutex && GetLastError()==ERROR_ALREADY_EXISTS)
		WaitForSingleObject(hMutex,INFINITE);
	h = WinDivertOpen(filter, WINDIVERT_LAYER_NETWORK, 0, flags);
	w_win32_error = GetLastError();

	if (hMutex)
	{
		ReleaseMutex(hMutex);
		CloseHandle(hMutex);
		SetLastError(w_win32_error);
	}

	if (h != INVALID_HANDLE_VALUE) return h;

	FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL, w_win32_error, MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT), (LPSTR)&errormessage, 0, NULL);
	DLOG_ERR("windivert: error opening filter: %s", errormessage);
	LocalFree(errormessage);
	if (w_win32_error == ERROR_INVALID_IMAGE_HASH)
		DLOG_ERR("windivert: try to disable secure boot and install OS patches\n");

	return NULL;
}
void rawsend_cleanup(void)
{
	if (w_filter)
	{
		CancelIoEx(w_filter,&ovl);
		WinDivertClose(w_filter);
		w_filter=NULL;
	}
	if (ovl.hEvent)
	{
		CloseHandle(ovl.hEvent);
		ovl.hEvent=NULL;
	}
}
bool windivert_init(const char *filter)
{
	rawsend_cleanup();
	w_filter = windivert_init_filter(filter, 0);
	if (w_filter)
	{
		ovl.hEvent = CreateEventW(NULL,FALSE,FALSE,NULL);
		if (!ovl.hEvent)
		{
			w_win32_error = GetLastError();
			rawsend_cleanup();
			return false;
		}
		return true;
	}
	return false;
}

static bool windivert_recv_filter(HANDLE hFilter, uint8_t *packet, size_t *len, WINDIVERT_ADDRESS *wa)
{
	UINT recv_len;
	DWORD err;
	DWORD rd;
	char c;

	if (bQuit)
	{
		errno=EINTR;
		return false;
	}
	if (!logical_net_filter_match_rate_limited())
	{
		errno=ENODEV;
		return false;
	}
	usleep(0);
	if (WinDivertRecvEx(hFilter, packet, *len, &recv_len, 0, wa, NULL, &ovl))
	{
		*len = recv_len;
		return true;
	}
	for(;;)
	{
		w_win32_error = GetLastError();
		switch(w_win32_error)
		{
			case ERROR_IO_PENDING:
				// make signals working
				while (WaitForSingleObject(ovl.hEvent,50)==WAIT_TIMEOUT)
				{
					if (bQuit)
					{
						errno=EINTR;
						return false;
					}
					if (!logical_net_filter_match_rate_limited())
					{
						errno=ENODEV;
						return false;
					}
					usleep(0);
				}
				if (!GetOverlappedResult(hFilter,&ovl,&rd,TRUE))
					continue;
				*len = rd;
				return true;
			case ERROR_INSUFFICIENT_BUFFER:
				errno = ENOBUFS;
				break;
			case ERROR_NO_DATA:
				errno = ESHUTDOWN;
				break;
			default:
				errno = EIO;
		}
		break;
	}
	return false;
}
bool windivert_recv(uint8_t *packet, size_t *len, WINDIVERT_ADDRESS *wa)
{
	return windivert_recv_filter(w_filter,packet,len,wa);
}

static bool windivert_send_filter(HANDLE hFilter, const uint8_t *packet, size_t len, const WINDIVERT_ADDRESS *wa)
{
	bool b = WinDivertSend(hFilter,packet,(UINT)len,NULL,wa);
	w_win32_error = GetLastError();
	return b;
}
bool windivert_send(const uint8_t *packet, size_t len, const WINDIVERT_ADDRESS *wa)
{
	return windivert_send_filter(w_filter,packet,len,wa);
}

bool rawsend(const struct sockaddr* dst,uint32_t fwmark,const char *ifout,const void *data,size_t len)
{
	WINDIVERT_ADDRESS wa;

	memset(&wa,0,sizeof(wa));
	// pseudo interface id IfIdx.SubIfIdx
	if (sscanf(ifout,"%u.%u",&wa.Network.IfIdx,&wa.Network.SubIfIdx)!=2)
	{
		errno = EINVAL;
		return false;
	}
	wa.Outbound=1;
	wa.IPChecksum=1;
	wa.TCPChecksum=1;
	wa.UDPChecksum=1;
	wa.IPv6 = (dst->sa_family==AF_INET6);

	return windivert_send(data,len,&wa);
}

#else // *nix

static int rawsend_sock4=-1, rawsend_sock6=-1;
static bool b_bind_fix4=false, b_bind_fix6=false;
static void rawsend_clean_sock(int *sock)
{
	if (sock && *sock!=-1)
	{
		close(*sock);
		*sock=-1;
	}
}
void rawsend_cleanup(void)
{
#ifdef __APPLE__
	macsend_cleanup();
#else
	rawsend_clean_sock(&rawsend_sock4);
	rawsend_clean_sock(&rawsend_sock6);
#endif
}
static int *rawsend_family_sock(sa_family_t family)
{
	switch(family)
	{
		case AF_INET: return &rawsend_sock4;
		case AF_INET6: return &rawsend_sock6;
		default: return NULL;
	}
}

#ifdef BSD
int socket_divert(sa_family_t family)
{
	int fd;

#ifdef __FreeBSD__
	// freebsd14+ way
	// don't want to use ifdefs with os version to make binaries compatible with all versions
	fd = socket(PF_DIVERT, SOCK_RAW, 0);
	if (fd==-1 && (errno==EPROTONOSUPPORT || errno==EAFNOSUPPORT || errno==EPFNOSUPPORT))
#endif
		// freebsd13- or openbsd way
		fd = socket(family, SOCK_RAW, IPPROTO_DIVERT);
	return fd;
}
static int rawsend_socket_divert(sa_family_t family)
{
	// HACK HACK HACK HACK HACK HACK HACK HACK
	// FreeBSD doesnt allow IP_HDRINCL for IPV6
	// OpenBSD doesnt allow rawsending tcp frames
	// we either have to go to the link layer (its hard, possible problems arise, compat testing, ...) or use some HACKING
	// from my point of view disabling direct ability to send ip frames is not security. its SHIT

	int fd = socket_divert(family);
	if (fd!=-1 && !set_socket_buffers(fd,4096,RAW_SNDBUF))
	{
		close(fd);
		return -1;
	}
	return fd;
}
static int rawsend_sendto_divert(sa_family_t family, int sock, const void *buf, size_t len)
{
	struct sockaddr_storage sa;
	socklen_t slen;

#ifdef __FreeBSD__
	// since FreeBSD 14 it requires hardcoded ipv4 values, although can also send ipv6 frames
	family = AF_INET;
	slen = sizeof(struct sockaddr_in);
#else
	// OpenBSD requires correct family and size
	switch(family)
	{
		case AF_INET:
			slen = sizeof(struct sockaddr_in);
			break;
		case AF_INET6:
			slen = sizeof(struct sockaddr_in6);
			break;
		default:
			return -1;
	}
#endif
	memset(&sa,0,slen);
	sa.ss_family = family;
	return sendto(sock, buf, len, 0, (struct sockaddr*)&sa, slen);
}
#endif

static int rawsend_socket_raw(int domain, int proto)
{
	int fd = socket(domain, SOCK_RAW, proto);
	if (fd!=-1)
	{
		#ifdef __linux__
		int s=RAW_SNDBUF/2;
		int r=2048;
		#else
		int s=RAW_SNDBUF;
		int r=4096;
		#endif
		if (!set_socket_buffers(fd,r,s))
		{
			close(fd);
			return -1;
		}
	}
	return fd;
}

static bool set_socket_fwmark(int sock, uint32_t fwmark)
{
#ifdef BSD
#ifdef SO_USER_COOKIE
	if (setsockopt(sock, SOL_SOCKET, SO_USER_COOKIE, &fwmark, sizeof(fwmark)) == -1)
	{
		DLOG_PERROR("rawsend: setsockopt(SO_USER_COOKIE)");
		return false;
	}
#endif
#elif defined(__linux__)
	if (setsockopt(sock, SOL_SOCKET, SO_MARK, &fwmark, sizeof(fwmark)) == -1)
	{
		DLOG_PERROR("rawsend: setsockopt(SO_MARK)");
		return false;
	}

#endif
	return true;
}

static int rawsend_socket(sa_family_t family)
{
	int *sock = rawsend_family_sock(family);
	if (!sock) return -1;

	if (*sock==-1)
	{
		int yes=1,pri=6;
		//printf("rawsend_socket: family %d",family);

#ifdef __FreeBSD__
		// IPPROTO_RAW with ipv6 in FreeBSD always returns EACCES on sendto.
		// must use IPPROTO_TCP for ipv6. IPPROTO_RAW works for ipv4
		// divert sockets are always v4 but accept both v4 and v6
		*sock = rawsend_socket_divert(AF_INET);
#elif defined(__OpenBSD__) || defined (__APPLE__)
		// OpenBSD does not allow sending TCP frames through raw sockets
		// I dont know about macos. They have dropped ipfw in recent versions and their PF does not support divert-packet
		*sock = rawsend_socket_divert(family);
#else
		*sock = rawsend_socket_raw(family, IPPROTO_RAW);
#endif
		if (*sock==-1)
		{
			DLOG_PERROR("rawsend: socket()");
			return -1;
		}
#ifdef __linux__
		if (setsockopt(*sock, SOL_SOCKET, SO_PRIORITY, &pri, sizeof(pri)) == -1)
		{
			DLOG_PERROR("rawsend: setsockopt(SO_PRIORITY)");
			goto exiterr;
		}
		if (family==AF_INET && setsockopt(*sock, IPPROTO_IP, IP_NODEFRAG, &yes, sizeof(yes)) == -1)
		{
			DLOG_PERROR("rawsend: setsockopt(IP_NODEFRAG)");
			goto exiterr;
		}
		if (family==AF_INET && setsockopt(*sock, IPPROTO_IP, IP_FREEBIND, &yes, sizeof(yes)) == -1)
		{
			DLOG_PERROR("rawsend: setsockopt(IP_FREEBIND)");
			goto exiterr;
		}
		if (family==AF_INET6 && setsockopt(*sock, SOL_IPV6, IPV6_FREEBIND, &yes, sizeof(yes)) == -1)
		{
			//DLOG_PERROR("rawsend: setsockopt(IPV6_FREEBIND)");
			// dont error because it's supported only from kernel 4.15
		}
#endif
	}
	return *sock;
exiterr:
	rawsend_clean_sock(sock);
	return -1;
}
bool rawsend_preinit(bool bind_fix4, bool bind_fix6)
{
	b_bind_fix4 = bind_fix4;
	b_bind_fix6 = bind_fix6;
#ifdef __APPLE__
	return macsend_preinit();
#else
	// allow ipv6 disabled systems
	return rawsend_socket(AF_INET)!=-1 && (rawsend_socket(AF_INET6)!=-1 || errno==EAFNOSUPPORT);
#endif
}
bool rawsend(const struct sockaddr* dst,uint32_t fwmark,const char *ifout,const void *data,size_t len)
{
#ifdef __APPLE__
	(void)fwmark;
	(void)ifout;
	return macsend_packet(dst->sa_family, data, len);
#else
	ssize_t bytes;
	int sock=rawsend_socket(dst->sa_family);
	if (sock==-1) return false;
	if (!set_socket_fwmark(sock,fwmark)) return false;

	int salen = dst->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
	struct sockaddr_storage dst2;
	memcpy(&dst2,dst,salen);
	if (dst->sa_family==AF_INET6)
		((struct sockaddr_in6 *)&dst2)->sin6_port = 0; // or will be EINVAL in linux

#if defined(BSD)
	bytes = rawsend_sendto_divert(dst->sa_family,sock,data,len);
	if (bytes==-1)
	{
		DLOG_PERROR("rawsend: sendto_divert");
		return false;
	}
	return true;

#else

#ifdef __linux__
	struct sockaddr_storage sa_src;
	switch(dst->sa_family)
	{
		case AF_INET:
			if (!b_bind_fix4) goto nofix;
			extract_endpoints(data,NULL,NULL,NULL, &sa_src, NULL);
			break;
		case AF_INET6:
			if (!b_bind_fix6) goto nofix;
			extract_endpoints(NULL,data,NULL,NULL, &sa_src, NULL);
			break;
		default:
			return false; // should not happen
	}
	//printf("family %u dev %s bind : ",  dst->sa_family, ifout); print_sockaddr((struct sockaddr *)&sa_src); printf("\n");
	if (setsockopt(sock, SOL_SOCKET, SO_BINDTODEVICE, ifout, ifout ? strlen(ifout)+1 : 0) == -1)
	{
		DLOG_PERROR("rawsend: setsockopt(SO_BINDTODEVICE)");
		return false;
	}
	if (bind(sock, (const struct sockaddr*)&sa_src, dst->sa_family==AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6)))
	{
		DLOG_PERROR("rawsend: bind (ignoring)");
		// do not fail. this can happen regardless of IP_FREEBIND
		// rebind to any address
		memset(&sa_src,0,sizeof(sa_src));
		sa_src.ss_family = dst->sa_family;
		if (bind(sock, (const struct sockaddr*)&sa_src, dst->sa_family==AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6)))
		{
			DLOG_PERROR("rawsend: bind to any");
			return false;
		}
	}
nofix:
#endif

	// normal raw socket sendto
	bytes = sendto(sock, data, len, 0, (struct sockaddr*)&dst2, salen);
	if (bytes==-1)
	{
		char s[40];
		snprintf(s,sizeof(s),"rawsend: sendto (%zu)",len);
		DLOG_PERROR(s);
		return false;
	}
	return true;
#endif
#endif
}

#endif // not CYGWIN

bool rawsend_rp(const struct rawpacket *rp)
{
	return rawsend((struct sockaddr*)&rp->dst,rp->fwmark,rp->ifout,rp->packet,rp->len);
}
bool rawsend_queue(struct rawpacket_tailhead *q)
{
	struct rawpacket *rp;
	bool b;
	for (b=true; (rp=rawpacket_dequeue(q)) ; rawpacket_free(rp))
		b &= rawsend_rp(rp);
	return b;
}



#if defined(HAS_FILTER_SSID) && defined(__linux__)

// linux-specific wlan retrieval implementation

typedef void netlink_prepare_nlh_cb_t(struct nlmsghdr *nlh, void *param);

static bool netlink_genl_simple_transact(struct mnl_socket* nl, uint16_t type, uint16_t flags, uint8_t cmd, uint8_t version, netlink_prepare_nlh_cb_t cb_prepare_nlh, void *prepare_data, mnl_cb_t cb_data, void *data)
{
	char buf[MNL_SOCKET_BUFFER_SIZE];
	struct nlmsghdr *nlh;
	struct genlmsghdr *genl;
	ssize_t rd;

	nlh = mnl_nlmsg_put_header(buf);
	nlh->nlmsg_type	= type;
	nlh->nlmsg_flags = flags;

	genl = mnl_nlmsg_put_extra_header(nlh, sizeof(struct genlmsghdr));
	genl->cmd = cmd;
	genl->version = version;

	if (cb_prepare_nlh) cb_prepare_nlh(nlh, prepare_data);

	if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0)
	{
		DLOG_PERROR("mnl_socket_sendto");
		return false;
	}

	while ((rd=mnl_socket_recvfrom(nl, buf, sizeof(buf))) > 0)
	{
		switch(mnl_cb_run(buf, rd, 0, 0, cb_data, data))
		{
			case MNL_CB_STOP:
				return true;
			case MNL_CB_OK:
				break;
			default:
				return false;
		}
	}

	return false;
}

static void wlan_id_prepare(struct nlmsghdr *nlh, void *param)
{
	mnl_attr_put_strz(nlh, CTRL_ATTR_FAMILY_NAME, "nl80211");
}
static int wlan_id_attr_cb(const struct nlattr *attr, void *data)
{
	if (mnl_attr_type_valid(attr, CTRL_ATTR_MAX) < 0)
	{
		DLOG_PERROR("mnl_attr_type_valid");
		return MNL_CB_ERROR;
	}

	switch(mnl_attr_get_type(attr))
	{
		case CTRL_ATTR_FAMILY_ID:
			if (mnl_attr_validate(attr, MNL_TYPE_U16) < 0)
			{
				DLOG_PERROR("mnl_attr_validate(family_id)");
				return MNL_CB_ERROR;
			}
			*((uint16_t*)data) = mnl_attr_get_u16(attr);
		break;
	}
	return MNL_CB_OK;
}
static int wlan_id_cb(const struct nlmsghdr *nlh, void *data)
{
	return mnl_attr_parse(nlh, sizeof(struct genlmsghdr), wlan_id_attr_cb, data);
}
static uint16_t wlan_get_family_id(struct mnl_socket* nl)
{
	uint16_t id;
	return netlink_genl_simple_transact(nl, GENL_ID_CTRL, NLM_F_REQUEST | NLM_F_ACK, CTRL_CMD_GETFAMILY, 1, wlan_id_prepare, NULL, wlan_id_cb, &id) ? id : 0;
}

static int wlan_info_attr_cb(const struct nlattr *attr, void *data)
{
	struct wlan_interface *wlan = (struct wlan_interface *)data;
	switch(mnl_attr_get_type(attr))
	{
		case NL80211_ATTR_IFINDEX:
			if (mnl_attr_validate(attr, MNL_TYPE_U32) < 0)
			{
				DLOG_PERROR("mnl_attr_validate(ifindex)");
				return MNL_CB_ERROR;
			}
			wlan->ifindex = mnl_attr_get_u32(attr);
			break;
		case NL80211_ATTR_SSID:
			if (mnl_attr_validate(attr, MNL_TYPE_STRING) < 0)
			{
				DLOG_PERROR("mnl_attr_validate(ssid)");
				return MNL_CB_ERROR;
			}
			snprintf(wlan->ssid,sizeof(wlan->ssid),"%s",mnl_attr_get_str(attr));
			break;
		case NL80211_ATTR_IFNAME:
			if (mnl_attr_validate(attr, MNL_TYPE_STRING) < 0)
			{
				DLOG_PERROR("mnl_attr_validate(ifname)");
				return MNL_CB_ERROR;
			}
			snprintf(wlan->ifname,sizeof(wlan->ifname),"%s",mnl_attr_get_str(attr));
			break;
	}
	return MNL_CB_OK;
}
struct wlan_info_req
{
	struct wlan_interface_collection *wc;
	bool bReqSSID;
};
static int wlan_info_cb(const struct nlmsghdr *nlh, void *data)
{
	int ret;
	struct wlan_info_req *wr = (struct wlan_info_req*)data;
	if (wr->wc->count>=WLAN_INTERFACE_MAX) return MNL_CB_OK;
	memset(wr->wc->wlan + wr->wc->count,0,sizeof(struct wlan_interface));
	ret = mnl_attr_parse(nlh, sizeof(struct genlmsghdr), wlan_info_attr_cb, wr->wc->wlan + wr->wc->count);
	if (ret>=0 && (!wr->bReqSSID || *wr->wc->wlan[wr->wc->count].ssid) && *wr->wc->wlan[wr->wc->count].ifname && wr->wc->wlan[wr->wc->count].ifindex)
		wr->wc->count++;
	return ret;
}
static bool wlan_info(struct mnl_socket* nl, uint16_t wlan_family_id, struct wlan_interface_collection* w, bool bReqSSID)
{
	struct wlan_info_req req = { .bReqSSID = bReqSSID, .wc = w };
	return netlink_genl_simple_transact(nl, wlan_family_id, NLM_F_REQUEST | NLM_F_ACK | NLM_F_DUMP, NL80211_CMD_GET_INTERFACE, 0, NULL, NULL, wlan_info_cb, &req);
}


static void scan_prepare(struct nlmsghdr *nlh, void *param)
{
	mnl_attr_put_u32(nlh, NL80211_ATTR_IFINDEX, *(int*)param);
}
static uint8_t *find_ie(uint8_t *buf, size_t len, uint8_t ie)
{
	while (len>=2)
	{
		if (len<(2+buf[1])) break;
		if (buf[0]==ie) return buf;
		buf+=buf[1]+2;
		len-=buf[1]+2;
	}
	return NULL;
}
static int scan_info_attr_cb(const struct nlattr *attr, void *data)
{
	struct wlan_interface *wlan = (struct wlan_interface *)data;
	const struct nlattr *nested;
	uint8_t *payload, *ie;
	uint16_t payload_len;
	bool ok;

	switch(mnl_attr_get_type(attr))
	{
		case NL80211_ATTR_IFINDEX:
			if (mnl_attr_validate(attr, MNL_TYPE_U32) < 0)
			{
				DLOG_PERROR("mnl_attr_validate");
				return MNL_CB_ERROR;
			}
			wlan->ifindex = mnl_attr_get_u32(attr);
			if (!if_indextoname(wlan->ifindex, wlan->ifname))
				DLOG_PERROR("if_indextoname");
			break;
		case NL80211_ATTR_BSS:
			if (mnl_attr_validate(attr, MNL_TYPE_NESTED) < 0)
			{
				DLOG_PERROR("mnl_attr_validate");
				return MNL_CB_ERROR;
			}
			ok = false;
			mnl_attr_for_each_nested(nested, attr)
			{
				if (mnl_attr_get_type(nested)==NL80211_BSS_STATUS)
				{
					uint32_t status = mnl_attr_get_u32(nested);
					if (status==NL80211_BSS_STATUS_ASSOCIATED || status==NL80211_BSS_STATUS_AUTHENTICATED || status==NL80211_BSS_STATUS_IBSS_JOINED)
					{
						ok=1;
						break;
					}
				}
			}
			if (!ok) break;
			mnl_attr_for_each_nested(nested, attr)
			{
				switch(mnl_attr_get_type(nested))
				{
					case NL80211_BSS_INFORMATION_ELEMENTS:
						payload_len = mnl_attr_get_payload_len(nested);
						payload = mnl_attr_get_payload(nested);
						ie = find_ie(payload,payload_len,0);
						if (ie)
						{
							uint8_t l = ie[1];
							if (l>=(sizeof(wlan->ssid))) l=sizeof(wlan->ssid)-1;
							memcpy(wlan->ssid,ie+2,l);
							wlan->ssid[l]=0;
						}
						break;
				}
			}
			break;
	}
	return MNL_CB_OK;
}
static int scan_info_cb(const struct nlmsghdr *nlh, void *data)
{
	int ret;
	struct wlan_interface_collection *wc = (struct wlan_interface_collection*)data;
	if (wc->count>=WLAN_INTERFACE_MAX) return MNL_CB_OK;
	memset(wc->wlan+wc->count,0,sizeof(wc->wlan[0]));
	ret = mnl_attr_parse(nlh, sizeof(struct genlmsghdr), scan_info_attr_cb, wc->wlan+wc->count);
	if (ret>=0 && *wc->wlan[wc->count].ssid && *wc->wlan[wc->count].ifname && wc->wlan[wc->count].ifindex)
		wc->count++;
	return ret;
}
static bool scan_info(struct mnl_socket* nl, uint16_t wlan_family_id, struct wlan_interface_collection* w)
{
	struct wlan_interface_collection wc_all = { .count = 0 };
	// wlan_info does not return ssid since kernel 5.19
	// it's used to enumerate all wifi interfaces then call scan_info on each
	if (!wlan_info(nl, wlan_family_id, &wc_all, false)) return false;
	w->count=0;
	for(int i=0;i<wc_all.count;i++)
		if (!netlink_genl_simple_transact(nl, wlan_family_id, NLM_F_REQUEST | NLM_F_ACK | NLM_F_DUMP, NL80211_CMD_GET_SCAN, 0, scan_prepare, (void*)&wc_all.wlan[i].ifindex, scan_info_cb, w))
			return false;
	return true;
}


static bool wlan_init80211(struct mnl_socket** nl)
{
	if (!(*nl = mnl_socket_open(NETLINK_GENERIC)))
	{
		DLOG_PERROR("mnl_socket_open");
		return false;
	}
	if (mnl_socket_bind(*nl, 0, MNL_SOCKET_AUTOPID))
	{
		DLOG_PERROR("mnl_socket_bind");
		return false;
	}
	return true;
}

static void wlan_deinit80211(struct mnl_socket** nl)
{
	if (*nl)
	{
		mnl_socket_close(*nl);
		*nl = NULL;
	}
}

static time_t wlan_info_last = 0;
static bool wlan_info_rate_limited(struct mnl_socket* nl, uint16_t wlan_family_id, struct wlan_interface_collection* w)
{
	bool bres = true;
	time_t now = time(NULL);

	// do not purge too often to save resources
	if (wlan_info_last != now)
	{
		bres = scan_info(nl,wlan_family_id,w);
		wlan_info_last = now;
	}
	return bres;
}

static struct mnl_socket* nl_wifi = NULL;
static uint16_t id_nl80211;
struct wlan_interface_collection wlans = { .count = 0 };

void wlan_info_deinit(void)
{
	wlan_deinit80211(&nl_wifi);
}
bool wlan_info_init(void)
{
	wlan_info_deinit();

	if (!wlan_init80211(&nl_wifi)) return false;
	if (!(id_nl80211 = wlan_get_family_id(nl_wifi)))
	{
		wlan_info_deinit();
		return false;
	}
	return true;
}
bool wlan_info_get_rate_limited(void)
{
	return wlan_info_rate_limited(nl_wifi, id_nl80211, &wlans);
}

#endif


#ifdef HAS_FILTER_SSID
const char *wlan_ifname2ssid(const struct wlan_interface_collection *w, const char *ifname)
{
	int i;
	if (ifname)
	{
		for (i=0;i<w->count;i++)
			if (!strcmp(w->wlan[i].ifname,ifname))
				return w->wlan[i].ssid;
	}
	return NULL;
}
const char *wlan_ifidx2ssid(const struct wlan_interface_collection *w,int ifidx)
{
	int i;
	for (i=0;i<w->count;i++)
		if (w->wlan[i].ifindex == ifidx)
			return w->wlan[i].ssid;
	return NULL;
}
const char *wlan_ssid_search_ifname(const char *ifname)
{
	return wlan_ifname2ssid(&wlans,ifname);
}
const char *wlan_ssid_search_ifidx(int ifidx)
{
	return wlan_ifidx2ssid(&wlans,ifidx);
}

#endif



uint8_t hop_count_guess(uint8_t ttl)
{
	// 18.65.168.125 ( cloudfront ) 	255
	// 157.254.246.178 			128
	// 1.1.1.1				 64
	// guess original ttl. consider path lengths less than 32 hops

	uint8_t orig;

	if (ttl>223)
		orig=255;
	else if (ttl<128 && ttl>96)
		orig=128;
	else if (ttl<64 && ttl>32)
		orig=64;
	else
		return 0;

	return orig - ttl;
}
// return guessed fake ttl value. 0 means unsuccessfull, should not perform autottl fooling
uint8_t autottl_eval(uint8_t hop_count, const autottl *attl)
{
	uint8_t fake;
	int d;

	d = (int)hop_count + attl->delta;
	if (d<attl->min) fake=attl->min;
	else if (d>attl->max) fake=attl->max;
	else fake=(uint8_t)d;

	if (attl->delta<0 && fake>=hop_count || attl->delta>=0 && fake<hop_count)
		return 0;

	return fake;
}

void do_nat(bool bOutbound, struct ip *ip, struct ip6_hdr *ip6, struct tcphdr *tcphdr, struct udphdr *udphdr, const struct sockaddr_in *target4, const struct sockaddr_in6 *target6)
{
	uint16_t nport;

	if (ip && target4)
	{
		nport = target4->sin_port;
		if (bOutbound)
			ip->ip_dst = target4->sin_addr;
		else
			ip->ip_src = target4->sin_addr;
		ip4_fix_checksum(ip);
	}
	else if (ip6 && target6)
	{
		nport = target6->sin6_port;
		if (bOutbound)
			ip6->ip6_dst = target6->sin6_addr;
		else
			ip6->ip6_src = target6->sin6_addr;
	}
	else
		return;
	if (nport)
	{
		if (tcphdr)
		{
			if (bOutbound)
				tcphdr->th_dport = nport;
			else
				tcphdr->th_sport = nport;
		}
		if (udphdr)
		{
			if (bOutbound)
				udphdr->uh_dport = nport;
			else
				udphdr->uh_sport = nport;
		}
	}
}


void verdict_tcp_csum_fix(uint8_t verdict, struct tcphdr *tcphdr, size_t transport_len, struct ip *ip, struct ip6_hdr *ip6hdr)
{
	if (!(verdict & VERDICT_NOCSUM))
	{
		#ifdef __CYGWIN__
		// always fix csum for windivert. original can be partial or bad
		if ((verdict & VERDICT_MASK)!=VERDICT_DROP)
		#elif defined(__FreeBSD__)
		// FreeBSD tend to pass ipv6 frames with wrong checksum
		if ((verdict & VERDICT_MASK)==VERDICT_MODIFY || ip6hdr)
		#else
		// if original packet was tampered earlier it needs checksum fixed
		if ((verdict & VERDICT_MASK)==VERDICT_MODIFY)
		#endif
			tcp_fix_checksum(tcphdr,transport_len,ip,ip6hdr);
	}
}
void verdict_udp_csum_fix(uint8_t verdict, struct udphdr *udphdr, size_t transport_len, struct ip *ip, struct ip6_hdr *ip6hdr)
{
	if (!(verdict & VERDICT_NOCSUM))
	{
		#ifdef __CYGWIN__
		// always fix csum for windivert. original can be partial or bad
		if ((verdict & VERDICT_MASK)!=VERDICT_DROP)
		#elif defined(__FreeBSD__)
		// FreeBSD tend to pass ipv6 frames with wrong checksum
		if ((verdict & VERDICT_MASK)==VERDICT_MODIFY || ip6hdr)
		#else
		// if original packet was tampered earlier it needs checksum fixed
		if ((verdict & VERDICT_MASK)==VERDICT_MODIFY)
		#endif
			udp_fix_checksum(udphdr,transport_len,ip,ip6hdr);
	}
}

void dbgprint_socket_buffers(int fd)
{
	if (params.debug)
	{
		int v;
		socklen_t sz;
		sz = sizeof(int);
		if (!getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, &sz))
			DLOG("fd=%d SO_RCVBUF=%d\n", fd, v);
			sz = sizeof(int);
		if (!getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &v, &sz))
			DLOG("fd=%d SO_SNDBUF=%d\n", fd, v);
	}
}
bool set_socket_buffers(int fd, int rcvbuf, int sndbuf)
{
	DLOG("set_socket_buffers fd=%d rcvbuf=%d sndbuf=%d\n", fd, rcvbuf, sndbuf);
	if (rcvbuf && setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(int)) < 0)
	{
		DLOG_PERROR("setsockopt (SO_RCVBUF)");
		return false;
	}
	if (sndbuf && setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(int)) < 0)
	{
		DLOG_PERROR("setsockopt (SO_SNDBUF)");
		return false;
	}
	dbgprint_socket_buffers(fd);
	return true;
}
