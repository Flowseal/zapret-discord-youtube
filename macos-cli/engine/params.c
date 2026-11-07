#include "params.h"

#include <stdarg.h>
#include <syslog.h>
#include <errno.h>
#ifdef __ANDROID__
#include <android/log.h>
#endif

#include "pools.h"
#include "desync.h"

#ifdef __APPLE__
const char *progname = "utunws";
#elif defined(BSD)
const char *progname = "dvtws";
#elif defined(__CYGWIN__)
const char *progname = "winws";
#elif defined(__linux__)
const char *progname = "nfqws";
#else
#error UNKNOWN_SYSTEM_TIME
#endif

const char * tld[6] = { "com","org","net","edu","gov","biz" };

int DLOG_FILE(FILE *F, const char *format, va_list args)
{
	return vfprintf(F, format, args);
}
int DLOG_CON(const char *format, int syslog_priority, va_list args)
{
	return DLOG_FILE(syslog_priority==LOG_ERR ? stderr : stdout, format, args);
}
int DLOG_FILENAME(const char *filename, const char *format, va_list args)
{
	int r;
	FILE *F = fopen(filename,"at");
	if (F)
	{
		r = DLOG_FILE(F, format, args);
		fclose(F);
	}
	else
		r=-1;
	return r;
}

typedef void (*f_log_function)(int priority, const char *line);

static char log_buf[1024];
static size_t log_buf_sz=0;
static void syslog_log_function(int priority, const char *line)
{
	syslog(priority,"%s",line);
}
#ifdef __ANDROID__
static enum android_LogPriority syslog_priority_to_android(int priority)
{
	enum android_LogPriority ap;
	switch(priority)
	{
		case LOG_INFO:
		case LOG_NOTICE: ap=ANDROID_LOG_INFO; break;
		case LOG_ERR: ap=ANDROID_LOG_ERROR; break;
		case LOG_WARNING: ap=ANDROID_LOG_WARN; break;
		case LOG_EMERG:
		case LOG_ALERT:
		case LOG_CRIT: ap=ANDROID_LOG_FATAL; break;
		case LOG_DEBUG: ap=ANDROID_LOG_DEBUG; break;
		default: ap=ANDROID_LOG_UNKNOWN;
	}
	return ap;
}
static void android_log_function(int priority, const char *line)
{
	__android_log_print(syslog_priority_to_android(priority), progname, "%s", line);
}
#endif
static void log_buffered(f_log_function log_function, int syslog_priority, const char *format, va_list args)
{
	if (vsnprintf(log_buf+log_buf_sz,sizeof(log_buf)-log_buf_sz,format,args)>0)
	{
		log_buf_sz=strlen(log_buf);
		// log when buffer is full or buffer ends with \n
		if (log_buf_sz>=(sizeof(log_buf)-1) || (log_buf_sz && log_buf[log_buf_sz-1]=='\n'))
		{
			log_function(syslog_priority,log_buf);
			log_buf_sz = 0;
		}
	}
}

static int DLOG_VA(const char *format, int syslog_priority, bool condup, va_list args)
{
	int r=0;
	va_list args2;

	if (condup && !(params.debug && params.debug_target==LOG_TARGET_CONSOLE))
	{
		va_copy(args2,args);
		DLOG_CON(format,syslog_priority,args2);
		va_end(args2);
	}
	if (params.debug)
	{
		switch(params.debug_target)
		{
			case LOG_TARGET_CONSOLE:
				r = DLOG_CON(format,syslog_priority,args);
				break;
			case LOG_TARGET_FILE:
				r = DLOG_FILENAME(params.debug_logfile,format,args);
				break;
			case LOG_TARGET_SYSLOG:
				// skip newlines
				log_buffered(syslog_log_function,syslog_priority,format,args);
				r = 1;
				break;
#ifdef __ANDROID__
			case LOG_TARGET_ANDROID:
				// skip newlines
				log_buffered(android_log_function,syslog_priority,format,args);
				r = 1;
				break;
#endif
			default:
				break;
		}
	}
	return r;
}

int DLOG(const char *format, ...)
{
	int r;
	va_list args;
	va_start(args, format);
	r = DLOG_VA(format, LOG_DEBUG, false, args);
	va_end(args);
	return r;
}
int DLOG_CONDUP(const char *format, ...)
{
	int r;
	va_list args;
	va_start(args, format);
	r = DLOG_VA(format, LOG_DEBUG, true, args);
	va_end(args);
	return r;
}
int DLOG_ERR(const char *format, ...)
{
	int r;
	va_list args;
	va_start(args, format);
	r = DLOG_VA(format, LOG_ERR, true, args);
	va_end(args);
	return r;
}
int DLOG_PERROR(const char *s)
{
	return DLOG_ERR("%s: %s\n", s, strerror(errno));
}


