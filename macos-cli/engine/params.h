#pragma once

#include "nfqws.h"
#include "pools.h"
#include "conntrack.h"
#include "desync.h"
#include "protocol.h"
#include "helpers.h"

#include <sys/param.h>
#include <sys/types.h>
#include <net/if.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <time.h>
#include <sys/queue.h>
#if !defined( __OpenBSD__) && !defined(__ANDROID__)
#include <wordexp.h>
#endif

#define TLS_PARTIALS_ENABLE	true

#define RAW_SNDBUF	(64*1024)	// in bytes

#define Q_MAXLEN	4986		// in packets
#define Q_RCVBUF	(1024*1024)	// in bytes

#define BADSEQ_INCREMENT_DEFAULT 	-10000
#define BADSEQ_ACK_INCREMENT_DEFAULT 	-66000

#define TS_INCREMENT_DEFAULT 		-600000

#define IPFRAG_UDP_DEFAULT 8
#define IPFRAG_TCP_DEFAULT 32

#define UDPLEN_INCREMENT_DEFAULT 	2

#define HOSTLIST_AUTO_FAIL_THRESHOLD_DEFAULT	3
#define	HOSTLIST_AUTO_FAIL_TIME_DEFAULT 	60
#define	HOSTLIST_AUTO_RETRANS_THRESHOLD_DEFAULT	3

#define IPCACHE_LIFETIME		7200

#define AUTOTTL_DEFAULT_DESYNC_DELTA	-1
#define AUTOTTL_DEFAULT_DESYNC_MIN	3
#define AUTOTTL_DEFAULT_DESYNC_MAX	20
#define AUTOTTL_DEFAULT_ORIG_DELTA	+5
#define AUTOTTL_DEFAULT_ORIG_MIN	3
#define AUTOTTL_DEFAULT_ORIG_MAX	64
#define AUTOTTL_DEFAULT_DUP_DELTA	-1
#define AUTOTTL_DEFAULT_DUP_MIN		3
#define AUTOTTL_DEFAULT_DUP_MAX		64


#define MAX_SPLITS	64

#define FAKE_TLS_MOD_SAVE_MASK		0x0F
#define FAKE_TLS_MOD_SET		0x01
#define FAKE_TLS_MOD_CUSTOM_FAKE	0x02
#define FAKE_TLS_MOD_RND		0x10
#define FAKE_TLS_MOD_DUP_SID		0x20
#define FAKE_TLS_MOD_RND_SNI		0x40
#define FAKE_TLS_MOD_SNI		0x80
#define FAKE_TLS_MOD_PADENCAP		0x100

#define FAKE_MAX_TCP	1460
#define FAKE_MAX_UDP	1472

#define MAX_GIDS 64

extern const char * tld[6];

enum log_target { LOG_TARGET_CONSOLE=0, LOG_TARGET_FILE, LOG_TARGET_SYSLOG, LOG_TARGET_ANDROID };

struct fake_tls_mod_cache
{
	size_t extlen_offset, padlen_offset;
};
struct fake_tls_mod
{
	char sni[128];
	uint32_t mod;
};
struct hostfakesplit_mod
{
	char host[128];
	size_t host_size;
	int ordering;
};
struct fakedsplit_mod
{
	int ordering;
};
struct tcp_mod
{
	bool seq;
};

typedef enum {SS_NONE=0,SS_SYN,SS_SYNACK,SS_ACKSYN} t_synack_split;
typedef enum {IPID_SEQ=0,IPID_SEQ_GROUP,IPID_RND,IPID_ZERO,IPID_SAME} t_ip_id_mode;

struct desync_profile
{
	int n;	// number of the profile

	uint16_t wsize,wssize;
	uint8_t wscale,wsscale;
	char wssize_cutoff_mode; // n - packets, d - data packets, s - relative sequence
	bool wssize_no_forced_cutoff;
	unsigned int wssize_cutoff;

	t_synack_split synack_split;

	t_ip_id_mode ip_id_mode;

	bool hostcase, hostnospace, domcase, methodeol;
	char hostspell[4];
	enum dpi_desync_mode desync_mode0,desync_mode,desync_mode2;
	bool desync_retrans,desync_skip_nosni,desync_any_proto;
	unsigned int desync_repeats,desync_ipfrag_pos_tcp,desync_ipfrag_pos_udp;

	// multisplit
	struct proto_pos splits[MAX_SPLITS];
	int split_count;
	struct proto_pos seqovl,hostfakesplit_midhost;

	char dup_start_mode, dup_cutoff_mode; // n - packets, d - data packets, s - relative sequence
	bool dup_replace;
	unsigned int dup_start, dup_cutoff;
	unsigned int dup_repeats;
	uint8_t dup_ttl, dup_ttl6;
	uint32_t dup_fooling_mode;
	uint32_t dup_ts_increment, dup_badseq_increment, dup_badseq_ack_increment;
	autottl dup_autottl, dup_autottl6;
	uint16_t dup_tcp_flags_set, dup_tcp_flags_unset;
	t_ip_id_mode dup_ip_id_mode;

	char orig_mod_start_mode, orig_mod_cutoff_mode; // n - packets, d - data packets, s - relative sequence
	unsigned int orig_mod_start, orig_mod_cutoff;
	uint8_t orig_mod_ttl, orig_mod_ttl6;
	autottl orig_autottl, orig_autottl6;
	uint16_t orig_tcp_flags_set, orig_tcp_flags_unset;

