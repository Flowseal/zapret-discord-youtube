#define _GNU_SOURCE

#include <string.h>
#include <errno.h>

#include "desync.h"
#include "protocol.h"
#include "params.h"
#include "helpers.h"
#include "hostlist.h"
#include "ipset.h"
#include "conntrack.h"

const char *fake_http_request_default = "GET / HTTP/1.1\r\nHost: www.iana.org\r\n"
"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/109.0\r\n"
"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n"
"Accept-Encoding: gzip, deflate, br\r\n\r\n";

// SNI - www.microsoft.com
const uint8_t fake_tls_clienthello_default[680] = {
  0x16, 0x03, 0x01, 0x02, 0xa3, 0x01, 0x00, 0x02, 0x9f, 0x03, 0x03, 0x41,
  0x88, 0x82, 0x2d, 0x4f, 0xfd, 0x81, 0x48, 0x9e, 0xe7, 0x90, 0x65, 0x1f,
  0xba, 0x05, 0x7b, 0xff, 0xa7, 0x5a, 0xf9, 0x5b, 0x8a, 0x8f, 0x45, 0x8b,
  0x41, 0xf0, 0x3d, 0x1b, 0xdd, 0xe3, 0xf8, 0x20, 0x9b, 0x23, 0xa5, 0xd2,
  0x21, 0x1e, 0x9f, 0xe7, 0x85, 0x6c, 0xfc, 0x61, 0x80, 0x3a, 0x3f, 0xba,
  0xb9, 0x60, 0xba, 0xb3, 0x0e, 0x98, 0x27, 0x6c, 0xf7, 0x38, 0x28, 0x65,
  0x80, 0x5d, 0x40, 0x38, 0x00, 0x22, 0x13, 0x01, 0x13, 0x03, 0x13, 0x02,
  0xc0, 0x2b, 0xc0, 0x2f, 0xcc, 0xa9, 0xcc, 0xa8, 0xc0, 0x2c, 0xc0, 0x30,
  0xc0, 0x0a, 0xc0, 0x09, 0xc0, 0x13, 0xc0, 0x14, 0x00, 0x9c, 0x00, 0x9d,
  0x00, 0x2f, 0x00, 0x35, 0x01, 0x00, 0x02, 0x34, 0x00, 0x00, 0x00, 0x16,
  0x00, 0x14, 0x00, 0x00, 0x11, 0x77, 0x77, 0x77, 0x2e, 0x6d, 0x69, 0x63,
  0x72, 0x6f, 0x73, 0x6f, 0x66, 0x74, 0x2e, 0x63, 0x6f, 0x6d, 0x00, 0x17,
  0x00, 0x00, 0xff, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0a, 0x00, 0x0e, 0x00,
  0x0c, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x18, 0x00, 0x19, 0x01, 0x00, 0x01,
  0x01, 0x00, 0x0b, 0x00, 0x02, 0x01, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00,
  0x10, 0x00, 0x0e, 0x00, 0x0c, 0x02, 0x68, 0x32, 0x08, 0x68, 0x74, 0x74,
  0x70, 0x2f, 0x31, 0x2e, 0x31, 0x00, 0x05, 0x00, 0x05, 0x01, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x22, 0x00, 0x0a, 0x00, 0x08, 0x04, 0x03, 0x05, 0x03,
  0x06, 0x03, 0x02, 0x03, 0x00, 0x12, 0x00, 0x00, 0x00, 0x33, 0x00, 0x6b,
  0x00, 0x69, 0x00, 0x1d, 0x00, 0x20, 0x69, 0x15, 0x16, 0x29, 0x6d, 0xad,
  0xd5, 0x68, 0x88, 0x27, 0x2f, 0xde, 0xaf, 0xac, 0x3c, 0x4c, 0xa4, 0xe4,
  0xd8, 0xc8, 0xfb, 0x41, 0x87, 0xf4, 0x76, 0x4e, 0x0e, 0xfa, 0x64, 0xc4,
  0xe9, 0x29, 0x00, 0x17, 0x00, 0x41, 0x04, 0xfe, 0x62, 0xb9, 0x08, 0xc8,
  0xc3, 0x2a, 0xb9, 0x87, 0x37, 0x84, 0x42, 0x6b, 0x5c, 0xcd, 0xc9, 0xca,
  0x62, 0x38, 0xd3, 0xd9, 0x99, 0x8a, 0xc4, 0x2d, 0xc6, 0xd0, 0xa3, 0x60,
  0xb2, 0x12, 0x54, 0x41, 0x8e, 0x52, 0x5e, 0xe3, 0xab, 0xf9, 0xc2, 0x07,
  0x81, 0xdc, 0xf8, 0xf2, 0x6a, 0x91, 0x40, 0x2f, 0xcb, 0xa4, 0xff, 0x6f,
  0x24, 0xc7, 0x4d, 0x77, 0x77, 0x2d, 0x6f, 0xe0, 0x77, 0xaa, 0x92, 0x00,
  0x2b, 0x00, 0x05, 0x04, 0x03, 0x04, 0x03, 0x03, 0x00, 0x0d, 0x00, 0x18,
  0x00, 0x16, 0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x08, 0x04, 0x08, 0x05,
  0x08, 0x06, 0x04, 0x01, 0x05, 0x01, 0x06, 0x01, 0x02, 0x03, 0x02, 0x01,
  0x00, 0x2d, 0x00, 0x02, 0x01, 0x01, 0x00, 0x1c, 0x00, 0x02, 0x40, 0x01,
  0x00, 0x1b, 0x00, 0x07, 0x06, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0xfe,
  0x0d, 0x01, 0x19, 0x00, 0x00, 0x01, 0x00, 0x03, 0x21, 0x00, 0x20, 0x62,
  0xe8, 0x83, 0xd8, 0x97, 0x05, 0x8a, 0xbe, 0xa1, 0xf2, 0x63, 0x4e, 0xce,
  0x93, 0x84, 0x8e, 0xcf, 0xe7, 0xdd, 0xb2, 0xe4, 0x87, 0x06, 0xac, 0x11,
  0x19, 0xbe, 0x0e, 0x71, 0x87, 0xf1, 0xa6, 0x00, 0xef, 0xd8, 0x6b, 0x27,
  0x5e, 0xc0, 0xa7, 0x5d, 0x42, 0x4e, 0x8c, 0xdc, 0xf3, 0x9f, 0x1c, 0x51,
  0x62, 0xef, 0xff, 0x5b, 0xed, 0xc8, 0xfd, 0xee, 0x6f, 0xbb, 0x88, 0x9b,
  0xb1, 0x30, 0x9c, 0x66, 0x42, 0xab, 0x0f, 0x66, 0x89, 0x18, 0x8b, 0x11,
  0xc1, 0x6d, 0xe7, 0x2a, 0xeb, 0x96, 0x3b, 0x7f, 0x52, 0x78, 0xdb, 0xf8,
  0x6d, 0x04, 0xf7, 0x95, 0x1a, 0xa8, 0xf0, 0x64, 0x52, 0x07, 0x39, 0xf0,
  0xa8, 0x1d, 0x0d, 0x16, 0x36, 0xb7, 0x18, 0x0e, 0xc8, 0x44, 0x27, 0xfe,
  0xf3, 0x31, 0xf0, 0xde, 0x8c, 0x74, 0xf5, 0xa1, 0xd8, 0x8f, 0x6f, 0x45,
  0x97, 0x69, 0x79, 0x5e, 0x2e, 0xd4, 0xb0, 0x2c, 0x0c, 0x1a, 0x6f, 0xcc,
  0xce, 0x90, 0xc7, 0xdd, 0xc6, 0x60, 0x95, 0xf3, 0xc2, 0x19, 0xde, 0x50,
  0x80, 0xbf, 0xde, 0xf2, 0x25, 0x63, 0x15, 0x26, 0x63, 0x09, 0x1f, 0xc5,
  0xdf, 0x32, 0xf5, 0xea, 0x9c, 0xd2, 0xff, 0x99, 0x4e, 0x67, 0xa2, 0xe5,
  0x1a, 0x94, 0x85, 0xe3, 0xdf, 0x36, 0xa5, 0x83, 0x4b, 0x0a, 0x1c, 0xaf,
  0xd7, 0x48, 0xc9, 0x4b, 0x8a, 0x27, 0xdd, 0x58, 0x7f, 0x95, 0xf2, 0x6b,
  0xde, 0x2b, 0x12, 0xd3, 0xec, 0x4d, 0x69, 0x37, 0x9c, 0x13, 0x9b, 0x16,
  0xb0, 0x45, 0x52, 0x38, 0x77, 0x69, 0xef, 0xaa, 0x65, 0x19, 0xbc, 0xc2,
  0x93, 0x4d, 0xb0, 0x1b, 0x7f, 0x5b, 0x41, 0xff, 0xaf, 0xba, 0x50, 0x51,
  0xc3, 0xf1, 0x27, 0x09, 0x25, 0xf5, 0x60, 0x90, 0x09, 0xb1, 0xe5, 0xc0,
  0xc7, 0x42, 0x78, 0x54, 0x3b, 0x23, 0x19, 0x7d, 0x8e, 0x72, 0x13, 0xb4,
  0xd3, 0xcd, 0x63, 0xb6, 0xc4, 0x4a, 0x28, 0x3d, 0x45, 0x3e, 0x8b, 0xdb,
  0x84, 0x4f, 0x78, 0x64, 0x30, 0x69, 0xe2, 0x1b
};

#define PKTDATA_MAXDUMP 32
#define IP_MAXDUMP 80

#define TCP_MAX_REASM 16384
#define UDP_MAX_REASM 16384

static void TLSDebugHandshake(const uint8_t *tls, size_t sz)
{
	if (!params.debug) return;

	if (sz < 6) return;

	const uint8_t *ext;
	size_t len, len2;

	uint16_t v_handshake = pntoh16(tls + 4), v, v2;
	DLOG("TLS handshake version : %s\n", TLSVersionStr(v_handshake));

	if (TLSFindExtInHandshake(tls, sz, 43, &ext, &len, false))
	{
		if (len)
		{
			len2 = ext[0];
			if (len2 < len)
			{
				for (ext++, len2 &= ~1; len2; len2 -= 2, ext += 2)
				{
					v = pntoh16(ext);
					DLOG("TLS supported versions ext : %s\n", TLSVersionStr(v));
				}
			}
		}
	}
	else
		DLOG("TLS supported versions ext : not present\n");

	if (TLSFindExtInHandshake(tls, sz, 16, &ext, &len, false))
	{
		if (len >= 2)
		{
			len2 = pntoh16(ext);
			if (len2 <= (len - 2))
			{
				char s[32];
				for (ext += 2; len2;)
				{
					v = *ext; ext++; len2--;
					if (v <= len2)
					{
						v2 = v < sizeof(s) ? v : sizeof(s) - 1;
						memcpy(s, ext, v2);
						s[v2] = 0;
						DLOG("TLS ALPN ext : %s\n", s);
						len2 -= v;
						ext += v;
					}
					else
						break;
				}
			}
		}
	}
	else
		DLOG("TLS ALPN ext : not present\n");

	DLOG("TLS ECH ext : %s\n", TLSFindExtInHandshake(tls, sz, 65037, NULL, NULL, false) ? "present" : "not present");
}
static void TLSDebug(const uint8_t *tls, size_t sz)
{
	if (!params.debug) return;

	if (sz < 11) return;

	DLOG("TLS record layer version : %s\n", TLSVersionStr(pntoh16(tls + 1)));

	size_t reclen = TLSRecordLen(tls);
	if (reclen < sz) sz = reclen; // correct len if it has more data than the first tls record has

	TLSDebugHandshake(tls + 5, sz - 5);
}

bool desync_valid_zero_stage(enum dpi_desync_mode mode)
{
	return mode == DESYNC_SYNACK || mode == DESYNC_SYNDATA;
}
bool desync_valid_first_stage(enum dpi_desync_mode mode)
{
	return mode == DESYNC_FAKE || mode == DESYNC_FAKE_KNOWN || mode == DESYNC_RST || mode == DESYNC_RSTACK || mode == DESYNC_HOPBYHOP || mode == DESYNC_DESTOPT || mode == DESYNC_IPFRAG1;
}
bool desync_only_first_stage(enum dpi_desync_mode mode)
{
	return false;
}
bool desync_valid_second_stage_tcp(enum dpi_desync_mode mode)
{
	return
		mode == DESYNC_NONE || mode == DESYNC_FAKEDDISORDER || mode == DESYNC_FAKEDSPLIT || mode == DESYNC_MULTISPLIT || mode == DESYNC_MULTIDISORDER || mode == DESYNC_HOSTFAKESPLIT ||
		mode == DESYNC_IPFRAG2;
}
bool desync_valid_second_stage_udp(enum dpi_desync_mode mode)
{
	return mode == DESYNC_NONE || mode == DESYNC_UDPLEN || mode == DESYNC_TAMPER || mode == DESYNC_IPFRAG2;
}
bool desync_valid_second_stage(enum dpi_desync_mode mode)
{
	return desync_valid_second_stage_tcp(mode) || desync_valid_second_stage_udp(mode);
}
enum dpi_desync_mode desync_mode_from_string(const char *s)
{
	if (!s)
		return DESYNC_NONE;
	else if (!strcmp(s, "fake"))
		return DESYNC_FAKE;
	else if (!strcmp(s, "fakeknown"))
		return DESYNC_FAKE_KNOWN;
	else if (!strcmp(s, "rst"))
		return DESYNC_RST;
	else if (!strcmp(s, "rstack"))
		return DESYNC_RSTACK;
	else if (!strcmp(s, "synack"))
		return DESYNC_SYNACK;
	else if (!strcmp(s, "syndata"))
		return DESYNC_SYNDATA;
	else if (!strcmp(s, "fakeddisorder") || !strcmp(s, "disorder"))
		return DESYNC_FAKEDDISORDER;
	else if (!strcmp(s, "fakedsplit") || !strcmp(s, "split"))
		return DESYNC_FAKEDSPLIT;
	else if (!strcmp(s, "multisplit") || !strcmp(s, "split2"))
		return DESYNC_MULTISPLIT;
	else if (!strcmp(s, "multidisorder") || !strcmp(s, "disorder2"))
		return DESYNC_MULTIDISORDER;
	else if (!strcmp(s, "hostfakesplit"))
		return DESYNC_HOSTFAKESPLIT;
	else if (!strcmp(s, "ipfrag2"))
		return DESYNC_IPFRAG2;
	else if (!strcmp(s, "hopbyhop"))
		return DESYNC_HOPBYHOP;
	else if (!strcmp(s, "destopt"))
		return DESYNC_DESTOPT;
	else if (!strcmp(s, "ipfrag1"))
		return DESYNC_IPFRAG1;
	else if (!strcmp(s, "udplen"))
		return DESYNC_UDPLEN;
	else if (!strcmp(s, "tamper"))
		return DESYNC_TAMPER;
	return DESYNC_INVALID;
}

static bool dp_match(
	struct desync_profile *dp,
	uint8_t l3proto, const struct sockaddr *dest, const char *hostname, bool bNoSubdom, t_l7proto l7proto, const char *ssid,
	bool *bCheckDone, bool *bCheckResult, bool *bExcluded)
{
	bool bHostlistsEmpty;

	if (bCheckDone) *bCheckDone = false;

	if (!HostlistsReloadCheckForProfile(dp)) return false;

	if ((dest->sa_family == AF_INET && !dp->filter_ipv4) || (dest->sa_family == AF_INET6 && !dp->filter_ipv6))
		// L3 filter does not match
		return false;
	if ((l3proto == IPPROTO_TCP && !port_filters_in_range(&dp->pf_tcp, saport(dest))) || (l3proto == IPPROTO_UDP && !port_filters_in_range(&dp->pf_udp, saport(dest))))
		// L4 filter does not match
		return false;
	if (dp->filter_l7 && !l7_proto_match(l7proto, dp->filter_l7))
		// L7 filter does not match
		return false;
#ifdef HAS_FILTER_SSID
	if (!LIST_EMPTY(&dp->filter_ssid) && !strlist_search(&dp->filter_ssid, ssid))
		return false;
#endif

	bHostlistsEmpty = PROFILE_HOSTLISTS_EMPTY(dp);
	if (!dp->hostlist_auto && !hostname && !bHostlistsEmpty)
		// avoid cpu consuming ipset check. profile cannot win if regular hostlists are present without auto hostlist and hostname is unknown.
		return false;
	if (!IpsetCheck(dp, dest->sa_family == AF_INET ? &((struct sockaddr_in*)dest)->sin_addr : NULL, dest->sa_family == AF_INET6 ? &((struct sockaddr_in6*)dest)->sin6_addr : NULL))
		// target ip does not match
		return false;

	// autohostlist profile matching l3/l4/l7 filter always win
	if (dp->hostlist_auto) return true;

	if (bHostlistsEmpty)
		// profile without hostlist filter wins
		return true;
	else
	{
		// if hostlists are present profile matches only if hostname is known and satisfy profile hostlists
		if (hostname)
		{
			if (bCheckDone) *bCheckDone = true;
			bool b;
			b = HostlistCheck(dp, hostname, bNoSubdom, bExcluded, true);
			if (bCheckResult) *bCheckResult = b;
			return b;
		}
	}
	return false;
}
static struct desync_profile *dp_find(
	struct desync_profile_list_head *head,
	uint8_t l3proto, const struct sockaddr *dest, const char *hostname, bool bNoSubdom, t_l7proto l7proto, const char *ssid,
	bool *bCheckDone, bool *bCheckResult, bool *bExcluded)
{
	struct desync_profile_list *dpl;
	if (params.debug)
	{
		char ip_port[48];
		ntop46_port(dest, ip_port, sizeof(ip_port));
		DLOG("desync profile search for %s target=%s l7proto=%s ssid='%s' hostname='%s'\n", proto_name(l3proto), ip_port, l7proto_str(l7proto), ssid ? ssid : "", hostname ? hostname : "");
	}
	if (bCheckDone) *bCheckDone = false;
	LIST_FOREACH(dpl, head, next)
	{
		if (dp_match(&dpl->dp, l3proto, dest, hostname, bNoSubdom, l7proto, ssid, bCheckDone, bCheckResult, bExcluded))
		{
			DLOG("desync profile %d matches\n", dpl->dp.n);
			return &dpl->dp;
		}
	}
	DLOG("desync profile not found\n");
	return NULL;
}