int LOG_APPEND(const char *filename, const char *format, va_list args)
{
	int r;
	FILE *F = fopen(filename,"at");
	if (F)
	{
		fprint_localtime(F);
		fprintf(F, " : ");
		r = vfprintf(F, format, args);
		fprintf(F, "\n");
		fclose(F);
	}
	else
		r=-1;
	return r;
}

int HOSTLIST_DEBUGLOG_APPEND(const char *format, ...)
{
	if (*params.hostlist_auto_debuglog)
	{
		int r;
		va_list args;

		va_start(args, format);
		r = LOG_APPEND(params.hostlist_auto_debuglog, format, args);
		va_end(args);
		return r;
	}
	else
		return 0;
}

void hexdump_limited_dlog(const uint8_t *data, size_t size, size_t limit)
{
	size_t k;
	bool bcut = false;
	if (size > limit)
	{
		size = limit;
		bcut = true;
	}
	if (!size) return;
	for (k = 0; k < size; k++) DLOG("%02X ", data[k]);
	DLOG(bcut ? "... : " : ": ");
	for (k = 0; k < size; k++) DLOG("%c", data[k] >= 0x20 && data[k] <= 0x7F ? (char)data[k] : '.');
	if (bcut) DLOG(" ...");
}

void dp_init(struct desync_profile *dp)
{
	LIST_INIT(&dp->hl_collection);
	LIST_INIT(&dp->hl_collection_exclude);
	LIST_INIT(&dp->ips_collection);
	LIST_INIT(&dp->ips_collection_exclude);
	LIST_INIT(&dp->pf_tcp);
	LIST_INIT(&dp->pf_udp);
#ifdef HAS_FILTER_SSID
	LIST_INIT(&dp->filter_ssid);
#endif

	memcpy(dp->hostspell, "host", 4); // default hostspell
	dp->desync_skip_nosni = true;
	dp->desync_ipfrag_pos_udp = IPFRAG_UDP_DEFAULT;
	dp->desync_ipfrag_pos_tcp = IPFRAG_TCP_DEFAULT;
	dp->desync_repeats = 1;
	dp->fake_syndata_size = 16;
	dp->wscale=-1; // default - dont change scale factor (client)
	dp->desync_ttl6 = dp->dup_ttl6 = dp->orig_mod_ttl6 = 0xFF; // unused
	dp->desync_ts_increment = dp->dup_ts_increment = TS_INCREMENT_DEFAULT;
	dp->desync_badseq_increment = dp->dup_badseq_increment = BADSEQ_INCREMENT_DEFAULT;
	dp->desync_badseq_ack_increment = dp->dup_badseq_ack_increment = BADSEQ_ACK_INCREMENT_DEFAULT;
	dp->wssize_cutoff_mode = dp->desync_start_mode = dp->desync_cutoff_mode = dp->dup_start_mode = dp->dup_cutoff_mode = dp->orig_mod_start_mode = dp->orig_mod_cutoff_mode = 'n'; // packet number by default
	dp->udplen_increment = UDPLEN_INCREMENT_DEFAULT;
	dp->hostlist_auto_fail_threshold = HOSTLIST_AUTO_FAIL_THRESHOLD_DEFAULT;
	dp->hostlist_auto_fail_time = HOSTLIST_AUTO_FAIL_TIME_DEFAULT;
	dp->hostlist_auto_retrans_threshold = HOSTLIST_AUTO_RETRANS_THRESHOLD_DEFAULT;
	dp->filter_ipv4 = dp->filter_ipv6 = true;
	dp->dup_ip_id_mode = IPID_SAME;
}
bool dp_fake_defaults(struct desync_profile *dp)
{
	struct blob_item *item;
	if (blob_collection_empty(&dp->fake_http))
		if (!blob_collection_add_blob(&dp->fake_http,fake_http_request_default,strlen(fake_http_request_default),0,0))
			return false;
	if (blob_collection_empty(&dp->fake_tls))
	{
		if (!(item=blob_collection_add_blob(&dp->fake_tls,fake_tls_clienthello_default,sizeof(fake_tls_clienthello_default),4+sizeof(((struct fake_tls_mod*)0)->sni),0)))
			return false;
		if (!(item->extra2 = malloc(sizeof(struct fake_tls_mod))))
			return false;
		*(struct fake_tls_mod*)item->extra2 = dp->tls_mod_last;
	}
	if (blob_collection_empty(&dp->fake_unknown))
	{
		if (!(item=blob_collection_add_blob(&dp->fake_unknown,NULL,256,0,0)))
			return false;
		memset(item->data,0,item->size);
	}
	if (blob_collection_empty(&dp->fake_quic))
	{
		if (!(item=blob_collection_add_blob(&dp->fake_quic,NULL,620,0,0)))
			return false;
		memset(item->data,0,item->size);
		item->data[0] = 0x40;
	}
	struct blob_collection_head **fake,*fakes_z64[] = {&dp->fake_wg, &dp->fake_dht, &dp->fake_discord, &dp->fake_stun, &dp->fake_unknown_udp,NULL};
	for(fake=fakes_z64;*fake;fake++)
	{
		if (blob_collection_empty(*fake))
		{
			if (!(item=blob_collection_add_blob(*fake,NULL,64,0,0)))
				return false;
			memset(item->data,0,item->size);
		}
	}
	return true;
}
struct desync_profile_list *dp_list_add(struct desync_profile_list_head *head)
{
	struct desync_profile_list *entry = calloc(1,sizeof(struct desync_profile_list));
	if (!entry) return NULL;