	char desync_start_mode, desync_cutoff_mode; // n - packets, d - data packets, s - relative sequence
	unsigned int desync_start, desync_cutoff;
	uint8_t desync_ttl, desync_ttl6;
	autottl desync_autottl, desync_autottl6;
	uint32_t desync_fooling_mode;
	uint32_t desync_ts_increment, desync_badseq_increment, desync_badseq_ack_increment;
	uint16_t desync_tcp_flags_set, desync_tcp_flags_unset;

	struct blob_collection_head fake_http,fake_tls,fake_unknown,fake_unknown_udp,fake_quic,fake_wg,fake_dht,fake_discord,fake_stun;
	uint8_t fake_syndata[FAKE_MAX_TCP],seqovl_pattern[FAKE_MAX_TCP],udplen_pattern[FAKE_MAX_UDP];
	uint8_t *fsplit_pattern;
	size_t fake_syndata_size, fsplit_pattern_size;

	struct fake_tls_mod tls_mod_last;
	struct blob_item *tls_fake_last;

	struct hostfakesplit_mod hfs_mod;
	struct fakedsplit_mod fs_mod;
	struct tcp_mod tcp_mod;

	int udplen_increment;

	bool filter_ipv4,filter_ipv6;
	struct port_filters_head pf_tcp,pf_udp;
	uint32_t filter_l7;	// L7_PROTO_* bits

#ifdef HAS_FILTER_SSID
	// per profile ssid filter
	// annot use global filter because it's not possible to bind multiple instances to a single queue
	// it's possible to run multiple winws instances on the same windivert filter, but it's not the case for linux
	struct str_list_head filter_ssid;
#endif

	// list of pointers to ipsets
	struct ipset_collection_head ips_collection, ips_collection_exclude;

	// list of pointers to hostlist files
	struct hostlist_collection_head hl_collection, hl_collection_exclude;
	// pointer to autohostlist. NULL if no autohostlist for the profile.
	struct hostlist_file *hostlist_auto;
	int hostlist_auto_fail_threshold, hostlist_auto_fail_time, hostlist_auto_retrans_threshold;

	hostfail_pool *hostlist_auto_fail_counters;
};

#define PROFILE_IPSETS_ABSENT(dp) (!LIST_FIRST(&(dp)->ips_collection) && !LIST_FIRST(&(dp)->ips_collection_exclude))
#define PROFILE_IPSETS_EMPTY(dp) (ipset_collection_is_empty(&(dp)->ips_collection) && ipset_collection_is_empty(&(dp)->ips_collection_exclude))
#define PROFILE_HOSTLISTS_EMPTY(dp) (hostlist_collection_is_empty(&(dp)->hl_collection) && hostlist_collection_is_empty(&(dp)->hl_collection_exclude))
#define PROFILE_HAS_ORIG_MOD(dp) ((dp)->orig_mod_ttl || (dp)->orig_mod_ttl6 || (dp)->orig_tcp_flags_set || (dp)->orig_tcp_flags_unset)

struct desync_profile_list {
	struct desync_profile dp;
	LIST_ENTRY(desync_profile_list) next;
};
LIST_HEAD(desync_profile_list_head, desync_profile_list);
struct desync_profile_list *dp_list_add(struct desync_profile_list_head *head);
void dp_entry_destroy(struct desync_profile_list *entry);
void dp_list_destroy(struct desync_profile_list_head *head);
bool dp_list_have_autohostlist(struct desync_profile_list_head *head);
bool dp_list_need_all_out(struct desync_profile_list_head *head);
void dp_init(struct desync_profile *dp);
bool dp_fake_defaults(struct desync_profile *dp);
void dp_clear(struct desync_profile *dp);

struct params_s
{
#if !defined( __OpenBSD__) && !defined(__ANDROID__)
	wordexp_t wexp; // for file based config
#endif

	enum log_target debug_target;
	char debug_logfile[PATH_MAX];
	bool debug;

	bool daemon;

#ifdef __linux__
	int qnum;
#elif defined(BSD)
	uint16_t port; // divert port
#endif
	char bind_fix4,bind_fix6;
	uint32_t desync_fwmark; // unused in BSD

	struct desync_profile_list_head desync_profiles;

#ifdef __CYGWIN__
	struct str_list_head ssid_filter,nlm_filter;
	struct str_list_head wf_raw_part;
#else
	bool droproot;
	char *user;
	uid_t uid;
	gid_t gid[MAX_GIDS];
	int gid_count;
#endif
	char pidfile[PATH_MAX];

	char hostlist_auto_debuglog[PATH_MAX];

	// hostlist files with data for all profiles
	struct hostlist_files_head hostlists;
	// ipset files with data for all profiles
	struct ipset_files_head ipsets;

	unsigned int ctrack_t_syn, ctrack_t_est, ctrack_t_fin, ctrack_t_udp;
	t_conntrack conntrack;
	bool ctrack_disable;

	bool autottl_present;
#ifdef HAS_FILTER_SSID
	bool filter_ssid_present;
#endif

	bool cache_hostname;
	unsigned int ipcache_lifetime;
	ip_cache ipcache;
};

extern struct params_s params;
extern const char *progname;
#if !defined( __OpenBSD__) && !defined(__ANDROID__)
void cleanup_args(struct params_s *params);
#endif
void cleanup_params(struct params_s *params);

int DLOG(const char *format, ...);
int DLOG_ERR(const char *format, ...);
int DLOG_PERROR(const char *s);
int DLOG_CONDUP(const char *format, ...);
int HOSTLIST_DEBUGLOG_APPEND(const char *format, ...);
void hexdump_limited_dlog(const uint8_t *data, size_t size, size_t limit);