// auto creates internal socket and uses it for subsequent calls
static bool rawsend_rep(int repeats, const struct sockaddr* dst, uint32_t fwmark, const char *ifout, const void *data, size_t len)
{
	for (int i = 0; i < repeats; i++)
		if (!rawsend(dst, fwmark, ifout, data, len))
			return false;
	return true;
}


static uint64_t cutoff_get_limit(const t_ctrack *ctrack, char mode)
{
	switch (mode)
	{
	case 'n': return ctrack->pcounter_orig;
	case 'd': return ctrack->pdcounter_orig;
	case 's': return ctrack->seq_last - ctrack->seq0;
	default: return 0;
	}
}
static bool cutoff_test(const t_ctrack *ctrack, uint64_t cutoff, char mode)
{
	return cutoff && cutoff_get_limit(ctrack, mode) >= cutoff;
}
static void maybe_cutoff(t_ctrack *ctrack, uint8_t proto)
{
	if (ctrack && ctrack->dp)
	{
		if (proto == IPPROTO_TCP)
			ctrack->b_wssize_cutoff |= cutoff_test(ctrack, ctrack->dp->wssize_cutoff, ctrack->dp->wssize_cutoff_mode);
		ctrack->b_desync_cutoff |= cutoff_test(ctrack, ctrack->dp->desync_cutoff, ctrack->dp->desync_cutoff_mode);
		ctrack->b_dup_cutoff |= cutoff_test(ctrack, ctrack->dp->dup_cutoff, ctrack->dp->dup_cutoff_mode);
		ctrack->b_orig_mod_cutoff |= cutoff_test(ctrack, ctrack->dp->orig_mod_cutoff, ctrack->dp->orig_mod_cutoff_mode);

		// in MULTI STRATEGY concept conntrack entry holds desync profile
		// we do not want to remove conntrack entries ASAP anymore

		/*
		// we do not need conntrack entry anymore if all cutoff conditions are either not defined or reached
		// do not drop udp entry because it will be recreated when next packet arrives
		if (proto==IPPROTO_TCP)
			ctrack->b_cutoff |= \
				(!ctrack->dp->wssize || ctrack->b_wssize_cutoff) &&
				(!ctrack->dp->desync_cutoff || ctrack->b_desync_cutoff) &&
				(!ctrack->hostname_ah_check || ctrack->req_retrans_counter==RETRANS_COUNTER_STOP) &&
				ReasmIsEmpty(&ctrack->reasm_orig);
		*/
	}
}
static void wssize_cutoff(t_ctrack *ctrack)
{
	if (ctrack)
	{
		ctrack->b_wssize_cutoff = true;
		maybe_cutoff(ctrack, IPPROTO_TCP);
	}
}
static void forced_wssize_cutoff(t_ctrack *ctrack)
{
	if (ctrack && ctrack->dp && !ctrack->b_wssize_cutoff)
	{
		DLOG("forced wssize-cutoff\n");
		wssize_cutoff(ctrack);
	}
}

static void ctrack_stop_retrans_counter(t_ctrack *ctrack)
{
	if (ctrack && ctrack->hostname_ah_check)
	{
		ctrack->req_retrans_counter = RETRANS_COUNTER_STOP;
		maybe_cutoff(ctrack, IPPROTO_TCP);
	}
}

static void auto_hostlist_reset_fail_counter(struct desync_profile *dp, const char *hostname, const char *client_ip_port, t_l7proto l7proto)
{
	if (hostname)
	{
		hostfail_pool *fail_counter;

		fail_counter = HostFailPoolFind(dp->hostlist_auto_fail_counters, hostname);
		if (fail_counter)
		{
			HostFailPoolDel(&dp->hostlist_auto_fail_counters, fail_counter);
			DLOG("auto hostlist (profile %d) : %s : fail counter reset. website is working.\n", dp->n, hostname);
			HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : fail counter reset. website is working.", hostname, dp->n, client_ip_port, l7proto_str(l7proto));
		}
	}
}

// return true if retrans trigger fires
static bool auto_hostlist_retrans(t_ctrack *ctrack, uint8_t l4proto, int threshold, const char *client_ip_port, t_l7proto l7proto)
{
	if (ctrack && ctrack->dp && ctrack->hostname_ah_check && ctrack->req_retrans_counter != RETRANS_COUNTER_STOP)
	{
		if (l4proto == IPPROTO_TCP)
		{
			if (!ctrack->req_seq_finalized || ctrack->req_seq_abandoned)
				return false;
			if (!seq_within(ctrack->seq_last, ctrack->req_seq_start, ctrack->req_seq_end))
			{
				DLOG("req retrans : tcp seq %u not within the req range %u-%u. stop tracking.\n", ctrack->seq_last, ctrack->req_seq_start, ctrack->req_seq_end);
				ctrack_stop_retrans_counter(ctrack);
				auto_hostlist_reset_fail_counter(ctrack->dp, ctrack->hostname, client_ip_port, l7proto);
				return false;
			}
		}
		ctrack->req_retrans_counter++;
		if (ctrack->req_retrans_counter >= threshold)
		{
			DLOG("req retrans threshold reached : %u/%u\n", ctrack->req_retrans_counter, threshold);
			ctrack_stop_retrans_counter(ctrack);
			return true;
		}
		DLOG("req retrans counter : %u/%u\n", ctrack->req_retrans_counter, threshold);
	}
	return false;
}
static void auto_hostlist_failed(struct desync_profile *dp, const char *hostname, bool bNoSubdom, const char *client_ip_port, t_l7proto l7proto)
{
	hostfail_pool *fail_counter;

	fail_counter = HostFailPoolFind(dp->hostlist_auto_fail_counters, hostname);
	if (!fail_counter)
	{
		fail_counter = HostFailPoolAdd(&dp->hostlist_auto_fail_counters, hostname, dp->hostlist_auto_fail_time);
		if (!fail_counter)
		{
			DLOG_ERR("HostFailPoolAdd: out of memory\n");
			return;
		}
	}
	fail_counter->counter++;
	DLOG("auto hostlist (profile %d) : %s : fail counter %d/%d\n", dp->n, hostname, fail_counter->counter, dp->hostlist_auto_fail_threshold);
	HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : fail counter %d/%d", hostname, dp->n, client_ip_port, l7proto_str(l7proto), fail_counter->counter, dp->hostlist_auto_fail_threshold);
	if (fail_counter->counter >= dp->hostlist_auto_fail_threshold)
	{
		DLOG("auto hostlist (profile %d) : fail threshold reached. about to add %s to auto hostlist\n", dp->n, hostname);
		HostFailPoolDel(&dp->hostlist_auto_fail_counters, fail_counter);

		DLOG("auto hostlist (profile %d) : rechecking %s to avoid duplicates\n", dp->n, hostname);
		bool bExcluded = false;
		if (!HostlistCheck(dp, hostname, bNoSubdom, &bExcluded, false) && !bExcluded)
		{
			DLOG("auto hostlist (profile %d) : adding %s to %s\n", dp->n, hostname, dp->hostlist_auto->filename);
			HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : adding to %s", hostname, dp->n, client_ip_port, l7proto_str(l7proto), dp->hostlist_auto->filename);
			if (!HostlistPoolAddStr(&dp->hostlist_auto->hostlist, hostname, 0))
			{
				DLOG_ERR("StrPoolAddStr out of memory\n");
				return;
			}
			if (!append_to_list_file(dp->hostlist_auto->filename, hostname))
			{
				DLOG_PERROR("write to auto hostlist");
				return;
			}
			if (!file_mod_signature(dp->hostlist_auto->filename, &dp->hostlist_auto->mod_sig))
				DLOG_PERROR("file_mod_signature");
		}
		else
		{
			DLOG("auto hostlist (profile %d) : NOT adding %s\n", dp->n, hostname);
			HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : NOT adding, duplicate detected", hostname, dp->n, client_ip_port, l7proto_str(l7proto));
		}
	}
}

static void process_retrans_fail(t_ctrack *ctrack, uint8_t proto, const struct sockaddr *client)
{
	char client_ip_port[48];
	if (*params.hostlist_auto_debuglog)
		ntop46_port((struct sockaddr*)client, client_ip_port, sizeof(client_ip_port));
	else
		*client_ip_port = 0;
	if (ctrack && ctrack->dp && ctrack->hostname && auto_hostlist_retrans(ctrack, proto, ctrack->dp->hostlist_auto_retrans_threshold, client_ip_port, ctrack->l7proto))
	{
		HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : retrans threshold reached", ctrack->hostname, ctrack->dp->n, client_ip_port, l7proto_str(ctrack->l7proto));
		auto_hostlist_failed(ctrack->dp, ctrack->hostname, ctrack->hostname_is_ip, client_ip_port, ctrack->l7proto);
	}
}

static bool send_delayed(t_ctrack *ctrack)
{
	if (!rawpacket_queue_empty(&ctrack->delayed))
	{
		DLOG("SENDING %u delayed packets\n", rawpacket_queue_count(&ctrack->delayed));
		return rawsend_queue(&ctrack->delayed);
	}
	return true;
}


static bool reasm_start(t_ctrack *ctrack, t_reassemble *reasm, uint8_t proto, size_t sz, size_t szMax, const uint8_t *data_payload, size_t len_payload)
{
	ReasmClear(reasm);
	if (sz <= szMax)
	{
		uint32_t seq = (proto == IPPROTO_TCP) ? ctrack->seq_last : 0;
		if (ReasmInit(reasm, sz, seq))
		{
			ReasmFeed(reasm, seq, data_payload, len_payload);
			DLOG("starting reassemble. now we have %zu/%zu\n", reasm->size_present, reasm->size);
			return true;
		}
		else
			DLOG("reassemble init failed. out of memory\n");
	}
	else
		DLOG("unexpected large payload for reassemble: size=%zu\n", sz);
	return false;
}
static bool reasm_orig_start(t_ctrack *ctrack, uint8_t proto, size_t sz, size_t szMax, const uint8_t *data_payload, size_t len_payload)
{
	return reasm_start(ctrack, &ctrack->reasm_orig, proto, sz, szMax, data_payload, len_payload);
}
static bool reasm_feed(t_ctrack *ctrack, t_reassemble *reasm, uint8_t proto, const uint8_t *data_payload, size_t len_payload)
{
	if (ctrack && !ReasmIsEmpty(reasm))
	{
		uint32_t seq = (proto == IPPROTO_TCP) ? ctrack->seq_last : (uint32_t)reasm->size_present;
		if (ReasmFeed(reasm, seq, data_payload, len_payload))
		{
			DLOG("reassemble : feeding data payload size=%zu. now we have %zu/%zu\n", len_payload, reasm->size_present, reasm->size);
			return true;
		}
		else
		{
			ReasmClear(reasm);
			DLOG("reassemble session failed\n");
			send_delayed(ctrack);
		}
	}
	return false;
}
static bool reasm_orig_feed(t_ctrack *ctrack, uint8_t proto, const uint8_t *data_payload, size_t len_payload)
{
	return reasm_feed(ctrack, &ctrack->reasm_orig, proto, data_payload, len_payload);
}
static void reasm_orig_stop(t_ctrack *ctrack, const char *dlog_msg)
{
	if (ctrack)
	{
		if (!ReasmIsEmpty(&ctrack->reasm_orig))
		{
			DLOG("%s", dlog_msg);
			ReasmClear(&ctrack->reasm_orig);
		}
		send_delayed(ctrack);
		ctrack->delayed_first_gap = false;
	}
}
static void reasm_orig_cancel(t_ctrack *ctrack)
{
	reasm_orig_stop(ctrack, "reassemble session cancelled\n");
}
static void reasm_orig_fin(t_ctrack *ctrack)
{
	reasm_orig_stop(ctrack, "reassemble session finished\n");
}

#ifdef __APPLE__
static void reasm_orig_feed_delayed(t_ctrack *ctrack)
{
	bool fed;
	do
	{
		fed = false;
		struct rawpacket *rp;
		TAILQ_FOREACH(rp, &ctrack->delayed, next)
		{
			struct dissect dis;
			proto_dissect_l3l4(rp->packet, rp->len, &dis);
			if (dis.tcp && dis.len_payload && ntohl(dis.tcp->th_seq) == ctrack->reasm_orig.seq)
			{
				if (ReasmFeed(&ctrack->reasm_orig, ctrack->reasm_orig.seq, dis.data_payload, dis.len_payload))
					fed = true;
				break;
			}
		}
	}
	while (fed && !ReasmIsFull(&ctrack->reasm_orig));
}
#endif


static uint8_t ct_new_postnat_fix(const t_ctrack *ctrack, struct ip *ip, struct ip6_hdr *ip6, const struct tcphdr *tcp)
{
#ifdef __linux__
	// if used in postnat chain, dropping initial packet will cause conntrack connection teardown
	// so we need to workaround this.
	// SYN and SYN,ACK checks are for conntrack-less mode
	if (ctrack && ctrack->pcounter_orig == 1 || tcp && (tcp_syn_segment(tcp) || tcp_synack_segment(tcp)))
	{
		DLOG("applying linux postnat conntrack workaround\n");
		// make ip protocol invalid and low TTL
		if (ip6)
		{
			ip6->ip6_ctlun.ip6_un1.ip6_un1_nxt = 255;
			ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim = 1;
		}
		if (ip)
		{
			// this likely also makes ipv4 header checksum invalid
			ip->ip_p = 255;
			ip->ip_ttl = 1;
		}
		return VERDICT_MODIFY | VERDICT_NOCSUM;
	}
#endif
	return VERDICT_DROP;
}


static bool check_desync_interval(const struct desync_profile *dp, const t_ctrack *ctrack)
{
	if (dp)
	{
		if (dp->desync_start)
		{
			if (ctrack)
			{
				if (!cutoff_test(ctrack, dp->desync_start, dp->desync_start_mode))
				{
					DLOG("desync-start not reached (mode %c): %llu/%u . not desyncing\n", dp->desync_start_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->desync_start_mode), dp->desync_start);
					return false;
				}
				DLOG("desync-start reached (mode %c): %llu/%u\n", dp->desync_start_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->desync_start_mode), dp->desync_start);
			}
			else
			{
				DLOG("not desyncing. desync-start is set but conntrack entry is missing\n");
				return false;
			}
		}
		if (dp->desync_cutoff)
		{
			if (ctrack)
			{
				if (ctrack->b_desync_cutoff)
				{
					DLOG("desync-cutoff reached (mode %c): %llu/%u . not desyncing\n", dp->desync_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->desync_cutoff_mode), dp->desync_cutoff);
					return false;
				}
				DLOG("desync-cutoff not reached (mode %c): %llu/%u\n", dp->desync_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->desync_cutoff_mode), dp->desync_cutoff);
			}
			else
			{
				DLOG("not desyncing. desync-cutoff is set but conntrack entry is missing\n");
				return false;
			}
		}
	}
	return true;
}
static bool process_desync_interval(const struct desync_profile *dp, t_ctrack *ctrack)
{
	if (check_desync_interval(dp, ctrack))
		return true;
	else
	{
		reasm_orig_cancel(ctrack);
		return false;
	}
}
static bool check_dup_interval(const struct desync_profile *dp, const t_ctrack *ctrack)
{
	if (dp)
	{
		if (dp->dup_start)
		{
			if (ctrack)
			{
				if (!cutoff_test(ctrack, dp->dup_start, dp->dup_start_mode))
				{
					DLOG("dup-start not reached (mode %c): %llu/%u . not duping\n", dp->dup_start_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->dup_start_mode), dp->dup_start);
					return false;
				}
				DLOG("dup-start reached (mode %c): %llu/%u\n", dp->dup_start_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->dup_start_mode), dp->dup_start);
			}
			else
			{
				DLOG("not duping. dup-start is set but conntrack entry is missing\n");
				return false;
			}
		}
		if (dp->dup_cutoff)
		{
			if (ctrack)
			{
				if (ctrack->b_dup_cutoff)
				{
					DLOG("dup-cutoff reached (mode %c): %llu/%u . not duping\n", dp->dup_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->dup_cutoff_mode), dp->dup_cutoff);
					return false;
				}
				DLOG("dup-cutoff not reached (mode %c): %llu/%u\n", dp->dup_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->dup_cutoff_mode), dp->dup_cutoff);
			}
			else
			{
				DLOG("not duping. dup-cutoff is set but conntrack entry is missing\n");
				return false;
			}
		}
	}
	return true;
}
static bool check_orig_mod_interval(const struct desync_profile *dp, const t_ctrack *ctrack)
{
	if (dp)
	{
		if (dp->orig_mod_start)
		{
			if (ctrack)
			{
				if (!cutoff_test(ctrack, dp->orig_mod_start, dp->orig_mod_start_mode))
				{
					DLOG("orig-mod-start not reached (mode %c): %llu/%u . not modding original\n", dp->orig_mod_start_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->orig_mod_start_mode), dp->orig_mod_start);
					return false;
				}
				DLOG("orig-mod-start reached (mode %c): %llu/%u\n", dp->orig_mod_start_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->orig_mod_start_mode), dp->orig_mod_start);
			}
			else
			{
				DLOG("not modding original. orig-mod-start is set but conntrack entry is missing\n");
				return false;
			}
		}
		if (dp->orig_mod_cutoff)
		{
			if (ctrack)
			{
				if (ctrack->b_orig_mod_cutoff)
				{
					DLOG("orig-mod-cutoff reached (mode %c): %llu/%u . not modding original\n", dp->orig_mod_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->orig_mod_cutoff_mode), dp->orig_mod_cutoff);
					return false;
				}
				DLOG("orig-mod-cutoff not reached (mode %c): %llu/%u\n", dp->orig_mod_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->orig_mod_cutoff_mode), dp->orig_mod_cutoff);
			}
			else
			{
				DLOG("not modding original. orig-mod-cutoff is set but conntrack entry is missing\n");
				return false;
			}
		}
	}
	return true;
}