	dp_init(&entry->dp);

	// add to the tail
	struct desync_profile_list *dpn,*dpl=LIST_FIRST(head);
	if (dpl)
	{
		while ((dpn=LIST_NEXT(dpl,next))) dpl = dpn;
		LIST_INSERT_AFTER(dpl, entry, next);
	}
	else
		LIST_INSERT_HEAD(head, entry, next);

	return entry;
}
static void dp_clear_dynamic(struct desync_profile *dp)
{
	free(dp->fsplit_pattern);

	hostlist_collection_destroy(&dp->hl_collection);
	hostlist_collection_destroy(&dp->hl_collection_exclude);
	ipset_collection_destroy(&dp->ips_collection);
	ipset_collection_destroy(&dp->ips_collection_exclude);
	port_filters_destroy(&dp->pf_tcp);
	port_filters_destroy(&dp->pf_udp);
#ifdef HAS_FILTER_SSID
	strlist_destroy(&dp->filter_ssid);
#endif
	HostFailPoolDestroy(&dp->hostlist_auto_fail_counters);
	struct blob_collection_head **fake,*fakes[] = {&dp->fake_http, &dp->fake_tls, &dp->fake_unknown, &dp->fake_unknown_udp, &dp->fake_quic, &dp->fake_wg, &dp->fake_dht, &dp->fake_discord, &dp->fake_stun, NULL};
	for(fake=fakes;*fake;fake++) blob_collection_destroy(*fake);
}
void dp_clear(struct desync_profile *dp)
{
	dp_clear_dynamic(dp);
	memset(dp,0,sizeof(*dp));
}
void dp_entry_destroy(struct desync_profile_list *entry)
{
	dp_clear_dynamic(&entry->dp);
	free(entry);
}
void dp_list_destroy(struct desync_profile_list_head *head)
{
	struct desync_profile_list *entry;
	while ((entry = LIST_FIRST(head)))
	{
		LIST_REMOVE(entry, next);
		dp_entry_destroy(entry);
	}
}
bool dp_list_have_autohostlist(struct desync_profile_list_head *head)
{
	struct desync_profile_list *dpl;
	LIST_FOREACH(dpl, head, next)
		if (dpl->dp.hostlist_auto)
			return true;
	return false;
}
// check if we need empty outgoing ACK
bool dp_list_need_all_out(struct desync_profile_list_head *head)
{
	struct desync_profile_list *dpl;
	LIST_FOREACH(dpl, head, next)
		if (dpl->dp.dup_repeats || PROFILE_HAS_ORIG_MOD(&dpl->dp))
			return true;
	return false;
}


#if !defined( __OpenBSD__) && !defined(__ANDROID__)
void cleanup_args(struct params_s *params)
{
	wordfree(&params->wexp);
}
#endif

void cleanup_params(struct params_s *params)
{
#if !defined( __OpenBSD__) && !defined(__ANDROID__)
	cleanup_args(params);
#endif

	ConntrackPoolDestroy(&params->conntrack);

	dp_list_destroy(&params->desync_profiles);

	hostlist_files_destroy(&params->hostlists);
	ipset_files_destroy(&params->ipsets);
	ipcacheDestroy(&params->ipcache);
#ifdef __CYGWIN__
	strlist_destroy(&params->ssid_filter);
	strlist_destroy(&params->nlm_filter);
	strlist_destroy(&params->wf_raw_part);
#else
	free(params->user); params->user=NULL;
#endif
}