static bool replay_queue(struct rawpacket_tailhead *q);

static size_t pos_normalize(size_t split_pos, size_t reasm_offset, size_t len_payload)
{
	return (split_pos > reasm_offset && (split_pos - reasm_offset) < len_payload) ? split_pos - reasm_offset : 0;
}

static uint8_t autottl_guess(autottl *attl, uint8_t hop_count, const char *attl_kind)
{
	if (AUTOTTL_ENABLED(*attl))
	{
		uint8_t autottl = autottl_eval(hop_count, attl);
		if (autottl)
			DLOG("%s autottl: guessed %u\n", attl_kind, autottl);
		else
			DLOG("%s autottl: could not guess\n", attl_kind);
		return autottl;
	}
	else
		return 0;
}
static void autottl_discover(t_ctrack *ctrack, const struct in_addr *a4, const struct in6_addr *a6, const char *iface)
{
	if (ctrack && params.autottl_present && !ctrack->b_autottl_discovered)
	{
		ip_cache_item *ipc = ipcacheTouch(&params.ipcache, a4, a6, iface);
		if (!ipc)
		{
			DLOG_ERR("ipcache: out of memory\n");
			return;
		}
		if (ctrack->incoming_ttl)
		{
			uint8_t old_hops = ipc->hops;
			ipc->hops = hop_count_guess(ctrack->incoming_ttl);
			DLOG("incoming hops guessed %u\n", ipc->hops);
			if (old_hops != ipc->hops)
				DLOG("updated autottl cache\n");
		}
		else if (ipc->hops)
			DLOG("using cached hops %u\n", ipc->hops);
		else
			DLOG("hop count unknown\n");
		if (ipc->hops)
		{
			ctrack->desync_autottl = autottl_guess(a6 ? &ctrack->dp->desync_autottl6 : &ctrack->dp->desync_autottl, ipc->hops, "desync");
			ctrack->orig_autottl = autottl_guess(a6 ? &ctrack->dp->orig_autottl6 : &ctrack->dp->orig_autottl, ipc->hops, "orig");
			ctrack->dup_autottl = autottl_guess(a6 ? &ctrack->dp->dup_autottl6 : &ctrack->dp->dup_autottl, ipc->hops, "dup");
		}
		ctrack->b_autottl_discovered = true;
	}
}
static void autottl_rediscover(t_ctrack *ctrack, const struct in_addr *a4, const struct in6_addr *a6, const char *iface)
{
	if (ctrack)
	{
		ctrack->b_autottl_discovered = false;
		autottl_discover(ctrack, a4, a6, iface);
	}
}

static bool ipcache_put_hostname(const struct in_addr *a4, const struct in6_addr *a6, const char *hostname, bool hostname_is_ip)
{
	if (!params.cache_hostname) return true;

	ip_cache_item *ipc = ipcacheTouch(&params.ipcache, a4, a6, NULL);
	if (!ipc)
	{
		DLOG_ERR("ipcache_put_hostname: out of memory\n");
		return false;
	}
	if (!ipc->hostname || strcmp(ipc->hostname, hostname))
	{
		free(ipc->hostname);
		if (!(ipc->hostname = strdup(hostname)))
		{
			DLOG_ERR("ipcache_put_hostname: out of memory\n");
			return false;
		}
		ipc->hostname_is_ip = hostname_is_ip;
		DLOG("hostname cached (is_ip=%u): %s\n", hostname_is_ip, hostname);
	}
	return true;
}
static bool ipcache_get_hostname(const struct in_addr *a4, const struct in6_addr *a6, char *hostname, size_t hostname_buf_len, bool *hostname_is_ip)
{
	if (!params.cache_hostname)
	{
		*hostname = 0;
		return true;
	}
	ip_cache_item *ipc = ipcacheTouch(&params.ipcache, a4, a6, NULL);
	if (!ipc)
	{
		DLOG_ERR("ipcache_get_hostname: out of memory\n");
		return false;
	}
	if (ipc->hostname)
	{
		DLOG("got cached hostname (is_ip=%u): %s\n", ipc->hostname_is_ip, ipc->hostname);
		snprintf(hostname, hostname_buf_len, "%s", ipc->hostname);
		if (hostname_is_ip) *hostname_is_ip = ipc->hostname_is_ip;
	}
	else
		*hostname = 0;
	return true;
}


static uint16_t IP4_IP_ID_FIX(const struct ip *ip, t_ip_id_mode mode)
{
	if (ip)
	{
		switch(mode)
		{
			case IPID_SEQ:
			case IPID_SEQ_GROUP:
				return ip->ip_id ? ip->ip_id : (uint16_t)random();
			case IPID_SAME:
				return ip->ip_id;
			case IPID_RND:
				return (uint16_t)(random()%0xFFFF + 1);
			default:
				break;
		}
	}
	return 0;
}
static uint16_t IP4_IP_ID_ADD(uint16_t ip_id, uint16_t inc, t_ip_id_mode mode)
{
	switch(mode)
	{
		case IPID_SEQ_GROUP:
		case IPID_SEQ:
			if (ip_id)
			{
				ip_id = net16_add(ip_id, inc);
				if (!ip_id) ip_id = net16_add(ip_id, ((int16_t)inc) < 0 ? -1 : 1); // do not allow zero
			}
		case IPID_SAME:
			return ip_id;
		case IPID_RND:
			return (uint16_t)(random()%0xFFFF + 1);;
		default:
			return 0;
	}
}
#define IP4_IP_ID_NEXT(ip_id,mode) IP4_IP_ID_ADD(ip_id,+1,mode)
#define IP4_IP_ID_PREV(ip_id,mode) IP4_IP_ID_ADD(ip_id,-1,mode)


// fake_mod buffer must at least sizeof(desync_profile->fake_tls)
// size does not change
// return : true - altered, false - not altered
static bool runtime_tls_mod(int fake_n, const struct fake_tls_mod_cache *modcache, const struct fake_tls_mod *tls_mod, const uint8_t *fake_data, size_t fake_data_size, const uint8_t *payload, size_t payload_len, uint8_t *fake_mod)
{
	bool b = false;
	if (modcache) // it's filled only if it's TLS
	{
		if (tls_mod->mod & FAKE_TLS_MOD_PADENCAP)
		{
			size_t sz_rec = pntoh16(fake_data + 3) + payload_len;
			size_t sz_handshake = pntoh24(fake_data + 6) + payload_len;
			size_t sz_ext = pntoh16(fake_data + modcache->extlen_offset) + payload_len;
			size_t sz_pad = pntoh16(fake_data + modcache->padlen_offset) + payload_len;
			if ((sz_rec & ~0xFFFF) || (sz_handshake & ~0xFFFFFF) || (sz_ext & ~0xFFFF) || (sz_pad & ~0xFFFF))
				DLOG("fake[%d] cannot apply padencap tls mod. length overflow.\n", fake_n);
			else
			{
				memcpy(fake_mod, fake_data, fake_data_size);
				phton16(fake_mod + 3, (uint16_t)sz_rec);
				phton24(fake_mod + 6, (uint32_t)sz_handshake);
				phton16(fake_mod + modcache->extlen_offset, (uint16_t)sz_ext);
				phton16(fake_mod + modcache->padlen_offset, (uint16_t)sz_pad);
				b = true;
				DLOG("fake[%d] applied padencap tls mod. sizes increased by %zu bytes.\n", fake_n, payload_len);
			}
		}
		if (tls_mod->mod & FAKE_TLS_MOD_RND)
		{
			if (!b)	memcpy(fake_mod, fake_data, fake_data_size);
			fill_random_bytes(fake_mod + 11, 32); // random
			fill_random_bytes(fake_mod + 44, fake_mod[43]); // session id
			b = true;
			DLOG("fake[%d] applied rnd tls mod\n", fake_n);
		}
		if (tls_mod->mod & FAKE_TLS_MOD_DUP_SID)
		{
			if (payload_len < 44)
				DLOG("fake[%d] cannot apply dupsid tls mod. data payload is too short.\n", fake_n);
			else if (fake_data[43] != payload[43])
				DLOG("fake[%d] cannot apply dupsid tls mod. fake and orig session id length mismatch : %u!=%u.\n", fake_n, fake_data[43], payload[43]);
			else if (payload_len < (44 + payload[43]))
				DLOG("fake[%d] cannot apply dupsid tls mod. data payload is not valid.\n", fake_n);
			else
			{
				if (!b)	memcpy(fake_mod, fake_data, fake_data_size);
				memcpy(fake_mod + 44, payload + 44, fake_mod[43]); // session id
				b = true;
				DLOG("fake[%d] applied dupsid tls mod\n", fake_n);
			}
		}
	}
	return b;
}

static bool rewrite_tcp_flags(uint16_t *flags, uint16_t unset, uint16_t set, const char *what)
{
	if (set || unset)
	{
		uint16_t fl_new = *flags & ~unset | set;
		if (fl_new!=*flags)
		{
			DLOG("rewrite %s tcp flags 0x%03X => 0x%03X\n", what, *flags, fl_new);
			*flags = fl_new;
			return true;
		}
	}
	return false;
}

static uint8_t orig_mod(const struct desync_profile *dp, const t_ctrack *ctrack, struct dissect *dis)
{
	uint8_t ttl, ttl_orig;
	bool bModded = false;

	if (check_orig_mod_interval(dp, ctrack))
	{
		ttl = (ctrack && ctrack->orig_autottl) ? ctrack->orig_autottl : dis->ip6 ? dp->orig_mod_ttl6 : dp->orig_mod_ttl;
		if (ttl)
		{
			ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;
			if (ttl_orig != ttl)
			{
				DLOG("rewrite original packet ttl %u => %u\n", ttl_orig, ttl);
				rewrite_ttl(dis->ip, dis->ip6, ttl);
				bModded = true;
			}
		}
		if (dis->tcp)
		{
			uint16_t flags = get_tcp_flags(dis->tcp);
			if (rewrite_tcp_flags(&flags, dp->orig_tcp_flags_unset, dp->orig_tcp_flags_set, "original"))
			{
				apply_tcp_flags(dis->tcp,flags);
				bModded = true;
			}
		}
	}
	return bModded;
}

static bool orig_send_rewrite(
	uint32_t fwmark, const char *ifout, const struct sockaddr *dst,
	uint8_t ttl_orig, uint8_t ttl_fake, const struct desync_profile *dp, const struct dissect *dis)
{
	unsigned int k;

	// here we avoid heavy ops and preserve exact tcp options structure

	if (ttl_fake == ttl_orig)
		DLOG("sending %u dups\n", dp->dup_repeats);
	else
		DLOG("sending %u dups with ttl rewrite %u => %u\n", dp->dup_repeats, ttl_orig, ttl_fake);
	rewrite_ttl(dis->ip, dis->ip6, ttl_fake);

	// send dups
	for (k = 0; k < dp->dup_repeats; k++)
	{
		if (!rawsend(dst, fwmark, ifout, dis->data_pkt, dis->len_pkt))
		{
			rewrite_ttl(dis->ip, dis->ip6, ttl_orig);
			return false;
		}
	}
	rewrite_ttl(dis->ip, dis->ip6, ttl_orig);
	return true;
}

// return : true - orig was sent completely, false - should send orig another way
static bool tcp_orig_send(uint8_t verdict, uint32_t fwmark, const char *ifout, const struct desync_profile *dp, const t_ctrack *ctrack, struct dissect *dis, bool bForceSend)
{
	if (dp->dup_repeats || bForceSend)
	{
		unsigned int k;
		uint8_t pkt[DPI_DESYNC_MAX_FAKE_LEN + 100];
		size_t len;
		uint16_t ip_id, nmss;
		struct sockaddr_storage src, dst;
		uint8_t ttl_orig, ttl_dup, scale_factor;
		uint16_t flags_dup;
		uint32_t *timestamps;
		bool sack, DF, bTF;

		extract_endpoints(dis->ip, dis->ip6, dis->tcp, NULL, &src, &dst);
		ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;

		verdict_tcp_csum_fix(verdict, dis->tcp, dis->transport_len, dis->ip, dis->ip6);

		if (dp->dup_repeats && check_dup_interval(dp, ctrack))
		{
			ttl_dup = (ctrack && ctrack->dup_autottl) ? ctrack->dup_autottl : (dis->ip6 ? (dp->dup_ttl6 ? dp->dup_ttl6 : ttl_orig) : (dp->dup_ttl ? dp->dup_ttl : ttl_orig));

			flags_dup = dis->tcp->th_flags;
			bTF = rewrite_tcp_flags(&flags_dup, dp->dup_tcp_flags_unset, dp->dup_tcp_flags_set, "dup");
			if (bTF || dp->dup_fooling_mode || (dis->ip && dp->dup_ip_id_mode!=IPID_SAME))
			{
				scale_factor = tcp_find_scale_factor(dis->tcp);
				timestamps = tcp_find_timestamps(dis->tcp);
				sack = tcp_has_sack(dis->tcp);
				nmss = tcp_find_mss(dis->tcp);
				ip_id = IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode);

				len = sizeof(pkt);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst,
					flags_dup, sack, nmss,
					dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					ip_has_df(dis->ip), ttl_dup, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					dp->dup_fooling_mode, dp->dup_ts_increment, dp->dup_badseq_increment, dp->dup_badseq_ack_increment,
					dis->data_payload, dis->len_payload, pkt, &len))
				{
					DLOG_ERR("dup: packet reconstruct failed\n");
					return false;
				}
				DLOG("sending %u dups with packet reconstruct. ttl %u => %u\n", dp->dup_repeats, ttl_orig, ttl_dup);

				// send dups
				for (k = 0; k < dp->dup_repeats; k++)
				{
					if (!rawsend((struct sockaddr *)&dst, fwmark, ifout, pkt, len))
						return false;
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->dup_ip_id_mode);
					if (dis->ip) ((struct ip*)pkt)->ip_id = ip_id;
				}
			}
			else
			{
				if (!orig_send_rewrite(fwmark, ifout, (struct sockaddr *)&dst, ttl_orig, ttl_dup, dp, dis))
					return false;
			}
			if (dp->dup_replace)
				DLOG("NOT sending original because of dup_replace\n");
			else
			{
				DLOG("sending original ttl %u\n", ttl_orig);
				if (!rawsend((struct sockaddr *)&dst, fwmark, ifout, dis->data_pkt, dis->len_pkt))
					return false;
			}
			return true;
		}
		if (bForceSend)
		{
			DLOG("sending original ttl %u\n", ttl_orig);
			if (!rawsend((struct sockaddr *)&dst, fwmark, ifout, dis->data_pkt, dis->len_pkt))
				return false;
			return true;
		}
	}
	return false;
}
// return : true - orig was sent completely, false - should send orig another way
static bool udp_orig_send(uint8_t verdict, uint32_t fwmark, const char *ifout, const struct desync_profile *dp, const t_ctrack *ctrack, struct dissect *dis, bool bForceSend)
{
	if (dp->dup_repeats || bForceSend)
	{
		unsigned int k;
		uint8_t pkt[DPI_DESYNC_MAX_FAKE_LEN + 100];
		size_t len;
		uint16_t ip_id;
		struct sockaddr_storage src, dst;
		uint8_t ttl_orig, ttl_fake;

		extract_endpoints(dis->ip, dis->ip6, NULL, dis->udp, &src, &dst);
		ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;

		verdict_udp_csum_fix(verdict, dis->udp, dis->transport_len, dis->ip, dis->ip6);

		if (dp->dup_repeats && check_dup_interval(dp, ctrack))
		{
			ttl_fake = (ctrack && ctrack->dup_autottl) ? ctrack->dup_autottl : (dis->ip6 ? (dp->dup_ttl6 ? dp->dup_ttl6 : ttl_orig) : (dp->dup_ttl ? dp->dup_ttl : ttl_orig));

			if (dp->dup_fooling_mode || (dis->ip && dp->dup_ip_id_mode!=IPID_SAME))
			{
				ip_id = IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode);

				len = sizeof(pkt);
				if (!prepare_udp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst,
					ip_has_df(dis->ip), ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					dp->dup_fooling_mode, NULL, 0, 0,
					dis->data_payload, dis->len_payload, pkt, &len))
				{
					DLOG_ERR("dup: packet reconstruct failed\n");
					return false;
				}

				DLOG("sending %u dups with packet reconstruct. ttl %u => %u\n", dp->dup_repeats, ttl_orig, ttl_fake);

				// send dups
				for (k = 0; k < dp->dup_repeats; k++)
				{
					if (!rawsend((struct sockaddr *)&dst, fwmark, ifout, pkt, len))
						return false;
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->dup_ip_id_mode);
					if (dis->ip) ((struct ip*)pkt)->ip_id = ip_id;
				}
			}
			else
			{
				if (!orig_send_rewrite(fwmark, ifout, (struct sockaddr *)&dst, ttl_orig, ttl_fake, dp, dis))
					return false;
			}
			if (dp->dup_replace)
				DLOG("NOT sending original because of dup_replace\n");
			else
			{
				DLOG("sending original ttl %u\n", ttl_orig);
				if (!rawsend((struct sockaddr *)&dst, fwmark, ifout, dis->data_pkt, dis->len_pkt))
					return false;
			}
			return true;
		}
		if (bForceSend)
		{
			DLOG("sending original ttl %u\n", ttl_orig);
			if (!rawsend((struct sockaddr *)&dst, fwmark, ifout, dis->data_pkt, dis->len_pkt))
				return false;
			return true;
		}
	}
	return false;
}

static uint8_t dpi_desync_tcp_packet_play(bool replay, size_t reasm_offset, uint32_t fwmark, const char *ifin, const char *ifout, struct dissect *dis)
{
	uint8_t verdict = VERDICT_PASS;

	// additional safety check
	if (!!dis->ip == !!dis->ip6) return verdict;

	struct desync_profile *dp = NULL;

	t_ctrack *ctrack = NULL, *ctrack_replay = NULL;
	bool bReverse = false;
	bool bFake = false;

	struct sockaddr_storage src, dst;
	uint8_t pkt1[DPI_DESYNC_MAX_FAKE_LEN + 100], pkt2[DPI_DESYNC_MAX_FAKE_LEN + 100], pkt3[DPI_DESYNC_MAX_FAKE_LEN + 100];
	size_t pkt1_len, pkt2_len, pkt3_len;
	uint8_t ttl_orig, ttl_fake, scale_factor;
	uint32_t *timestamps;
	bool bSack, DF;
	uint16_t nmss;
	char host[256];
	const char *ifname = NULL, *ssid = NULL;

	uint32_t desync_fwmark = fwmark | params.desync_fwmark;
	extract_endpoints(dis->ip, dis->ip6, dis->tcp, NULL, &src, &dst);
	timestamps = tcp_find_timestamps(dis->tcp);
	DF = ip_has_df(dis->ip);
	ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;

	if (replay)
	{
		// in replay mode conntrack_replay is not NULL and ctrack is NULL

		//ConntrackPoolDump(&params.conntrack);
		if (!ConntrackPoolDoubleSearch(&params.conntrack, dis->ip, dis->ip6, dis->tcp, NULL, &ctrack_replay, &bReverse) || bReverse)
			return verdict;

		ifname = bReverse ? ifin : ifout;
#ifdef HAS_FILTER_SSID
		ssid = wlan_ssid_search_ifname(ifname);
		if (ssid) DLOG("found ssid for %s : %s\n", ifname, ssid);
#endif
		dp = ctrack_replay->dp;
		if (dp)
			DLOG("using cached desync profile %d\n", dp->n);
		else if (!ctrack_replay->dp_search_complete)
		{
			dp = ctrack_replay->dp = dp_find(&params.desync_profiles, IPPROTO_TCP, (struct sockaddr *)&dst, ctrack_replay->hostname, ctrack_replay->hostname_is_ip, ctrack_replay->l7proto, ssid, NULL, NULL, NULL);
			ctrack_replay->dp_search_complete = true;
		}
		if (!dp)
		{
			DLOG("matching desync profile not found\n");
			return verdict;
		}
	}
	else
	{
		// in real mode ctrack may be NULL or not NULL, conntrack_replay is equal to ctrack

		if (!params.ctrack_disable)
		{
			ConntrackPoolPurge(&params.conntrack);
			if (ConntrackPoolFeed(&params.conntrack, dis->ip, dis->ip6, dis->tcp, NULL, dis->len_payload, &ctrack, &bReverse))
			{
				dp = ctrack->dp;
				ctrack_replay = ctrack;
			}
		}
		ifname = bReverse ? ifin : ifout;
#ifdef HAS_FILTER_SSID
		ssid = wlan_ssid_search_ifname(ifname);
		if (ssid) DLOG("found ssid for %s : %s\n", ifname, ssid);
#endif
		if (dp)
			DLOG("using cached desync profile %d\n", dp->n);
		else if (!ctrack || !ctrack->dp_search_complete)
		{
			const char *hostname = NULL;
			bool hostname_is_ip = false;
			if (ctrack)
			{
				hostname = ctrack->hostname;
				hostname_is_ip = ctrack->hostname_is_ip;
				if (!hostname && !bReverse)
				{
					if (ipcache_get_hostname(dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, host, sizeof(host), &hostname_is_ip) && *host)
						if (!(hostname = ctrack_replay->hostname = strdup(host)))
							DLOG_ERR("strdup(host): out of memory\n");
				}
			}
			dp = dp_find(&params.desync_profiles, IPPROTO_TCP, (struct sockaddr *)&dst, hostname, hostname_is_ip, ctrack ? ctrack->l7proto : UNKNOWN, ssid, NULL, NULL, NULL);
			if (ctrack)
			{
				ctrack->dp = dp;
				ctrack->dp_search_complete = true;
			}
		}
		if (!dp)
		{
			DLOG("matching desync profile not found\n");
			return verdict;
		}
		maybe_cutoff(ctrack, IPPROTO_TCP);

		HostFailPoolPurgeRateLimited(&dp->hostlist_auto_fail_counters);

		//ConntrackPoolDump(&params.conntrack);

		if (tcp_synack_segment(dis->tcp))
		{
			if (dp->wsize)
			{
				tcp_rewrite_winsize(dis->tcp, dp->wsize, dp->wscale);
				verdict = VERDICT_MODIFY;
			}
			if (dp->synack_split == SS_SYN)
			{
				DLOG("split SYNACK : clearing ACK bit\n");
				dis->tcp->th_flags &= ~TH_ACK;
				verdict = VERDICT_MODIFY;
			}
		}

		if (bReverse)
		{
			if (ctrack && !ctrack->incoming_ttl)
			{
				ctrack->incoming_ttl = ttl_orig;
				DLOG("incoming TTL %u\n", ttl_orig);
				autottl_rediscover(ctrack, dis->ip ? &dis->ip->ip_src : NULL, dis->ip6 ? &dis->ip6->ip6_src : NULL, ifin);
			}

			// process reply packets for auto hostlist mode
			// by looking at RSTs or HTTP replies we decide whether original request looks like DPI blocked
			// we only process first-sequence replies. do not react to subsequent redirects or RSTs
			if (ctrack && ctrack->hostname && ctrack->hostname_ah_check && (ctrack->ack_last - ctrack->ack0) == 1)
			{
				bool bFail = false;

				char client_ip_port[48];
				if (*params.hostlist_auto_debuglog)
					ntop46_port((struct sockaddr*)&dst, client_ip_port, sizeof(client_ip_port));
				else
					*client_ip_port = 0;

				if (dis->tcp->th_flags & TH_RST)
				{
					DLOG("incoming RST detected for hostname %s\n", ctrack->hostname);
					HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : incoming RST", ctrack->hostname, ctrack->dp->n, client_ip_port, l7proto_str(ctrack->l7proto));
					bFail = true;
				}
				else if (dis->len_payload && ctrack->l7proto == HTTP)
				{
					if (IsHttpReply(dis->data_payload, dis->len_payload))
					{
						DLOG("incoming HTTP reply detected for hostname %s\n", ctrack->hostname);
						bFail = HttpReplyLooksLikeDPIRedirect(dis->data_payload, dis->len_payload, ctrack->hostname);
						if (bFail)
						{
							DLOG("redirect to another domain detected. possibly DPI redirect.\n");
							HOSTLIST_DEBUGLOG_APPEND("%s : profile %d : client %s : proto %s : redirect to another domain", ctrack->hostname, ctrack->dp->n, client_ip_port, l7proto_str(ctrack->l7proto));
						}
						else
							DLOG("local or in-domain redirect detected. it's not a DPI redirect.\n");
					}
					else
					{
						// received not http reply. do not monitor this connection anymore
						DLOG("incoming unknown HTTP data detected for hostname %s\n", ctrack->hostname);
					}
				}
				if (bFail)
					auto_hostlist_failed(dp, ctrack->hostname, ctrack->hostname_is_ip, client_ip_port, ctrack->l7proto);
				else
					if (dis->len_payload)
						auto_hostlist_reset_fail_counter(dp, ctrack->hostname, client_ip_port, ctrack->l7proto);
				if (dis->tcp->th_flags & TH_RST)
					ConntrackClearHostname(ctrack); // do not react to further dup RSTs
			}

			return verdict; // nothing to do. do not waste cpu
		}

		autottl_discover(ctrack, dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, ifout);

		if (orig_mod(dp, ctrack, dis)) // ttl can change !
			verdict = VERDICT_MODIFY;

		if (dp->wssize)
		{
			if (ctrack)
			{
				if (ctrack->b_wssize_cutoff)
				{
					DLOG("wssize-cutoff reached (mode %c): %llu/%u . not changing wssize.\n", dp->wssize_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->wssize_cutoff_mode), dp->wssize_cutoff);
				}
				else
				{
					if (dp->wssize_cutoff) DLOG("wssize-cutoff not reached (mode %c): %llu/%u\n", dp->wssize_cutoff_mode, (unsigned long long)cutoff_get_limit(ctrack, dp->wssize_cutoff_mode), dp->wssize_cutoff);
					tcp_rewrite_winsize(dis->tcp, dp->wssize, dp->wsscale);
					verdict = VERDICT_MODIFY;
				}
			}
			else
			{
				DLOG("not changing wssize. wssize is set but conntrack entry is missing\n");
			}
		}

		if ((dp->synack_split == SS_SYNACK || dp->synack_split == SS_ACKSYN) && tcp_synack_segment(dis->tcp))
		{
			// reconstruct required

			dis->tcp->th_flags &= ~TH_ACK;
			tcp_fix_checksum(dis->tcp, dis->transport_len, dis->ip, dis->ip6);

			char ss[2], i;
			if (dp->synack_split == SS_SYNACK)
			{
				ss[0] = 'S';
				ss[1] = 'A';
			}
			else
			{
				ss[0] = 'A';
				ss[1] = 'S';
			}
			pkt1_len = sizeof(pkt1);
			if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, TH_ACK, false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, SCALE_NONE, timestamps,
				DF, ttl_orig, IP4_TOS(dis->ip), IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode), IP6_FLOW(dis->ip6),
				FOOL_NONE, 0, 0, 0, NULL, 0, pkt1, &pkt1_len))
			{
				DLOG_ERR("cannot prepare split SYNACK ACK part\n");
				goto send_orig;
			}
			for (int i = 0; i < 2; i++)
			{
				switch (ss[i])
				{
				case 'S':
					DLOG("split SYNACK : SYN\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, dis->data_pkt, dis->len_pkt))
						goto send_orig;
					break;
				case 'A':
					DLOG("split SYNACK : ACK\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
						goto send_orig;
					break;
				}
			}
			return VERDICT_DROP;
		}

		// start and cutoff limiters
		if (!process_desync_interval(dp, ctrack)) goto send_orig;
	} // !replay

#ifdef __APPLE__
	if (!replay && ctrack && !bReverse && dis->len_payload && !ctrack->req_seq_present && ReasmIsEmpty(&ctrack->reasm_orig))
	{
		uint32_t expected = ctrack->seq0 + 1;
		uint32_t gap = ntohl(dis->tcp->th_seq) - expected;
		if ((ctrack->pdcounter_orig == 1 || ctrack->delayed_first_gap) && gap && gap < TCP_MAX_REASM)
		{
			verdict_tcp_csum_fix(verdict, dis->tcp, dis->transport_len, dis->ip, dis->ip6);
			if (rawpacket_queue(&ctrack->delayed, &dst, desync_fwmark, ifin, ifout, dis->data_pkt, dis->len_pkt, dis->len_payload))
			{
				ctrack->delayed_first_gap = true;
				DLOG("DELAY first tcp data gap +%u\n", gap);
				return VERDICT_DROP;
			}
		}
	}
#endif

	ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;
	ttl_fake = (ctrack_replay && ctrack_replay->desync_autottl) ? ctrack_replay->desync_autottl : (dis->ip6 ? (dp->desync_ttl6 ? dp->desync_ttl6 : ttl_orig) : (dp->desync_ttl ? dp->desync_ttl : ttl_orig));
	uint16_t flags_orig = get_tcp_flags(dis->tcp);
	scale_factor = tcp_find_scale_factor(dis->tcp);
	bSack = tcp_has_sack(dis->tcp);
	nmss = tcp_find_mss(dis->tcp);

	uint16_t ip_id=0;
	if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;
	if (!ip_id) ip_id = IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode);

	if (!replay)
	{
		if (tcp_syn_segment(dis->tcp))
		{
			switch (dp->desync_mode0)
			{
			case DESYNC_SYNACK:
				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, TH_SYN | TH_ACK, false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					NULL, 0, pkt1, &pkt1_len))
				{
					goto send_orig;
				}
				DLOG("sending fake SYNACK\n");
				if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;
				break;
			case DESYNC_SYNDATA:
				// make sure we are not breaking TCP fast open
				if (tcp_has_fastopen(dis->tcp))
				{
					DLOG("received SYN with TCP fast open option. syndata desync is not applied.\n");
					break;
				}
				if (dis->len_payload)
				{
					DLOG("received SYN with data payload. syndata desync is not applied.\n");
					break;
				}
				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, bSack, nmss, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					0, 0, 0, 0, dp->fake_syndata, dp->fake_syndata_size, pkt1, &pkt1_len))
				{
					goto send_orig;
				}
				ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending SYN with fake data : ");
				hexdump_limited_dlog(dp->fake_syndata, dp->fake_syndata_size, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;
				verdict = VERDICT_DROP;
				break;
			default:
				break;
			}
			// can do nothing else with SYN packet
			goto send_orig;
		}

	} // !replay

	if (!(dis->tcp->th_flags & TH_SYN) && dis->len_payload)
	{
		struct blob_collection_head *fake;

		uint8_t *p, *phost = NULL;
		const uint8_t *rdata_payload = dis->data_payload;
		size_t rlen_payload = dis->len_payload;
		size_t split_pos, seqovl_pos;
		size_t multisplit_pos[MAX_SPLITS];
		int multisplit_count;
		int i;

		bool bHaveHost = false, bHostIsIp = false;
		t_l7proto l7proto = UNKNOWN;

		if (replay)
		{
			rdata_payload = ctrack_replay->reasm_orig.packet;
			rlen_payload = ctrack_replay->reasm_orig.size_present;
		}
		else if (reasm_orig_feed(ctrack, IPPROTO_TCP, dis->data_payload, dis->len_payload))
		{
			rdata_payload = ctrack->reasm_orig.packet;
			rlen_payload = ctrack->reasm_orig.size_present;
		}

		process_retrans_fail(ctrack, IPPROTO_TCP, (struct sockaddr*)&src);

		if (IsHttp(rdata_payload, rlen_payload))
		{
			DLOG("packet contains HTTP request\n");
			l7proto = HTTP;
			if (ctrack && ctrack->l7proto == UNKNOWN) ctrack->l7proto = l7proto;

			// we do not reassemble http
			reasm_orig_cancel(ctrack);
			if (!dp->wssize_no_forced_cutoff) forced_wssize_cutoff(ctrack);

			bHaveHost = HttpExtractHost(rdata_payload, rlen_payload, host, sizeof(host));
			if (!bHaveHost)
			{
				DLOG("not applying tampering to HTTP without Host:\n");
				goto send_orig;
			}
			if (ctrack)
			{
				// we do not reassemble http
				if (!ctrack->req_seq_present)
				{
					ctrack->req_seq_start = ctrack->seq_last;
					ctrack->req_seq_end = ctrack->pos_orig - 1;
					ctrack->req_seq_present = ctrack->req_seq_finalized = true;
					DLOG("req retrans : tcp seq interval %u-%u\n", ctrack->req_seq_start, ctrack->req_seq_end);
				}
			}
		}
		else if (IsTLSClientHello(rdata_payload, rlen_payload, TLS_PARTIALS_ENABLE))
		{
			bool bReqFull = IsTLSRecordFull(rdata_payload, rlen_payload);
			bool bFakeCanRunPartial;
			DLOG(bReqFull ? "packet contains full TLS ClientHello\n" : "packet contains partial TLS ClientHello\n");
			l7proto = TLS;

			if (bReqFull) TLSDebug(rdata_payload, rlen_payload);

			bHaveHost = TLSHelloExtractHost(rdata_payload, rlen_payload, host, sizeof(host), TLS_PARTIALS_ENABLE);
			bFakeCanRunPartial = (bHaveHost || (!dp->desync_skip_nosni && PROFILE_HOSTLISTS_EMPTY(dp))) &&
				dp->desync_mode == DESYNC_FAKE && dp->desync_mode2 == DESYNC_NONE;

			if (ctrack)
			{
				if (!ctrack->l7proto) ctrack->l7proto = l7proto;
				// do not reasm retransmissions
				if (!bReqFull && !bFakeCanRunPartial && ReasmIsEmpty(&ctrack->reasm_orig) && !ctrack->req_seq_abandoned &&
					!(ctrack->req_seq_finalized && seq_within(ctrack->seq_last, ctrack->req_seq_start, ctrack->req_seq_end)))
				{
					// do not reconstruct unexpected large payload (they are feeding garbage ?)
					if (!reasm_orig_start(ctrack, IPPROTO_TCP, TLSRecordLen(dis->data_payload), TCP_MAX_REASM, dis->data_payload, dis->len_payload))
					{
						reasm_orig_cancel(ctrack);
						goto send_orig;
					}
				}
				if (!ctrack->req_seq_finalized)
				{
					if (!ctrack->req_seq_present)
					{
						// lower bound of request seq interval
						ctrack->req_seq_start = ctrack->seq_last;
						ctrack->req_seq_present = true;
					}
					// upper bound of request seq interval
					// it can grow on every packet until request is complete. then interval is finalized and never touched again.
					ctrack->req_seq_end = ctrack->pos_orig - 1;
					DLOG("req retrans : seq interval %u-%u\n", ctrack->req_seq_start, ctrack->req_seq_end);
					ctrack->req_seq_finalized |= bReqFull;
				}
				if (!dp->wssize_no_forced_cutoff && (bReqFull || ReasmIsEmpty(&ctrack->reasm_orig))) forced_wssize_cutoff(ctrack);

				if (!ReasmIsEmpty(&ctrack->reasm_orig))
				{
					verdict_tcp_csum_fix(verdict, dis->tcp, dis->transport_len, dis->ip, dis->ip6);
					struct rawpacket *queued;
#ifdef __APPLE__
					if (ctrack->delayed_first_gap)
						queued = rawpacket_queue_head(&ctrack->delayed, &dst, desync_fwmark, ifin, ifout, dis->data_pkt, dis->len_pkt, dis->len_payload);
					else
#endif
						queued = rawpacket_queue(&ctrack->delayed, &dst, desync_fwmark, ifin, ifout, dis->data_pkt, dis->len_pkt, dis->len_payload);
					if (queued)
					{
						DLOG("DELAY desync until reasm is complete (#%u)\n", rawpacket_queue_count(&ctrack->delayed));
					}
					else
					{
						DLOG_ERR("rawpacket_queue failed !\n");
						reasm_orig_cancel(ctrack);
						goto send_orig;
					}
#ifdef __APPLE__
					if (ctrack->delayed_first_gap)
						reasm_orig_feed_delayed(ctrack);
#endif
					if (ReasmIsFull(&ctrack->reasm_orig))
					{
						struct rawpacket_tailhead replay;
						rawpacket_queue_init(&replay);
						TAILQ_CONCAT(&replay, &ctrack->delayed, next);
						replay_queue(&replay);
						reasm_orig_fin(ctrack);
					}
					return VERDICT_DROP;
				}
			}

			if (dp->desync_skip_nosni && !bHaveHost)
			{
				DLOG("not applying tampering to TLS ClientHello without hostname in the SNI\n");
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
		}

		if (ctrack && ctrack->req_seq_finalized)
		{
			uint32_t dseq = ctrack->seq_last - ctrack->req_seq_end;
			// do not react to 32-bit overflowed sequence numbers. allow 16 Mb grace window then cutoff.
			if (dseq >= 0x1000000 && !(dseq & 0x80000000)) ctrack->req_seq_abandoned = true;
		}

		if (bHaveHost)
		{
			bHostIsIp = strip_host_to_ip(host);
			DLOG("hostname: %s\n", host);
		}

		bool bDiscoveredL7;
		if (ctrack_replay)
		{
			if ((bDiscoveredL7 = !ctrack_replay->l7proto_discovered && ctrack_replay->l7proto != UNKNOWN))
				ctrack_replay->l7proto_discovered = true;
		}
		else
			bDiscoveredL7 = !ctrack_replay && l7proto != UNKNOWN;
		if (bDiscoveredL7) DLOG("discovered l7 protocol\n");

		bool bDiscoveredHostname = bHaveHost && !(ctrack_replay && ctrack_replay->hostname_discovered);
		if (bDiscoveredHostname)
		{
			DLOG("discovered hostname\n");
			if (ctrack_replay)
			{
				free(ctrack_replay->hostname);
				ctrack_replay->hostname = strdup(host);
				ctrack_replay->hostname_is_ip = bHostIsIp;
				if (!ctrack_replay->hostname)
				{
					DLOG_ERR("hostname dup : out of memory");
					reasm_orig_cancel(ctrack);
					goto send_orig;
				}
				ctrack_replay->hostname_discovered = true;
				if (!ipcache_put_hostname(dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, host, bHostIsIp))
				{
					reasm_orig_cancel(ctrack);
					goto send_orig;
				}

			}
		}

		bool bCheckDone = false, bCheckResult = false, bCheckExcluded = false;
		if (bDiscoveredL7 || bDiscoveredHostname)
		{
			struct desync_profile *dp_prev = dp;

			dp = dp_find(&params.desync_profiles, IPPROTO_TCP, (struct sockaddr *)&dst,
				ctrack_replay ? ctrack_replay->hostname : bHaveHost ? host : NULL,
				ctrack_replay ? ctrack_replay->hostname_is_ip : bHostIsIp,
				ctrack_replay ? ctrack_replay->l7proto : l7proto, ssid,
				&bCheckDone, &bCheckResult, &bCheckExcluded);
			if (ctrack_replay)
			{
				ctrack_replay->dp = dp;
				ctrack_replay->dp_search_complete = true;
				ctrack_replay->bCheckDone = bCheckDone;
				ctrack_replay->bCheckResult = bCheckResult;
				ctrack_replay->bCheckExcluded = bCheckExcluded;
			}
			if (!dp)
			{
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
			if (dp != dp_prev)
			{
				DLOG("desync profile changed by revealed l7 protocol or hostname !\n");
				autottl_rediscover(ctrack_replay, dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, ifout);
				ip_id = IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode);
				// re-evaluate start/cutoff limiters
				if (replay)
				{
					if (orig_mod(dp, ctrack_replay, dis)) // ttl can change !
						verdict = VERDICT_MODIFY;
				}
				else
				{
					maybe_cutoff(ctrack, IPPROTO_TCP);
					if (orig_mod(dp, ctrack, dis)) // ttl can change !
						verdict = VERDICT_MODIFY;
					if (!process_desync_interval(dp, ctrack))
					{
						reasm_orig_cancel(ctrack);
						goto send_orig;
					}
				}
				ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;
				ttl_fake = (ctrack_replay && ctrack_replay->desync_autottl) ? ctrack_replay->desync_autottl : (dis->ip6 ? (dp->desync_ttl6 ? dp->desync_ttl6 : ttl_orig) : (dp->desync_ttl ? dp->desync_ttl : ttl_orig));
			}
		}
		else if (ctrack_replay)
		{
			bCheckDone = ctrack_replay->bCheckDone;
			bCheckResult = ctrack_replay->bCheckResult;
			bCheckExcluded = ctrack_replay->bCheckExcluded;
		}

		if (bHaveHost && !PROFILE_HOSTLISTS_EMPTY(dp))
		{
			if (!bCheckDone)
				bCheckResult = HostlistCheck(dp, host, bHostIsIp, &bCheckExcluded, false);
			if (bCheckResult)
				ctrack_stop_retrans_counter(ctrack_replay);
			else
			{
				if (ctrack_replay)
				{
					ctrack_replay->hostname_ah_check = dp->hostlist_auto && !bCheckExcluded;
					if (!ctrack_replay->hostname_ah_check)
						ctrack_stop_retrans_counter(ctrack_replay);
				}
				DLOG("not applying tampering to this request\n");
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
		}

		if (l7proto == UNKNOWN)
		{
			if (!dp->desync_any_proto)
			{
				DLOG("not applying tampering to unknown protocol\n");
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
			DLOG("applying tampering to unknown protocol\n");
		}

		if ((l7proto == HTTP) && (dp->hostcase || dp->hostnospace || dp->domcase || dp->methodeol) && HttpFindHost(&phost, dis->data_payload, dis->len_payload))
		{
			if (dp->hostcase)
			{
				DLOG("modifying Host: => %c%c%c%c:\n", dp->hostspell[0], dp->hostspell[1], dp->hostspell[2], dp->hostspell[3]);
				memcpy(phost, dp->hostspell, 4);
				verdict = VERDICT_MODIFY;
			}
			if (dp->domcase)
			{
				DLOG("mixing domain case\n");
				for (p = phost + 5; p < (dis->data_payload + dis->len_payload) && *p != '\r' && *p != '\n'; p++)
					*p = (((size_t)p) & 1) ? tolower(*p) : toupper(*p);
				verdict = VERDICT_MODIFY;
			}
			uint8_t *pua;
			if (dp->hostnospace)
			{
				if ((pua = (uint8_t*)memmem(dis->data_payload, dis->len_payload, "\r\nUser-Agent: ", 14)) &&
					(pua = (uint8_t*)memmem(pua + 1, dis->len_payload - (pua - dis->data_payload) - 1, "\r\n", 2)))
				{
					DLOG("removing space after Host: and adding it to User-Agent:\n");
					if (pua > phost)
					{
						memmove(phost + 5, phost + 6, pua - phost - 6);
						pua[-1] = ' ';
					}
					else
					{
						memmove(pua + 1, pua, phost - pua + 5);
						*pua = ' ';
					}
					verdict = VERDICT_MODIFY;
				}
				else
					DLOG("cannot do hostnospace because valid User-Agent: not found\n");
			}
			else if (dp->methodeol)
			{
				if (phost[5] == ' ' || phost[5] == '\t')
				{
					DLOG("removing space after Host: and adding '\\n' before method\n");
					memmove(dis->data_payload + 1, dis->data_payload, phost - dis->data_payload + 5);
					dis->data_payload[0] = '\n';
					verdict = VERDICT_MODIFY;
				}
				else
					DLOG("cannot do methodeol because there's no space or tab after Host:\n");
			}

		}

		if (dp->desync_mode == DESYNC_NONE)
		{
			reasm_orig_cancel(ctrack);
			goto send_orig;
		}

		if (params.debug)
		{
			char s1[48], s2[48];
			ntop46_port((struct sockaddr *)&src, s1, sizeof(s1));
			ntop46_port((struct sockaddr *)&dst, s2, sizeof(s2));
			DLOG("dpi desync src=%s dst=%s\n", s1, s2);
		}

		switch (l7proto)
		{
		case HTTP:
			fake = &dp->fake_http;
			break;
		case TLS:
			fake = &dp->fake_tls;
			break;
		default:
			fake = &dp->fake_unknown;
			break;
		}
		if (dp->desync_mode == DESYNC_MULTISPLIT || dp->desync_mode == DESYNC_MULTIDISORDER || dp->desync_mode2 == DESYNC_MULTISPLIT || dp->desync_mode2 == DESYNC_MULTIDISORDER)
		{
			split_pos = 0;
			ResolveMultiPos(rdata_payload, rlen_payload, l7proto, dp->splits, dp->split_count, multisplit_pos, &multisplit_count);
			if (params.debug)
			{
				if (multisplit_count)
				{
					DLOG("multisplit pos: ");
					for (i = 0; i < multisplit_count; i++) DLOG("%zu ", multisplit_pos[i]);
					DLOG("\n");
				}
				else
					DLOG("all multisplit pos are outside of this packet\n");
			}
			if (multisplit_count)
			{
				int j;
				for (i = j = 0; i < multisplit_count; i++)
				{
					multisplit_pos[j] = pos_normalize(multisplit_pos[i], reasm_offset, dis->len_payload);
					if (multisplit_pos[j]) j++;
				}
				multisplit_count = j;
				if (params.debug)
				{
					if (multisplit_count)
					{
						DLOG("normalized multisplit pos: ");
						for (i = 0; i < multisplit_count; i++) DLOG("%zu ", multisplit_pos[i]);
						DLOG("\n");
					}
					else
						DLOG("all multisplit pos are outside of this packet\n");
				}
			}
		}
		else if (dp->desync_mode == DESYNC_FAKEDSPLIT || dp->desync_mode == DESYNC_FAKEDDISORDER || dp->desync_mode2 == DESYNC_FAKEDSPLIT || dp->desync_mode2 == DESYNC_FAKEDDISORDER)
		{
			multisplit_count = 0;
			// first look for non-abs split
			for (i = 0, split_pos = 0; i < dp->split_count && !split_pos; i++)
				if (dp->splits[i].marker != PM_ABS)
					split_pos = ResolvePos(rdata_payload, rlen_payload, l7proto, dp->splits + i);
			// second look for abs split
			if (!split_pos)
				for (i = 0, split_pos = 0; i < dp->split_count && !split_pos; i++)
					if (dp->splits[i].marker == PM_ABS)
						split_pos = ResolvePos(rdata_payload, rlen_payload, l7proto, dp->splits + i);
			if (!split_pos) split_pos = 1;
			DLOG("regular split pos: %zu\n", split_pos);
			if (!split_pos || split_pos > rlen_payload) split_pos = 1;
			split_pos = pos_normalize(split_pos, reasm_offset, dis->len_payload);
			if (split_pos)
				DLOG("normalized regular split pos : %zu\n", split_pos);
			else
				DLOG("regular split pos is outside of this packet\n");
		}
		else if (dp->desync_mode == DESYNC_HOSTFAKESPLIT || dp->desync_mode2 == DESYNC_HOSTFAKESPLIT)
		{
			struct proto_pos splits[2] = {
				{.marker = PM_HOST,.pos = 0},
				{.marker = PM_HOST_END,.pos = 0}
			};
			split_pos = 0;
			ResolveMultiPos(rdata_payload, rlen_payload, l7proto, splits, 2, multisplit_pos, &multisplit_count);
			if (multisplit_count != 2)
			{
				DLOG("hostfakesplit: host and endhost positions not found\n");
				multisplit_count = 0;
			}
			else
			{
				int j;
				for (i = j = 0; i < multisplit_count; i++)
				{
					multisplit_pos[j] = pos_normalize(multisplit_pos[i], reasm_offset, dis->len_payload);
					if (multisplit_pos[j]) j++;
				}
				multisplit_count = j;
				if (multisplit_count != 2)
				{
					DLOG("hostfakesplit: host or endhost are outside of this packet\n");
					multisplit_count = 0;
				}
				else
				{
					DLOG("normalized hostfakesplit pos: ");
					for (i = 0; i < multisplit_count; i++) DLOG("%zu ", multisplit_pos[i]);
					DLOG("\n");
					multisplit_pos[2] = ResolvePos(rdata_payload, rlen_payload, l7proto, &dp->hostfakesplit_midhost);
					if (multisplit_pos[2])
					{
						multisplit_pos[2] = pos_normalize(multisplit_pos[2], reasm_offset, dis->len_payload);
						if (multisplit_pos[2] > multisplit_pos[0] && multisplit_pos[2] < multisplit_pos[1])
						{
							DLOG("normalized hostfakesplit midhost pos: %zu\n", multisplit_pos[2]);
							multisplit_count++;
						}
					}
				}
			}
		}
		else
		{
			multisplit_count = 0;
			split_pos = 0;
		}
		if (dp->desync_mode == DESYNC_FAKEDSPLIT || dp->desync_mode == DESYNC_MULTISPLIT || dp->desync_mode2 == DESYNC_FAKEDSPLIT || dp->desync_mode2 == DESYNC_MULTISPLIT)
		{
			// split seqovl only uses absolute positive values
			seqovl_pos = (dp->seqovl.marker == PM_ABS && dp->seqovl.pos > 0) ? dp->seqovl.pos : 0;
			if (seqovl_pos)	DLOG("seqovl : %zu\n", seqovl_pos);
		}
		else if (dp->desync_mode == DESYNC_FAKEDDISORDER || dp->desync_mode == DESYNC_MULTIDISORDER || dp->desync_mode2 == DESYNC_FAKEDDISORDER || dp->desync_mode2 == DESYNC_MULTIDISORDER)
		{
			seqovl_pos = ResolvePos(rdata_payload, rlen_payload, l7proto, &dp->seqovl);
			seqovl_pos = pos_normalize(seqovl_pos, reasm_offset, dis->len_payload);
			if (seqovl_pos)	DLOG("normalized seqovl : %zu\n", seqovl_pos);
		}
		else
			seqovl_pos = 0;

		uint32_t fooling_orig = FOOL_NONE;

		uint16_t flags_fake = flags_orig;
		rewrite_tcp_flags(&flags_fake, dp->desync_tcp_flags_unset, dp->desync_tcp_flags_set, "desync");

		switch (dp->desync_mode)
		{
		case DESYNC_FAKE_KNOWN:
			if (reasm_offset) break;
			if (l7proto == UNKNOWN)
			{
				DLOG("not applying fake because of unknown protocol\n");
				break;
			}
		case DESYNC_FAKE:
			if (reasm_offset) break;

			{
				struct blob_item *fake_item;
				size_t fake_size;
				uint8_t *fake_data;
				uint8_t fake_data_buf[FAKE_MAX_TCP];
				int n = 0;
				uint32_t sequence, sequence0;

				sequence = sequence0 = ntohl(dis->tcp->th_seq);
				LIST_FOREACH(fake_item, fake, next)
				{
					n++;
					switch (l7proto)
					{
					case TLS:
						if ((fake_item->size <= sizeof(fake_data_buf)) &&
							runtime_tls_mod(n, (struct fake_tls_mod_cache *)fake_item->extra, (struct fake_tls_mod *)fake_item->extra2, fake_item->data, fake_item->size, rdata_payload, rlen_payload, fake_data_buf))
						{
							fake_data = fake_data_buf;
							break;
						}
					default:
						fake_data = fake_item->data;
					}
					fake_data += fake_item->offset;
					fake_size = fake_item->size - fake_item->offset;

					pkt1_len = sizeof(pkt1);
					if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_fake, false, 0, htonl(sequence), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
						DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
						dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
						fake_data, fake_size, pkt1, &pkt1_len))
					{
						reasm_orig_cancel(ctrack);
						goto send_orig;
					}
					DLOG("sending fake[%d] seq=+%u : ", n, sequence - sequence0);
					hexdump_limited_dlog(fake_data, fake_size, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					{
						reasm_orig_cancel(ctrack);
						goto send_orig;
					}
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					if (dp->tcp_mod.seq) sequence += fake_size;
				}
			}
			bFake = true;
			break;
		case DESYNC_RST:
		case DESYNC_RSTACK:
			if (reasm_offset) break;
			pkt1_len = sizeof(pkt1);
			if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, TH_RST | (dp->desync_mode == DESYNC_RSTACK ? TH_ACK : 0), false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
				DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
				dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
				NULL, 0, pkt1, &pkt1_len))
			{
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
			DLOG("sending fake RST/RSTACK\n");
			if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
			{
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
			ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
			bFake = true;
			break;
		case DESYNC_HOPBYHOP:
		case DESYNC_DESTOPT:
		case DESYNC_IPFRAG1:
			fooling_orig = (dp->desync_mode == DESYNC_HOPBYHOP) ? FOOL_HOPBYHOP : (dp->desync_mode == DESYNC_DESTOPT) ? FOOL_DESTOPT : FOOL_IPFRAG1;
			if (dis->ip6 && (dp->desync_mode2 == DESYNC_NONE || !desync_valid_second_stage_tcp(dp->desync_mode2) ||
				(!split_pos && (dp->desync_mode2 == DESYNC_FAKEDSPLIT || dp->desync_mode2 == DESYNC_FAKEDDISORDER)) ||
				(multisplit_count < 2 && dp->desync_mode2 == DESYNC_HOSTFAKESPLIT) ||
				(!multisplit_count && (dp->desync_mode2 == DESYNC_MULTISPLIT || dp->desync_mode2 == DESYNC_MULTIDISORDER))))
			{
				reasm_orig_cancel(ctrack);
				rdata_payload = NULL;

				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, 0, 0, IP6_FLOW(dis->ip6),
					fooling_orig, 0, 0, 0,
					dis->data_payload, dis->len_payload, pkt1, &pkt1_len))
				{
					goto send_orig;
				}
				DLOG("resending original packet with extension header\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;
				// this mode is final, no other options available
				return VERDICT_DROP;
			}
		default:
			pkt1_len = 0;
			break;
		}

		// we do not need reasm buffer anymore
		reasm_orig_cancel(ctrack);
		rdata_payload = NULL;

		enum dpi_desync_mode desync_mode = dp->desync_mode2 == DESYNC_NONE ? dp->desync_mode : dp->desync_mode2;
		switch (desync_mode)
		{
		case DESYNC_HOSTFAKESPLIT:
			// can be 2 or 3 split pos
			// if 2 split pos : host, endhost
			// if 3 split pos : host, endhost, midhost
			if (multisplit_count >= 2)
			{
				uint8_t *seg;
				size_t seg_len, host_size, pos_host, pos_endhost, pos_split_host, sz;
				uint8_t *fakehost;
				uint16_t ip_id_after_host;

				seg = dis->data_payload;
				seg_len = dis->len_payload;
				pos_host = multisplit_pos[0];
				pos_endhost = multisplit_pos[1];
				pos_split_host = multisplit_count >= 3 ? multisplit_pos[2] : 0;
				host_size = pos_endhost - pos_host;

				if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;

				// before_host segment
				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0,
					dis->tcp->th_seq, dis->tcp->th_ack,
					dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					fooling_orig, 0, 0, 0,
					seg, pos_host, pkt1, &pkt1_len))
					goto send_orig;
				ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending hostfakesplit before_host part 0-%zu len=%zu : ", pos_host - 1, pos_host);
				hexdump_limited_dlog(seg, pos_host, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;

				if (!(fakehost = malloc(host_size + 1)))
				{
					DLOG("fakehost out of memory\n");
					goto send_orig;
				}
				if (*dp->hfs_mod.host)
				{
					if (host_size <= dp->hfs_mod.host_size)
					{
						// "google.com" => "gle.com"
						// "google.com" => "google.com"
						memcpy(fakehost, dp->hfs_mod.host + dp->hfs_mod.host_size - host_size, host_size);
					}
					else
					{
						// "google.com" => "nb4auv9.google.com"
						// "google.com" => ".google.com"
						sz = host_size - dp->hfs_mod.host_size;
						memcpy(fakehost + sz, dp->hfs_mod.host, dp->hfs_mod.host_size);
						fakehost[--sz] = '.';
						if (sz)
						{
							fill_random_az(fakehost, 1);
							sz--;
						}
						fill_random_az09(fakehost + 1, sz);
					}
				}
				else
				{
					fill_random_az(fakehost, 1);
					fill_random_az09(fakehost + 1, host_size - 1);
					if (host_size >= 7)
					{
						fakehost[host_size - 4] = '.';
						memcpy(fakehost + host_size - 3, tld[random() % (sizeof(tld) / sizeof(*tld))], 3);
					}
				}
				fakehost[host_size] = 0;
				DLOG("generated fake host: %s\n", fakehost);

				// pkt2: fake_host segment
				pkt2_len = sizeof(pkt2);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_fake, false, 0,
					net32_add(dis->tcp->th_seq, pos_host), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					fakehost, host_size, pkt2, &pkt2_len))
					goto send_orig_clean;
				if (dp->ip_id_mode!=IPID_SEQ_GROUP) ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending hostfakesplit fake host %zu-%zu len=%zu : ", pos_host, pos_endhost - 1, host_size);
				hexdump_limited_dlog(fakehost, host_size, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt2, pkt2_len))
					goto send_orig_clean;

				ip_id_after_host = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				if (pos_split_host) ip_id_after_host = IP4_IP_ID_NEXT(ip_id_after_host,dp->ip_id_mode);

				// pkt3: after_host segment
				pkt3_len = sizeof(pkt3);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0,
					net32_add(dis->tcp->th_seq, pos_endhost), dis->tcp->th_ack,
					dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id_after_host, IP6_FLOW(dis->ip6),
					fooling_orig, 0, 0, 0,
					seg + pos_endhost, seg_len - pos_endhost, pkt3, &pkt3_len))
					goto send_orig_clean;

				if (dp->hfs_mod.ordering == 1)
				{
					DLOG("sending hostfakesplit after_host part %zu-%zu len=%zu : ", pos_endhost, seg_len - 1, seg_len - pos_endhost);
					hexdump_limited_dlog(seg + pos_endhost, seg_len - pos_endhost, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt3, pkt3_len))
						goto send_orig_clean;
				}

				sz = pos_split_host ? pos_split_host - pos_host : host_size;
				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0,
					net32_add(dis->tcp->th_seq, pos_host), dis->tcp->th_ack,
					dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					fooling_orig, 0, 0, 0,
					seg + pos_host, sz, pkt1, &pkt1_len))
					goto send_orig_clean;
				ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);

				DLOG("sending hostfakesplit real host %s%zu-%zu len=%zu : ", pos_split_host ? "part 1 " : "", pos_host, pos_host + sz - 1, sz);
				hexdump_limited_dlog(seg + pos_host, sz, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig_clean;

				if (pos_split_host)
				{
					sz = pos_endhost - pos_split_host;
					pkt1_len = sizeof(pkt1);
					if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0,
						net32_add(dis->tcp->th_seq, pos_split_host), dis->tcp->th_ack,
						dis->tcp->th_win, scale_factor, timestamps,
						DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
						fooling_orig, 0, 0, 0,
						seg + pos_split_host, sz, pkt1, &pkt1_len))
						goto send_orig_clean;
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					DLOG("sending hostfakesplit real host part 2 %zu-%zu len=%zu : ", pos_split_host, pos_endhost - 1, sz);
					hexdump_limited_dlog(seg + pos_split_host, sz, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
						goto send_orig_clean;
				}

				if (dp->hfs_mod.ordering == 0)
				{
					if (dp->ip_id_mode!=IPID_SEQ_GROUP)
					{
						if (dis->ip) ((struct ip*)pkt2)->ip_id = ip_id;
						ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					}
					DLOG("sending hostfakesplit fake(2) host %zu-%zu len=%zu : ", pos_host, pos_endhost - 1, host_size);
					hexdump_limited_dlog(fakehost, host_size, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt2, pkt2_len))
						goto send_orig_clean;

					if (dp->ip_id_mode!=IPID_SEQ_GROUP)
					{
						ip_id_after_host = ip_id;
						if (dis->ip) ((struct ip*)pkt3)->ip_id = ip_id;
					}
					DLOG("sending hostfakesplit after_host part %zu-%zu len=%zu : ", pos_endhost, seg_len - 1, seg_len - pos_endhost);
					hexdump_limited_dlog(seg + pos_endhost, seg_len - pos_endhost, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt3, pkt3_len))
						goto send_orig_clean;
				}

				free(fakehost);

				if (replay) ctrack_replay->ip_id = IP4_IP_ID_NEXT(ip_id_after_host,dp->ip_id_mode);

				return VERDICT_DROP;
			send_orig_clean:
				free(fakehost);
				goto send_orig;
			}
			else
				goto unsplitted_part;

		case DESYNC_MULTISPLIT:
			if (multisplit_count)
			{
				uint8_t ovlseg[DPI_DESYNC_MAX_FAKE_LEN + 100], *seg;
				size_t seg_len, from, to;
				unsigned int seqovl;

				if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;

				for (i = 0, from = 0; i <= multisplit_count; i++)
				{
					to = i == multisplit_count ? dis->len_payload : multisplit_pos[i];

					// do seqovl only to the first packet
					// otherwise it's prone to race condition on server side
					// what happens first : server pushes socket buffer to process or another packet with seqovl arrives
					seqovl = (i == 0 && reasm_offset == 0) ? seqovl_pos : 0;
#ifdef __linux__
					// only linux return error if MTU is exceeded
					for (;; seqovl = 0)
					{
#endif
						if (seqovl)
						{
							seg_len = to - from + seqovl;
							if (seg_len > sizeof(ovlseg))
							{
								DLOG("seqovl is too large");
								goto send_orig;
							}
							fill_pattern(ovlseg, seqovl, dp->seqovl_pattern, sizeof(dp->seqovl_pattern), 0);
							memcpy(ovlseg + seqovl, dis->data_payload + from, to - from);
							seg = ovlseg;
						}
						else
						{
							seqovl = 0;
							seg = dis->data_payload + from;
							seg_len = to - from;
						}

						pkt1_len = sizeof(pkt1);
						if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0,
							net32_add(dis->tcp->th_seq, from - seqovl), dis->tcp->th_ack,
							dis->tcp->th_win, scale_factor, timestamps,
							DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
							fooling_orig, 0, 0, 0,
							seg, seg_len, pkt1, &pkt1_len))
							goto send_orig;
						ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
						DLOG("sending multisplit part %d %zu-%zu len=%zu seqovl=%u : ", i + 1, from, to - 1, to - from, seqovl);
						hexdump_limited_dlog(seg, seg_len, PKTDATA_MAXDUMP); DLOG("\n");
						if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
						{
#ifdef __linux__
							if (errno == EMSGSIZE && seqovl)
							{
								DLOG("MTU exceeded. cancelling seqovl.\n");
								continue;
							}
#endif
							goto send_orig;
						}
#ifdef __linux__
						break;
					}
#endif

					from = to;
				}

				if (replay) ctrack_replay->ip_id = ip_id;

				return VERDICT_DROP;
			}
			else
				goto unsplitted_part;

		case DESYNC_MULTIDISORDER:
			if (multisplit_count)
			{
				uint8_t ovlseg[DPI_DESYNC_MAX_FAKE_LEN + 100], *seg;
				size_t seg_len, from, to;
				unsigned int seqovl;
				uint16_t ip_id_end;

				if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;

				ip_id_end = ip_id = IP4_IP_ID_ADD(ip_id, (uint16_t)multisplit_count, dp->ip_id_mode);

				for (i = multisplit_count - 1, to = dis->len_payload; i >= -1; i--)
				{
					from = i >= 0 ? multisplit_pos[i] : 0;

					seg = dis->data_payload + from;
					seg_len = to - from;
					seqovl = 0;
					// do seqovl only to the second packet
					// otherwise sequence overlap becomes problematic. overlap algorithm is not too obvious.
					// real observations revealed that server can receive overlap junk instead of real data
					if (i == 0)
					{
						if (seqovl_pos >= from)
							DLOG("seqovl>=split_pos (%zu>=%zu). cancelling seqovl for part %d.\n", seqovl_pos, from, i + 2);
						else
						{
							seqovl = seqovl_pos;
							seg_len = to - from + seqovl;
							if (seg_len > sizeof(ovlseg))
							{
								DLOG("seqovl is too large");
								goto send_orig;
							}
							fill_pattern(ovlseg, seqovl, dp->seqovl_pattern, sizeof(dp->seqovl_pattern), 0);
							memcpy(ovlseg + seqovl, dis->data_payload + from, to - from);
							seg = ovlseg;
						}
					}

					pkt1_len = sizeof(pkt1);
					if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0,
						net32_add(dis->tcp->th_seq, from - seqovl), dis->tcp->th_ack,
						dis->tcp->th_win, scale_factor, timestamps,
						DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
						fooling_orig, 0, 0, 0,
						seg, seg_len, pkt1, &pkt1_len))
						goto send_orig;
					ip_id = IP4_IP_ID_PREV(ip_id,dp->ip_id_mode);
					DLOG("sending multisplit part %d %zu-%zu len=%zu seqovl=%u : ", i + 2, from, to - 1, to - from, seqovl);
					hexdump_limited_dlog(seg, seg_len, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
						goto send_orig;

					to = from;
				}

				if (replay) ctrack_replay->ip_id = IP4_IP_ID_NEXT(ip_id_end,dp->ip_id_mode);

				return VERDICT_DROP;
			}
			else
				goto unsplitted_part;

		case DESYNC_FAKEDDISORDER:
			{
				uint8_t fakeseg[DPI_DESYNC_MAX_FAKE_LEN + 100], fakeseg2[DPI_DESYNC_MAX_FAKE_LEN + 100], pat[DPI_DESYNC_MAX_FAKE_LEN], *seg;
				size_t seg_len, fakeseg2_len;
				unsigned int seqovl;
				int order;

				if (dis->len_payload > sizeof(pat))
				{
					DLOG("packet is too large\n");
					goto send_orig;
				}

				if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;

				seqovl = 0;
				if (split_pos)
				{
					order = dp->fs_mod.ordering & 3;
					if (seqovl_pos >= split_pos)
						DLOG("seqovl>=split_pos (%zu>=%zu). cancelling seqovl.\n", seqovl_pos, split_pos);
					else
						seqovl = seqovl_pos;
				}
				else
				{
					order = (dp->fs_mod.ordering >> 3) & 3;
				}

				fill_pattern(pat, dis->len_payload, dp->fsplit_pattern, dp->fsplit_pattern_size, reasm_offset);

				if (seqovl)
				{
					seg_len = dis->len_payload - split_pos + seqovl;
					if (seg_len > sizeof(fakeseg))
					{
						DLOG("seqovl is too large\n");
						goto send_orig;
					}
					fill_pattern(fakeseg, seqovl, dp->seqovl_pattern, sizeof(dp->seqovl_pattern), 0);
					memcpy(fakeseg + seqovl, dis->data_payload + split_pos, dis->len_payload - split_pos);
					seg = fakeseg;
				}
				else
				{
					seg = dis->data_payload + split_pos;
					seg_len = dis->len_payload - split_pos;
				}

				fakeseg2_len = sizeof(fakeseg2);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_fake, false, 0, net32_add(dis->tcp->th_seq, split_pos), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					pat + split_pos, dis->len_payload - split_pos, fakeseg2, &fakeseg2_len))
					goto send_orig;

				if (order == 0)
				{
					if (dp->ip_id_mode!=IPID_SEQ_GROUP) ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					DLOG("sending fake(1) 2nd out-of-order tcp segment %zu-%zu len=%zu : ", split_pos, dis->len_payload - 1, dis->len_payload - split_pos);
					hexdump_limited_dlog(pat + split_pos, dis->len_payload - split_pos, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg2, fakeseg2_len))
						goto send_orig;
				}

				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0, net32_add(dis->tcp->th_seq, split_pos - seqovl), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					fooling_orig, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					seg, seg_len, pkt1, &pkt1_len))
					goto send_orig;
				ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending 2nd out-of-order tcp segment %zu-%zu len=%zu seqovl=%u : ", split_pos, dis->len_payload - 1, dis->len_payload - split_pos, seqovl);
				hexdump_limited_dlog(seg, seg_len, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;

				if (order <= 1)
				{
					if (dp->ip_id_mode!=IPID_SEQ_GROUP)
					{
						if (dis->ip) ((struct ip*)fakeseg2)->ip_id = ip_id;
						ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					}
					DLOG("sending fake(2) 2nd out-of-order tcp segment %zu-%zu len=%zu : ", split_pos, dis->len_payload - 1, dis->len_payload - split_pos);
					hexdump_limited_dlog(pat + split_pos, dis->len_payload - split_pos, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg2, fakeseg2_len))
						goto send_orig;
				}

				if (split_pos)
				{
					seg_len = sizeof(fakeseg);
					if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_fake, false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
						DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
						dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
						pat, split_pos, fakeseg, &seg_len))
						goto send_orig;
					if (dp->ip_id_mode!=IPID_SEQ_GROUP) ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					DLOG("sending fake(1) 1st out-of-order tcp segment 0-%zu len=%zu : ", split_pos - 1, split_pos);
					hexdump_limited_dlog(pat, split_pos, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg, seg_len))
						goto send_orig;

					pkt1_len = sizeof(pkt1);
					if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
						DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
						fooling_orig, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
						dis->data_payload, split_pos, pkt1, &pkt1_len))
						goto send_orig;
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					DLOG("sending 1st out-of-order tcp segment 0-%zu len=%zu : ", split_pos - 1, split_pos);
					hexdump_limited_dlog(dis->data_payload, split_pos, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
						goto send_orig;

					if (order <= 2)
					{
						if (dp->ip_id_mode!=IPID_SEQ_GROUP)
						{
							if (dis->ip) ((struct ip*)fakeseg)->ip_id = ip_id;
							ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
						}
						DLOG("sending fake(2) 1st out-of-order tcp segment 0-%zu len=%zu : ", split_pos - 1, split_pos);
						hexdump_limited_dlog(pat, split_pos, PKTDATA_MAXDUMP); DLOG("\n");
						if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg, seg_len))
							goto send_orig;
					}
				}

				if (replay) ctrack_replay->ip_id = ip_id;

				return VERDICT_DROP;
			}

		case DESYNC_FAKEDSPLIT:
		{
			uint8_t fakeseg[DPI_DESYNC_MAX_FAKE_LEN + 100], ovlseg[DPI_DESYNC_MAX_FAKE_LEN + 100], pat[DPI_DESYNC_MAX_FAKE_LEN], *seg;
			size_t fakeseg_len, seg_len;
			int order;

			if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;

			if (dis->len_payload > sizeof(pat))
			{
				DLOG("packet is too large\n");
				goto send_orig;
			}

			fill_pattern(pat, dis->len_payload, dp->fsplit_pattern, dp->fsplit_pattern_size, reasm_offset);

			if (split_pos)
			{
				order = dp->fs_mod.ordering & 3;
			}
			else
			{
				order = (dp->fs_mod.ordering >> 3) & 3;
				split_pos = dis->len_payload;
			}

			fakeseg_len = sizeof(fakeseg);
			if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_fake, false, 0, dis->tcp->th_seq, dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
				DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
				dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
				pat, split_pos, fakeseg, &fakeseg_len))
				goto send_orig;

			if (order == 0)
			{
				if (dp->ip_id_mode!=IPID_SEQ_GROUP) ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending fake(1) 1st tcp segment 0-%zu len=%zu : ", split_pos - 1, split_pos);
				hexdump_limited_dlog(pat, split_pos, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg, fakeseg_len))
					goto send_orig;
			}

			unsigned int seqovl = (reasm_offset || split_pos>=dis->len_payload) ? 0 : seqovl_pos;
#ifdef __linux__
			// only linux return error if MTU is exceeded
			for (;; seqovl = 0)
			{
#endif
				if (seqovl)
				{
					seg_len = split_pos + seqovl;
					if (seg_len > sizeof(ovlseg))
					{
						DLOG("seqovl is too large\n");
						goto send_orig;
					}
					fill_pattern(ovlseg, seqovl, dp->seqovl_pattern, sizeof(dp->seqovl_pattern), 0);
					memcpy(ovlseg + seqovl, dis->data_payload, split_pos);
					seg = ovlseg;
				}
				else
				{
					seg = dis->data_payload;
					seg_len = split_pos;
				}

				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0, net32_add(dis->tcp->th_seq, -seqovl), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					fooling_orig, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					seg, seg_len, pkt1, &pkt1_len))
					goto send_orig;
				ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending 1st tcp segment 0-%zu len=%zu seqovl=%u : ", split_pos - 1, split_pos, seqovl);
				hexdump_limited_dlog(seg, seg_len, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
				{
#ifdef __linux__
					if (errno == EMSGSIZE && seqovl)
					{
						DLOG("MTU exceeded. cancelling seqovl.\n");
						continue;
					}
#endif
					goto send_orig;
				}
#ifdef __linux__
				break;
			}
#endif
			if (order <= 1)
			{
				if (dp->ip_id_mode!=IPID_SEQ_GROUP)
				{
					if (dis->ip) ((struct ip*)fakeseg)->ip_id = ip_id;
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				}
				DLOG("sending fake(2) 1st tcp segment 0-%zu len=%zu : ", split_pos - 1, split_pos);
				hexdump_limited_dlog(pat, split_pos, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg, fakeseg_len))
					goto send_orig;
			}

			if (split_pos < dis->len_payload)
			{
				fakeseg_len = sizeof(fakeseg);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_fake, false, 0, net32_add(dis->tcp->th_seq, split_pos), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					dp->desync_fooling_mode, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					pat + split_pos, dis->len_payload - split_pos, fakeseg, &fakeseg_len))
					goto send_orig;
				if (dp->ip_id_mode!=IPID_SEQ_GROUP) ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending fake(1) 2nd tcp segment %zu-%zu len=%zu : ", split_pos, dis->len_payload - 1, dis->len_payload - split_pos);
				hexdump_limited_dlog(pat + split_pos, dis->len_payload - split_pos, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg, fakeseg_len))
					goto send_orig;

				pkt1_len = sizeof(pkt1);
				if (!prepare_tcp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, flags_orig, false, 0, net32_add(dis->tcp->th_seq, split_pos), dis->tcp->th_ack, dis->tcp->th_win, scale_factor, timestamps,
					DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
					fooling_orig, dp->desync_ts_increment, dp->desync_badseq_increment, dp->desync_badseq_ack_increment,
					dis->data_payload + split_pos, dis->len_payload - split_pos, pkt1, &pkt1_len))
					goto send_orig;
				ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				DLOG("sending 2nd tcp segment %zu-%zu len=%zu : ", split_pos, dis->len_payload - 1, dis->len_payload - split_pos);
				hexdump_limited_dlog(dis->data_payload + split_pos, dis->len_payload - split_pos, PKTDATA_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;

				if (order <= 2)
				{
					if (dp->ip_id_mode!=IPID_SEQ_GROUP)
					{
						if (dis->ip) ((struct ip*)fakeseg)->ip_id = ip_id;
						ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
					}
					DLOG("sending fake(2) 2nd tcp segment %zu-%zu len=%zu : ", split_pos, dis->len_payload - 1, dis->len_payload - split_pos);
					hexdump_limited_dlog(pat + split_pos, dis->len_payload - split_pos, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, fakeseg, fakeseg_len))
						goto send_orig;
				}
			}

			if (replay) ctrack_replay->ip_id = ip_id;

			return VERDICT_DROP;
		}
		case DESYNC_IPFRAG2:
			if (reasm_offset)
				goto unsplitted_part;
			else
			{
				verdict_tcp_csum_fix(verdict, dis->tcp, dis->transport_len, dis->ip, dis->ip6);

				uint8_t *pkt_orig;
				size_t pkt_orig_len;

				uint32_t ident = dis->ip ? ip_id ? ip_id : htons(1 + random() % 0xFFFF) : htonl(1 + random() % 0xFFFFFFFF);
				size_t ipfrag_pos = (dp->desync_ipfrag_pos_tcp && dp->desync_ipfrag_pos_tcp < dis->transport_len) ? dp->desync_ipfrag_pos_tcp : 24;

				pkt1_len = sizeof(pkt1);
				pkt2_len = sizeof(pkt2);

				if (dis->ip6 && (fooling_orig == FOOL_HOPBYHOP || fooling_orig == FOOL_DESTOPT))
				{
					pkt_orig_len = sizeof(pkt3);
					if (!ip6_insert_simple_hdr(fooling_orig == FOOL_HOPBYHOP ? IPPROTO_HOPOPTS : IPPROTO_DSTOPTS, dis->data_pkt, dis->len_pkt, pkt3, &pkt_orig_len))
						goto send_orig;
					pkt_orig = pkt3;
				}
				else
				{
					pkt_orig = dis->data_pkt;
					pkt_orig_len = dis->len_pkt;
				}

				if (!ip_frag(pkt_orig, pkt_orig_len, ipfrag_pos, ident, pkt1, &pkt1_len, pkt2, &pkt2_len))
					goto send_orig;

				DLOG("sending 1st ip fragment 0-%zu ip_payload_len=%zu : ", ipfrag_pos - 1, ipfrag_pos);
				hexdump_limited_dlog(pkt1, pkt1_len, IP_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;

				DLOG("sending 2nd ip fragment %zu-%zu ip_payload_len=%zu : ", ipfrag_pos, dis->transport_len - 1, dis->transport_len - ipfrag_pos);
				hexdump_limited_dlog(pkt2, pkt2_len, IP_MAXDUMP); DLOG("\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt2, pkt2_len))
					goto send_orig;

				if (replay) ctrack_replay->ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);

				return VERDICT_DROP;
			}
		default:
			break;
		}
	}

send_orig:

	if ((verdict & VERDICT_MASK) == VERDICT_DROP)
		verdict = ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, dis->tcp);
	else
		if (tcp_orig_send(verdict, desync_fwmark, ifout, dp, ctrack_replay, dis, bFake))
			verdict = ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, dis->tcp);
	return verdict;

unsplitted_part:
	if (replay && dis->ip && ctrack_replay->ip_id)
	{
		DLOG("changing ip_id of unsplitted part\n");
		dis->ip->ip_id = ctrack_replay->ip_id;
		ctrack_replay->ip_id = IP4_IP_ID_NEXT(ctrack_replay->ip_id,dp->ip_id_mode);
		return VERDICT_MODIFY;
	}
	goto send_orig;

}

// return : true - should continue, false - should stop with verdict
static bool quic_reasm_cancel(t_ctrack *ctrack, const char *reason)
{
	reasm_orig_cancel(ctrack);
	if (ctrack && ctrack->dp && ctrack->dp->desync_any_proto)
	{
		DLOG("%s. applying tampering because desync_any_proto is set\n", reason);
		return true;
	}
	else
	{
		DLOG("%s. not applying tampering because desync_any_proto is not set\n", reason);
		return false;
	}
}

static uint8_t dpi_desync_udp_packet_play(bool replay, size_t reasm_offset, uint32_t fwmark, const char *ifin, const char *ifout, struct dissect *dis)
{
	uint8_t verdict = VERDICT_PASS;
	uint32_t desync_fwmark = fwmark | params.desync_fwmark;

	// additional safety check
	if (!!dis->ip == !!dis->ip6) return verdict;

	struct desync_profile *dp = NULL;

	t_ctrack *ctrack = NULL, *ctrack_replay = NULL;
	bool bReverse = false;
	bool bFake = false;

	struct sockaddr_storage src, dst;
	uint8_t pkt1[DPI_DESYNC_MAX_FAKE_LEN + 100], pkt2[DPI_DESYNC_MAX_FAKE_LEN + 100], pkt3[DPI_DESYNC_MAX_FAKE_LEN + 100];
	size_t pkt1_len, pkt2_len;
	uint8_t ttl_orig, ttl_fake;
	bool DF;
	char host[256];
	t_l7proto l7proto = UNKNOWN;
	const char *ifname = NULL, *ssid = NULL;

	extract_endpoints(dis->ip, dis->ip6, NULL, dis->udp, &src, &dst);

	if (replay)
	{
		// in replay mode conntrack_replay is not NULL and ctrack is NULL

		//ConntrackPoolDump(&params.conntrack);
		if (!ConntrackPoolDoubleSearch(&params.conntrack, dis->ip, dis->ip6, NULL, dis->udp, &ctrack_replay, &bReverse) || bReverse)
			return verdict;

		ifname = bReverse ? ifin : ifout;
#ifdef HAS_FILTER_SSID
		ssid = wlan_ssid_search_ifname(ifname);
		if (ssid) DLOG("found ssid for %s : %s\n", ifname, ssid);
#endif

		dp = ctrack_replay->dp;
		if (dp)
			DLOG("using cached desync profile %d\n", dp->n);
		else if (!ctrack_replay->dp_search_complete)
		{
			dp = ctrack_replay->dp = dp_find(&params.desync_profiles, IPPROTO_UDP, (struct sockaddr *)&dst, ctrack_replay->hostname, ctrack_replay->hostname_is_ip, ctrack_replay->l7proto, ssid, NULL, NULL, NULL);
			ctrack_replay->dp_search_complete = true;
		}
		if (!dp)
		{
			DLOG("matching desync profile not found\n");
			return verdict;
		}
	}
	else
	{
		// in real mode ctrack may be NULL or not NULL, conntrack_replay is equal to ctrack

		if (!params.ctrack_disable)
		{
			ConntrackPoolPurge(&params.conntrack);
			if (ConntrackPoolFeed(&params.conntrack, dis->ip, dis->ip6, NULL, dis->udp, dis->len_payload, &ctrack, &bReverse))
			{
				dp = ctrack->dp;
				ctrack_replay = ctrack;
			}
		}
		ifname = bReverse ? ifin : ifout;
#ifdef HAS_FILTER_SSID
		ssid = wlan_ssid_search_ifname(ifname);
		if (ssid) DLOG("found ssid for %s : %s\n", ifname, ssid);
#endif
		if (dp)
			DLOG("using cached desync profile %d\n", dp->n);
		else if (!ctrack || !ctrack->dp_search_complete)
		{
			const char *hostname = NULL;
			bool hostname_is_ip = false;
			if (ctrack)
			{
				hostname = ctrack->hostname;
				hostname_is_ip = ctrack->hostname_is_ip;
				if (!hostname && !bReverse)
				{
					if (ipcache_get_hostname(dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, host, sizeof(host), &hostname_is_ip) && *host)
						if (!(hostname = ctrack_replay->hostname = strdup(host)))
							DLOG_ERR("strdup(host): out of memory\n");
				}
			}
			dp = dp_find(&params.desync_profiles, IPPROTO_UDP, (struct sockaddr *)&dst, hostname, hostname_is_ip, ctrack ? ctrack->l7proto : UNKNOWN, ssid, NULL, NULL, NULL);
			if (ctrack)
			{
				ctrack->dp = dp;
				ctrack->dp_search_complete = true;
			}
		}
		if (!dp)
		{
			DLOG("matching desync profile not found\n");
			return verdict;
		}
		maybe_cutoff(ctrack, IPPROTO_UDP);

		HostFailPoolPurgeRateLimited(&dp->hostlist_auto_fail_counters);
		//ConntrackPoolDump(&params.conntrack);

		if (bReverse)
		{
			if (ctrack)
			{
				ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;
				if (!ctrack->incoming_ttl)
				{
					DLOG("incoming TTL %u\n", ttl_orig);
					ctrack->incoming_ttl = ttl_orig;
					autottl_rediscover(ctrack, dis->ip ? &dis->ip->ip_src : NULL, dis->ip6 ? &dis->ip6->ip6_src : NULL, ifin);
				}
			}
			return verdict; // nothing to do. do not waste cpu
		}

		autottl_discover(ctrack, dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, ifout);

		if (orig_mod(dp, ctrack, dis)) // ttl can change !
			verdict = VERDICT_MODIFY;

		// start and cutoff limiters
		if (!process_desync_interval(dp, ctrack)) goto send_orig;
	}

	DF = ip_has_df(dis->ip);

	if (dis->len_payload)
	{
		struct blob_collection_head *fake;
		bool bHaveHost = false, bHostIsIp = false;
		uint16_t ip_id=0;

		if (replay && ctrack_replay->ip_id) ip_id = ctrack_replay->ip_id;
		if (!ip_id) ip_id = IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode);

		if (IsQUICInitial(dis->data_payload, dis->len_payload))
		{
			DLOG("packet contains QUIC initial\n");
			l7proto = QUIC;
			if (ctrack && ctrack->l7proto == UNKNOWN) ctrack->l7proto = l7proto;

			uint8_t clean[16384], *pclean;
			size_t clean_len;

			if (replay)
			{
				clean_len = ctrack_replay->reasm_orig.size_present;
				pclean = ctrack_replay->reasm_orig.packet;
			}
			else
			{
				clean_len = sizeof(clean);
				pclean = QUICDecryptInitial(dis->data_payload, dis->len_payload, clean, &clean_len) ? clean : NULL;
			}
			if (pclean)
			{
				if (ctrack && !ReasmIsEmpty(&ctrack->reasm_orig))
				{
					if (ReasmHasSpace(&ctrack->reasm_orig, clean_len))
					{
						reasm_orig_feed(ctrack, IPPROTO_UDP, clean, clean_len);
						pclean = ctrack->reasm_orig.packet;
						clean_len = ctrack->reasm_orig.size_present;
					}
					else
					{
						DLOG("QUIC reasm is too long. cancelling.\n");
						reasm_orig_cancel(ctrack);
						goto send_orig; // cannot be first packet
					}
				}
				uint8_t defrag[UDP_MAX_REASM];
				size_t hello_offset, hello_len, defrag_len = sizeof(defrag);
				bool bFull;
				if (QUICDefragCrypto(pclean, clean_len, defrag, &defrag_len, &bFull))
				{
					if (bFull)
					{
						DLOG("QUIC initial contains CRYPTO with full fragment coverage\n");

						bool bIsHello = IsQUICCryptoHello(defrag, defrag_len, &hello_offset, &hello_len);
						bool bReqFull = bIsHello ? IsTLSHandshakeFull(defrag + hello_offset, hello_len) : false;

						DLOG(bIsHello ? bReqFull ? "packet contains full TLS ClientHello\n" : "packet contains partial TLS ClientHello\n" : "packet does not contain TLS ClientHello\n");

						if (bReqFull) TLSDebugHandshake(defrag + hello_offset, hello_len);

						if (ctrack)
						{
							if (bIsHello && !bReqFull && ReasmIsEmpty(&ctrack->reasm_orig))
							{
								// preallocate max buffer to avoid reallocs that cause memory copy
								if (!reasm_orig_start(ctrack, IPPROTO_UDP, UDP_MAX_REASM, UDP_MAX_REASM, clean, clean_len))
								{
									reasm_orig_cancel(ctrack);
									goto send_orig;
								}
							}
							if (!ReasmIsEmpty(&ctrack->reasm_orig))
							{
								verdict_udp_csum_fix(verdict, dis->udp, dis->transport_len, dis->ip, dis->ip6);
								if (rawpacket_queue(&ctrack->delayed, &dst, desync_fwmark, ifin, ifout, dis->data_pkt, dis->len_pkt, dis->len_payload))
								{
									DLOG("DELAY desync until reasm is complete (#%u)\n", rawpacket_queue_count(&ctrack->delayed));
								}
								else
								{
									DLOG_ERR("rawpacket_queue failed !\n");
									reasm_orig_cancel(ctrack);
									goto send_orig;
								}
								if (bReqFull)
								{
									replay_queue(&ctrack->delayed);
									reasm_orig_fin(ctrack);
								}
								return ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
							}
						}

						if (bIsHello)
						{
							bHaveHost = TLSHelloExtractHostFromHandshake(defrag + hello_offset, hello_len, host, sizeof(host), TLS_PARTIALS_ENABLE);
							if (!bHaveHost && dp->desync_skip_nosni)
							{
								reasm_orig_cancel(ctrack);
								DLOG("not applying tampering to QUIC ClientHello without hostname in the SNI\n");
								goto send_orig;
							}
						}
						else
						{
							if (!quic_reasm_cancel(ctrack, "QUIC initial without ClientHello")) goto send_orig;
						}
					}
					else
					{
						DLOG("QUIC initial contains CRYPTO with partial fragment coverage\n");
						if (ctrack)
						{
							if (ReasmIsEmpty(&ctrack->reasm_orig))
							{
								// preallocate max buffer to avoid reallocs that cause memory copy
								if (!reasm_orig_start(ctrack, IPPROTO_UDP, UDP_MAX_REASM, UDP_MAX_REASM, clean, clean_len))
								{
									reasm_orig_cancel(ctrack);
									goto send_orig;
								}
							}
							verdict_udp_csum_fix(verdict, dis->udp, dis->transport_len, dis->ip, dis->ip6);
							if (rawpacket_queue(&ctrack->delayed, &dst, desync_fwmark, ifin, ifout, dis->data_pkt, dis->len_pkt, dis->len_payload))
							{
								DLOG("DELAY desync until reasm is complete (#%u)\n", rawpacket_queue_count(&ctrack->delayed));
							}
							else
							{
								DLOG_ERR("rawpacket_queue failed !\n");
								reasm_orig_cancel(ctrack);
								goto send_orig;
							}
							return ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
						}
						if (!quic_reasm_cancel(ctrack, "QUIC initial fragmented CRYPTO")) goto send_orig;
					}
				}
				else
				{
					// defrag failed
					if (!quic_reasm_cancel(ctrack, "QUIC initial defrag CRYPTO failed")) goto send_orig;
				}
			}
			else
			{
				// decrypt failed
				if (!quic_reasm_cancel(ctrack, "QUIC initial decryption failed")) goto send_orig;
			}
		}
		else // not QUIC initial
		{
			// received payload without host. it means we are out of the request retransmission phase. stop counter
			ctrack_stop_retrans_counter(ctrack);

			reasm_orig_cancel(ctrack);

			if (IsWireguardHandshakeInitiation(dis->data_payload, dis->len_payload))
			{
				DLOG("packet contains wireguard handshake initiation\n");
				l7proto = WIREGUARD;
				if (ctrack && ctrack->l7proto == UNKNOWN) ctrack->l7proto = l7proto;
			}
			else if (IsDhtD1(dis->data_payload, dis->len_payload))
			{
				DLOG("packet contains DHT d1...e\n");
				l7proto = DHT;
				if (ctrack && ctrack->l7proto == UNKNOWN) ctrack->l7proto = l7proto;
			}
			else if (IsDiscordIpDiscoveryRequest(dis->data_payload, dis->len_payload))
			{
				DLOG("packet contains discord voice IP discovery\n");
				l7proto = DISCORD;
				if (ctrack && ctrack->l7proto == UNKNOWN) ctrack->l7proto = l7proto;
			}
			else if (IsStunMessage(dis->data_payload, dis->len_payload))
			{
				DLOG("packet contains STUN message\n");
				l7proto = STUN;
				if (ctrack && ctrack->l7proto == UNKNOWN) ctrack->l7proto = l7proto;
			}
			else
			{
				if (!dp->desync_any_proto)
				{
					DLOG("not applying tampering to unknown protocol\n");
					goto send_orig;
				}
				DLOG("applying tampering to unknown protocol\n");
			}
		}

		if (bHaveHost)
		{
			bHostIsIp = strip_host_to_ip(host);
			DLOG("hostname: %s\n", host);
		}

		bool bDiscoveredL7;
		if (ctrack_replay)
		{
			if ((bDiscoveredL7 = !ctrack_replay->l7proto_discovered && ctrack_replay->l7proto != UNKNOWN))
				ctrack_replay->l7proto_discovered = true;
		}
		else
			bDiscoveredL7 = !ctrack_replay && l7proto != UNKNOWN;
		if (bDiscoveredL7) DLOG("discovered l7 protocol\n");

		bool bDiscoveredHostname = bHaveHost && !(ctrack_replay && ctrack_replay->hostname_discovered);
		if (bDiscoveredHostname)
		{
			DLOG("discovered hostname\n");
			if (ctrack_replay)
			{
				ctrack_replay->hostname_discovered = true;
				free(ctrack_replay->hostname);
				ctrack_replay->hostname = strdup(host);
				ctrack_replay->hostname_is_ip = bHostIsIp;
				if (!ctrack_replay->hostname)
				{
					DLOG_ERR("hostname dup : out of memory");
					goto send_orig;
				}
				if (!ipcache_put_hostname(dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, host, bHostIsIp))
					goto send_orig;
			}
		}

		bool bCheckDone = false, bCheckResult = false, bCheckExcluded = false;
		if (bDiscoveredL7 || bDiscoveredHostname)
		{
			struct desync_profile *dp_prev = dp;

			dp = dp_find(&params.desync_profiles, IPPROTO_UDP, (struct sockaddr *)&dst,
				ctrack_replay ? ctrack_replay->hostname : bHaveHost ? host : NULL,
				ctrack_replay ? ctrack_replay->hostname_is_ip : bHostIsIp,
				ctrack_replay ? ctrack_replay->l7proto : l7proto, ssid,
				&bCheckDone, &bCheckResult, &bCheckExcluded);
			if (ctrack_replay)
			{
				ctrack_replay->dp = dp;
				ctrack_replay->dp_search_complete = true;
				ctrack_replay->bCheckDone = bCheckDone;
				ctrack_replay->bCheckResult = bCheckResult;
				ctrack_replay->bCheckExcluded = bCheckExcluded;
			}
			if (!dp)
			{
				reasm_orig_cancel(ctrack);
				goto send_orig;
			}
			if (dp != dp_prev)
			{
				DLOG("desync profile changed by revealed l7 protocol or hostname !\n");
				autottl_rediscover(ctrack_replay, dis->ip ? &dis->ip->ip_dst : NULL, dis->ip6 ? &dis->ip6->ip6_dst : NULL, ifout);
				ip_id = IP4_IP_ID_FIX(dis->ip,dp->ip_id_mode);
				// re-evaluate start/cutoff limiters
				if (replay)
				{
					if (orig_mod(dp, ctrack_replay, dis)) // ttl can change !
						verdict = VERDICT_MODIFY;
				}
				else
				{
					maybe_cutoff(ctrack, IPPROTO_UDP);
					if (orig_mod(dp, ctrack, dis)) // ttl can change !
						verdict = VERDICT_MODIFY;
					if (!process_desync_interval(dp, ctrack)) goto send_orig;
				}
			}
		}
		else if (ctrack_replay)
		{
			bCheckDone = ctrack_replay->bCheckDone;
			bCheckResult = ctrack_replay->bCheckResult;
			bCheckExcluded = ctrack_replay->bCheckExcluded;
		}

		if (bHaveHost && !PROFILE_HOSTLISTS_EMPTY(dp))
		{
			if (!bCheckDone)
				bCheckResult = HostlistCheck(dp, host, bHostIsIp, &bCheckExcluded, false);
			if (bCheckResult)
				ctrack_stop_retrans_counter(ctrack_replay);
			else
			{
				if (ctrack_replay)
				{
					ctrack_replay->hostname_ah_check = dp->hostlist_auto && !bCheckExcluded;
					if (ctrack_replay->hostname_ah_check)
					{
						// first request is not retrans
						if (!bDiscoveredHostname && !reasm_offset)
							process_retrans_fail(ctrack_replay, IPPROTO_UDP, (struct sockaddr*)&src);
					}
				}
				DLOG("not applying tampering to this request\n");
				goto send_orig;
			}
		}

		// desync profile may have changed after hostname was revealed
		switch (l7proto)
		{
		case QUIC:
			fake = &dp->fake_quic;
			break;
		case WIREGUARD:
			fake = &dp->fake_wg;
			break;
		case DHT:
			fake = &dp->fake_dht;
			break;
		case DISCORD:
			fake = &dp->fake_discord;
			break;
		case STUN:
			fake = &dp->fake_stun;
			break;
		default:
			fake = &dp->fake_unknown_udp;
			break;
		}

		ttl_orig = dis->ip ? dis->ip->ip_ttl : dis->ip6->ip6_ctlun.ip6_un1.ip6_un1_hlim;
		ttl_fake = (ctrack_replay && ctrack_replay->desync_autottl) ? ctrack_replay->desync_autottl : (dis->ip6 ? (dp->desync_ttl6 ? dp->desync_ttl6 : ttl_orig) : (dp->desync_ttl ? dp->desync_ttl : ttl_orig));

		uint32_t fooling_orig = FOOL_NONE;

		if (params.debug)
		{
			char s1[48], s2[48];
			ntop46_port((struct sockaddr *)&src, s1, sizeof(s1));
			ntop46_port((struct sockaddr *)&dst, s2, sizeof(s2));
			DLOG("dpi desync src=%s dst=%s\n", s1, s2);
		}

		switch (dp->desync_mode)
		{
		case DESYNC_FAKE_KNOWN:
			if (l7proto == UNKNOWN)
			{
				DLOG("not applying fake because of unknown protocol\n");
				break;
			}
		case DESYNC_FAKE:
			if (!reasm_offset)
			{
				size_t fake_size;
				uint8_t *fake_data;
				struct blob_item *fake_item;
				int n = 0;

				LIST_FOREACH(fake_item, fake, next)
				{
					n++;

					fake_data = fake_item->data + fake_item->offset;
					fake_size = fake_item->size - fake_item->offset;

					pkt1_len = sizeof(pkt1);
					if (!prepare_udp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst,
						DF, ttl_fake, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6),
						dp->desync_fooling_mode, NULL, 0, 0,
						fake_data, fake_size, pkt1, &pkt1_len))
					{
						goto send_orig;
					}
					DLOG("sending fake[%d] : ", n);
					hexdump_limited_dlog(fake_data, fake_size, PKTDATA_MAXDUMP); DLOG("\n");
					if (!rawsend_rep(dp->desync_repeats, (struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
						goto send_orig;
					ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);
				}
				bFake = true;
			}
			break;
		case DESYNC_HOPBYHOP:
		case DESYNC_DESTOPT:
		case DESYNC_IPFRAG1:
			fooling_orig = (dp->desync_mode == DESYNC_HOPBYHOP) ? FOOL_HOPBYHOP : (dp->desync_mode == DESYNC_DESTOPT) ? FOOL_DESTOPT : FOOL_IPFRAG1;
			if (dis->ip6 && (dp->desync_mode2 == DESYNC_NONE || !desync_valid_second_stage_udp(dp->desync_mode2)))
			{
				pkt1_len = sizeof(pkt1);
				if (!prepare_udp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst,
					DF, ttl_orig, 0, 0, IP6_FLOW(dis->ip6), fooling_orig, NULL, 0, 0,
					dis->data_payload, dis->len_payload, pkt1, &pkt1_len))
				{
					goto send_orig;
				}
				DLOG("resending original packet with extension header\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;
				// this mode is final, no other options available
				return ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
			}
			break;
		default:
			pkt1_len = 0;
			break;
		}

		enum dpi_desync_mode desync_mode = dp->desync_mode2 == DESYNC_NONE ? dp->desync_mode : dp->desync_mode2;
		switch (desync_mode)
		{
		case DESYNC_UDPLEN:
			pkt1_len = sizeof(pkt1);
			if (!prepare_udp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6), fooling_orig, dp->udplen_pattern, sizeof(dp->udplen_pattern), dp->udplen_increment, dis->data_payload, dis->len_payload, pkt1, &pkt1_len))
			{
				DLOG("could not construct packet with modified length. too large ?\n");
				break;
			}
			DLOG("resending original packet with increased by %d length\n", dp->udplen_increment);
			if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
				goto send_orig;
			return ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
		case DESYNC_TAMPER:
			if (IsDhtD1(dis->data_payload, dis->len_payload))
			{
				size_t szbuf, szcopy;
				memcpy(pkt2, "d2:001:x", 8);
				pkt2_len = 8;
				szbuf = sizeof(pkt2) - pkt2_len;
				szcopy = dis->len_payload - 1;
				if (szcopy > szbuf)
				{
					DLOG("packet is too long to tamper");
					break;
				}
				memcpy(pkt2 + pkt2_len, dis->data_payload + 1, szcopy);
				pkt2_len += szcopy;
				pkt1_len = sizeof(pkt1);
				if (!prepare_udp_segment((struct sockaddr *)&src, (struct sockaddr *)&dst, DF, ttl_orig, IP4_TOS(dis->ip), ip_id, IP6_FLOW(dis->ip6), fooling_orig, NULL, 0, 0, pkt2, pkt2_len, pkt1, &pkt1_len))
				{
					DLOG("could not construct packet with modified length. too large ?\n");
					break;
				}
				DLOG("resending tampered DHT\n");
				if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
					goto send_orig;
				return ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
			}
			else
			{
				DLOG("payload is not tamperable\n");
				break;
			}
		case DESYNC_IPFRAG2:
		{
			verdict_udp_csum_fix(verdict, dis->udp, dis->transport_len, dis->ip, dis->ip6);

			uint8_t *pkt_orig;
			size_t pkt_orig_len;

			uint32_t ident = dis->ip ? ip_id ? ip_id : htons(1 + random() % 0xFFFF) : htonl(1 + random() % 0xFFFFFFFF);
			size_t ipfrag_pos = (dp->desync_ipfrag_pos_udp && dp->desync_ipfrag_pos_udp < dis->transport_len) ? dp->desync_ipfrag_pos_udp : sizeof(struct udphdr);

			pkt1_len = sizeof(pkt1);
			pkt2_len = sizeof(pkt2);

			if (dis->ip6 && (fooling_orig == FOOL_HOPBYHOP || fooling_orig == FOOL_DESTOPT))
			{
				pkt_orig_len = sizeof(pkt3);
				if (!ip6_insert_simple_hdr(fooling_orig == FOOL_HOPBYHOP ? IPPROTO_HOPOPTS : IPPROTO_DSTOPTS, dis->data_pkt, dis->len_pkt, pkt3, &pkt_orig_len))
					goto send_orig;
				pkt_orig = pkt3;
			}
			else
			{
				pkt_orig = dis->data_pkt;
				pkt_orig_len = dis->len_pkt;
			}

			if (!ip_frag(pkt_orig, pkt_orig_len, ipfrag_pos, ident, pkt1, &pkt1_len, pkt2, &pkt2_len))
				goto send_orig;

			DLOG("sending 1st ip fragment 0-%zu ip_payload_len=%zu : ", ipfrag_pos - 1, ipfrag_pos);
			hexdump_limited_dlog(pkt1, pkt1_len, IP_MAXDUMP); DLOG("\n");
			if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt1, pkt1_len))
				goto send_orig;

			DLOG("sending 2nd ip fragment %zu-%zu ip_payload_len=%zu : ", ipfrag_pos, dis->transport_len - 1, dis->transport_len - ipfrag_pos);
			hexdump_limited_dlog(pkt2, pkt2_len, IP_MAXDUMP); DLOG("\n");
			if (!rawsend((struct sockaddr *)&dst, desync_fwmark, ifout, pkt2, pkt2_len))
				goto send_orig;

			if (replay) ctrack_replay->ip_id = IP4_IP_ID_NEXT(ip_id,dp->ip_id_mode);

			return ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
		}
		default:
			break;
		}
	}

send_orig:
	if ((verdict & VERDICT_MASK) == VERDICT_DROP)
		verdict = ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
	else
		if (udp_orig_send(verdict, desync_fwmark, ifout, dp, ctrack_replay, dis, bFake))
			verdict = ct_new_postnat_fix(ctrack, dis->ip, dis->ip6, NULL);
	return verdict;
}


static void packet_debug(bool replay, const struct dissect *dis)
{
	if (params.debug)
	{
		if (replay) DLOG("REPLAY ");
		if (dis->ip)
		{
			char s[66];
			str_ip(s, sizeof(s), dis->ip);
			DLOG("IP4: %s", s);
		}
		else if (dis->ip6)
		{
			char s[128];
			str_ip6hdr(s, sizeof(s), dis->ip6, dis->proto);
			DLOG("IP6: %s", s);
		}
		if (dis->tcp)
		{
			char s[80];
			str_tcphdr(s, sizeof(s), dis->tcp);
			DLOG(" %s\n", s);
			if (dis->len_payload) { DLOG("TCP: len=%zu : ", dis->len_payload); hexdump_limited_dlog(dis->data_payload, dis->len_payload, PKTDATA_MAXDUMP); DLOG("\n"); }

		}
		else if (dis->udp)
		{
			char s[30];
			str_udphdr(s, sizeof(s), dis->udp);
			DLOG(" %s\n", s);
			if (dis->len_payload) { DLOG("UDP: len=%zu : ", dis->len_payload); hexdump_limited_dlog(dis->data_payload, dis->len_payload, PKTDATA_MAXDUMP); DLOG("\n"); }
		}
		else
			DLOG("\n");
	}
}


static uint8_t dpi_desync_packet_play(bool replay, size_t reasm_offset, uint32_t fwmark, const char *ifin, const char *ifout, uint8_t *data_pkt, size_t *len_pkt)
{
	struct dissect dis;
	uint8_t verdict = VERDICT_PASS;

	proto_dissect_l3l4(data_pkt, *len_pkt, &dis);
	if (!!dis.ip != !!dis.ip6)
	{
		packet_debug(replay, &dis);
		switch (dis.proto)
		{
		case IPPROTO_TCP:
			if (dis.tcp)
			{
				verdict = dpi_desync_tcp_packet_play(replay, reasm_offset, fwmark, ifin, ifout, &dis);
				verdict_tcp_csum_fix(verdict, dis.tcp, dis.transport_len, dis.ip, dis.ip6);
			}
			break;
		case IPPROTO_UDP:
			if (dis.udp)
			{
				verdict = dpi_desync_udp_packet_play(replay, reasm_offset, fwmark, ifin, ifout, &dis);
				verdict_udp_csum_fix(verdict, dis.udp, dis.transport_len, dis.ip, dis.ip6);
			}
			break;
		}
		*len_pkt = dis.len_pkt;
	}
	return verdict;
}
uint8_t dpi_desync_packet(uint32_t fwmark, const char *ifin, const char *ifout, uint8_t *data_pkt, size_t *len_pkt)
{
	ipcachePurgeRateLimited(&params.ipcache, params.ipcache_lifetime);
	return dpi_desync_packet_play(false, 0, fwmark, ifin, ifout, data_pkt, len_pkt);
}



static bool replay_queue(struct rawpacket_tailhead *q)
{
	struct rawpacket *rp;
	size_t offset;
	unsigned int i;
	bool b = true;
	for (i = 1, offset = 0; (rp = rawpacket_dequeue(q)); offset += rp->len_payload, rawpacket_free(rp), i++)
	{
		DLOG("REPLAYING delayed packet #%u offset %zu\n", i, offset);
		uint8_t verdict = dpi_desync_packet_play(true, offset, rp->fwmark, rp->ifin, rp->ifout, rp->packet, &rp->len);
		switch (verdict & VERDICT_MASK)
		{
		case VERDICT_MODIFY:
			DLOG("SENDING delayed packet #%u modified\n", i);
			b &= rawsend_rp(rp);
			break;
		case VERDICT_PASS:
			DLOG("SENDING delayed packet #%u unmodified\n", i);
			b &= rawsend_rp(rp);
			break;
		case VERDICT_DROP:
			DLOG("DROPPING delayed packet #%u\n", i);
			break;
		}
	}
	return b;
}
