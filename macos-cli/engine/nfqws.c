#define _GNU_SOURCE

#include "nfqws.h"
#include "sec.h"
#include "desync.h"
#include "helpers.h"
#include "checksum.h"
#include "params.h"
#include "protocol.h"
#include "hostlist.h"
#include "ipset.h"
#include "gzip.h"
#include "pools.h"
#ifdef __APPLE__
#include "macos_utun.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdint.h>
#include <arpa/inet.h>
#include <getopt.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <syslog.h>
#include <grp.h>

#ifdef __CYGWIN__
#include "win.h"
#endif

#ifdef USE_SYSTEMD
#include <systemd/sd-daemon.h>
#endif

#ifdef __linux__
#include <libnetfilter_queue/libnetfilter_queue.h>
#define NF_DROP 0
#define NF_ACCEPT 1
#endif

#define CTRACK_T_SYN	60
#define CTRACK_T_FIN	60
#define CTRACK_T_EST	300
#define CTRACK_T_UDP	60

#define MAX_CONFIG_FILE_SIZE 16384

struct params_s params;
static bool bReload = false;
#ifdef __CYGWIN__
bool bQuit = false;
#endif

static void onhup(int sig)
{
	printf("HUP received ! Lists will be reloaded.\n");
	bReload = true;
}
static void ReloadCheck()
{
	if (bReload)
	{
		ResetAllHostlistsModTime();
		if (!LoadAllHostLists())
		{
			DLOG_ERR("hostlists load failed. this is fatal.\n");
			exit(1);
		}
		ResetAllIpsetModTime();
		if (!LoadAllIpsets())
		{
			DLOG_ERR("ipset load failed. this is fatal.\n");
			exit(1);
		}
		bReload = false;
	}
}

static void onusr1(int sig)
{
	printf("\nCONNTRACK DUMP\n");
	ConntrackPoolDump(&params.conntrack);
	printf("\n");
}
static void onusr2(int sig)
{
	printf("\nHOSTFAIL POOL DUMP\n");

	struct desync_profile_list *dpl;
	LIST_FOREACH(dpl, &params.desync_profiles, next)
	{
		printf("\nDESYNC PROFILE %d\n", dpl->dp.n);
		HostFailPoolDump(dpl->dp.hostlist_auto_fail_counters);
	}
	if (params.autottl_present || params.cache_hostname)
	{
		printf("\nIPCACHE\n");
		ipcachePrint(&params.ipcache);
	}
	printf("\n");
}

static void pre_desync(void)
{
	signal(SIGHUP, onhup);
	signal(SIGUSR1, onusr1);
	signal(SIGUSR2, onusr2);
}


static uint8_t processPacketData(uint32_t *mark, const char *ifin, const char *ifout, uint8_t *data_pkt, size_t *len_pkt)
{
#ifdef __linux__
	if (*mark & params.desync_fwmark)
	{
		DLOG("ignoring generated packet\n");
		return VERDICT_PASS;
	}
#endif
	return dpi_desync_packet(*mark, ifin, ifout, data_pkt, len_pkt);
}


static bool test_list_files()
{
	struct hostlist_file *hfile;
	struct ipset_file *ifile;

	LIST_FOREACH(hfile, &params.hostlists, next)
		if (hfile->filename && !file_open_test(hfile->filename, O_RDONLY))
		{
			DLOG_PERROR("file_open_test");
			DLOG_ERR("cannot access hostlist file '%s'\n", hfile->filename);
			return false;
		}
	LIST_FOREACH(ifile, &params.ipsets, next)
		if (ifile->filename && !file_open_test(ifile->filename, O_RDONLY))
		{
			DLOG_PERROR("file_open_test");
			DLOG_ERR("cannot access ipset file '%s'\n", ifile->filename);
			return false;
		}
	return true;
}


#ifdef __linux__
static int nfq_cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg, struct nfq_data *nfa, void *cookie)
{
	int id, ilen;
	size_t len;
	struct nfqnl_msg_packet_hdr *ph;
	uint8_t *data;
	uint32_t ifidx_out, ifidx_in;
	char ifout[IFNAMSIZ], ifin[IFNAMSIZ];

	ph = nfq_get_msg_packet_hdr(nfa);
	id = ph ? ntohl(ph->packet_id) : 0;

	uint32_t mark = nfq_get_nfmark(nfa);
	ilen = nfq_get_payload(nfa, &data);

	ifidx_out = nfq_get_outdev(nfa);
	*ifout = 0;
	if (ifidx_out) if_indextoname(ifidx_out, ifout);

	ifidx_in = nfq_get_indev(nfa);
	*ifin = 0;
	if (ifidx_in) if_indextoname(ifidx_in, ifin);

	DLOG("\npacket: id=%d len=%d mark=%08X ifin=%s(%u) ifout=%s(%u)\n", id, ilen, mark, ifin, ifidx_in, ifout, ifidx_out);

	if (ilen >= 0)
	{
		len = ilen;
		uint8_t verdict = processPacketData(&mark, ifin, ifout, data, &len);
		switch (verdict & VERDICT_MASK)
		{
		case VERDICT_MODIFY:
			DLOG("packet: id=%d pass modified. len=%zu\n", id, len);
			return nfq_set_verdict2(qh, id, NF_ACCEPT, mark, (uint32_t)len, data);
		case VERDICT_DROP:
			DLOG("packet: id=%d drop\n", id);
			return nfq_set_verdict2(qh, id, NF_DROP, mark, 0, NULL);
		}
	}
	DLOG("packet: id=%d pass unmodified\n", id);
	return nfq_set_verdict2(qh, id, NF_ACCEPT, mark, 0, NULL);
}
static void nfq_deinit(struct nfq_handle **h, struct nfq_q_handle **qh)
{
	if (*qh)
	{
		DLOG_CONDUP("unbinding from queue %u\n", params.qnum);
		nfq_destroy_queue(*qh);
		*qh = NULL;
	}
	if (*h)
	{
		DLOG_CONDUP("closing library handle\n");
		nfq_close(*h);
		*h = NULL;
	}
}
static bool nfq_init(struct nfq_handle **h, struct nfq_q_handle **qh)
{
	nfq_deinit(h, qh);

	DLOG_CONDUP("opening library handle\n");
	*h = nfq_open();
	if (!*h) {
		DLOG_PERROR("nfq_open()");
		goto exiterr;
	}

	DLOG_CONDUP("unbinding existing nf_queue handler for AF_INET (if any)\n");
	if (nfq_unbind_pf(*h, AF_INET) < 0) {
		DLOG_PERROR("nfq_unbind_pf()");
		goto exiterr;
	}

	DLOG_CONDUP("binding nfnetlink_queue as nf_queue handler for AF_INET\n");
	if (nfq_bind_pf(*h, AF_INET) < 0) {
		DLOG_PERROR("nfq_bind_pf()");
		goto exiterr;
	}

	DLOG_CONDUP("binding this socket to queue '%u'\n", params.qnum);
	*qh = nfq_create_queue(*h, params.qnum, &nfq_cb, &params);
	if (!*qh) {
		DLOG_PERROR("nfq_create_queue()");
		goto exiterr;
	}

	DLOG_CONDUP("setting copy_packet mode\n");
	if (nfq_set_mode(*qh, NFQNL_COPY_PACKET, 0xffff) < 0) {
		DLOG_PERROR("can't set packet_copy mode");
		goto exiterr;
	}
	if (nfq_set_queue_maxlen(*qh, Q_MAXLEN) < 0) {
		DLOG_PERROR("can't set queue maxlen");
		goto exiterr;
	}
	// accept packets if they cant be handled
	if (nfq_set_queue_flags(*qh, NFQA_CFG_F_FAIL_OPEN, NFQA_CFG_F_FAIL_OPEN))
	{
		DLOG_ERR("can't set queue flags. its OK on linux <3.6\n");
		// dot not fail. not supported on old linuxes <3.6
	}

	nfnl_rcvbufsiz(nfq_nfnlh(*h), Q_RCVBUF);

	DLOG_CONDUP("initializing raw sockets bind-fix4=%u bind-fix6=%u\n", params.bind_fix4, params.bind_fix6);
	if (!rawsend_preinit(params.bind_fix4, params.bind_fix6))
		goto exiterr;

	int yes = 1, fd = nfq_fd(*h);

#if defined SOL_NETLINK && defined NETLINK_NO_ENOBUFS
	if (setsockopt(fd, SOL_NETLINK, NETLINK_NO_ENOBUFS, &yes, sizeof(yes)) == -1)
		DLOG_PERROR("setsockopt(NETLINK_NO_ENOBUFS)");
#endif

	return true;
exiterr:
	nfq_deinit(h, qh);
	return false;
}

static void notify_ready(void)
{
#ifdef USE_SYSTEMD
	int r = sd_notify(0, "READY=1");
	if (r < 0)
		DLOG_ERR("sd_notify: %s\n", strerror(-r));
#endif
}

static int nfq_main(void)
{
	uint8_t buf[16384] __attribute__((aligned));
	struct nfq_handle *h = NULL;
	struct nfq_q_handle *qh = NULL;
	int fd, e;
	ssize_t rd;
	FILE *Fpid = NULL;

	if (*params.pidfile && !(Fpid = fopen(params.pidfile, "w")))
	{
		DLOG_PERROR("create pidfile");
		return 1;
	}

	if (params.droproot && !droproot(params.uid, params.user, params.gid, params.gid_count) || !dropcaps())
		goto err;
	print_id();
	if (params.droproot && !test_list_files())
		goto err;

	if (!nfq_init(&h, &qh))
		goto err;

#ifdef HAS_FILTER_SSID
	if (params.filter_ssid_present)
	{
		if (!wlan_info_init())
		{
			DLOG_ERR("cannot initialize wlan info capture\n");
			goto err;
		}
		DLOG("wlan info capture initialized\n");
	}
#endif

	if (params.daemon) daemonize();

	sec_harden();

	if (Fpid)
	{
		if (fprintf(Fpid, "%d", getpid()) <= 0)
		{
			DLOG_PERROR("write pidfile");
			goto err;
		}
		fclose(Fpid);
		Fpid = NULL;
	}

	pre_desync();
	notify_ready();

	fd = nfq_fd(h);
	do
	{
		while ((rd = recv(fd, buf, sizeof(buf), 0)) >= 0)
		{
			ReloadCheck();
#ifdef HAS_FILTER_SSID
			if (params.filter_ssid_present)
				if (!wlan_info_get_rate_limited())
					DLOG_ERR("cannot get wlan info\n");
#endif
			if (rd)
			{
				int r = nfq_handle_packet(h, (char *)buf, (int)rd);
				if (r<0) DLOG_ERR("nfq_handle_packet result %d, errno %d : %s\n", r, errno, strerror(errno));
			}
			else
				DLOG("recv from nfq returned 0 !\n");
		}
		e = errno;
		DLOG_ERR("recv: recv=%zd errno %d\n", rd, e);
		errno = e;
		DLOG_PERROR("recv");
		// do not fail on ENOBUFS
	} while (e == ENOBUFS);

	nfq_deinit(&h, &qh);
#ifdef HAS_FILTER_SSID
	wlan_info_deinit();
#endif
	return 0;
err:
	if (Fpid) fclose(Fpid);
	nfq_deinit(&h, &qh);
#ifdef HAS_FILTER_SSID
	wlan_info_deinit();
#endif
	return 1;
}

#elif defined(__APPLE__)

static int utun_main(void)
{
	uint8_t frame[65540] __attribute__((aligned));
	char ifname[64] = {0};
	const char *physical_iface = getenv("ZAPRET_IFACE");
	unsigned int id = 0;
	FILE *Fpid = NULL;

	if (*params.pidfile && !(Fpid = fopen(params.pidfile, "w")))
	{
		DLOG_PERROR("create pidfile");
		return 1;
	}

	DLOG_CONDUP("opening macOS utun interface\n");
	int fd = macos_utun_open(ifname, sizeof(ifname));
	if (fd < 0)
	{
		DLOG_PERROR("open utun");
		if (Fpid) fclose(Fpid);
		return 1;
	}
	DLOG_CONDUP("utun interface: %s\n", ifname);
	if (!rawsend_preinit(false, false))
	{
		DLOG_PERROR("initialize BPF sender");
		if (Fpid) fclose(Fpid);
		close(fd);
		return 1;
	}

	if (params.droproot && !droproot(params.uid, params.user, params.gid, params.gid_count))
	{
		if (Fpid) fclose(Fpid);
		close(fd);
		return 1;
	}
	print_id();
	if (params.droproot && !test_list_files())
	{
		if (Fpid) fclose(Fpid);
		close(fd);
		return 1;
	}
	if (params.daemon) daemonize();
	if (Fpid)
	{
		if (fprintf(Fpid, "%d", getpid()) <= 0)
		{
			DLOG_PERROR("write pidfile");
			fclose(Fpid);
			close(fd);
			return 1;
		}
		fclose(Fpid);
	}

	pre_desync();
	for (;;)
	{
		ssize_t rd = read(fd, frame, sizeof(frame));
		if (rd < 0)
		{
			if (errno == EINTR) continue;
			DLOG_PERROR("read utun");
			close(fd);
			return 1;
		}
		if (rd <= 4) continue;

		uint8_t *packet = frame + 4;
		size_t len = (size_t)rd - 4;
		uint8_t version = packet[0] >> 4;
		if (version != 4 && version != 6) continue;

		ReloadCheck();
		uint32_t mark = 0;
		DLOG("\npacket: id=%u len=%zu outbound utun\n", id, len);
		uint8_t verdict = processPacketData(&mark, ifname, physical_iface, packet, &len);
		switch (verdict & VERDICT_MASK)
		{
			case VERDICT_PASS:
			case VERDICT_MODIFY:
			{
				struct sockaddr_storage dst;
				memset(&dst, 0, sizeof(dst));
				if (version == 4)
					extract_endpoints((const struct ip *)packet, NULL, NULL, NULL, NULL, &dst);
				else
					extract_endpoints(NULL, (const struct ip6_hdr *)packet, NULL, NULL, NULL, &dst);
				if (!rawsend((const struct sockaddr *)&dst, mark, physical_iface, packet, len))
				{
					DLOG_PERROR("BPF reinject");
					close(fd);
					return 1;
				}
				break;
			}
			default:
				DLOG("packet: id=%u drop\n", id);
		}
		id++;
	}
}

#elif defined(BSD)

static int dvt_main(void)
{
	uint8_t buf[16384] __attribute__((aligned));
	struct sockaddr_storage sa_from;
	int fd[2] = { -1,-1 }; // 4,6
	int i, r, res = 1, fdct = 1, fdmax;
	unsigned int id = 0;
	socklen_t socklen;
	ssize_t rd, wr;
	fd_set fdset;
	FILE *Fpid = NULL;

	if (*params.pidfile && !(Fpid = fopen(params.pidfile, "w")))
	{
		DLOG_PERROR("create pidfile");
		return 1;
	}

	{
		struct sockaddr_in bp4;
		bp4.sin_family = AF_INET;
		bp4.sin_port = htons(params.port);
		bp4.sin_addr.s_addr = INADDR_ANY;

		DLOG_CONDUP("creating divert4 socket\n");
		fd[0] = socket_divert(AF_INET);
		if (fd[0] == -1) {
			DLOG_PERROR("socket (DIVERT4)");
			goto exiterr;
		}
		DLOG_CONDUP("binding divert4 socket\n");
		if (bind(fd[0], (struct sockaddr*)&bp4, sizeof(bp4)) < 0)
		{
			DLOG_PERROR("bind (DIVERT4)");
			goto exiterr;
		}
	}


#ifdef __OpenBSD__
	{
		// in OpenBSD must use separate divert sockets for ipv4 and ipv6
		struct sockaddr_in6 bp6;
		memset(&bp6, 0, sizeof(bp6));
		bp6.sin6_family = AF_INET6;
		bp6.sin6_port = htons(params.port);

		DLOG_CONDUP("creating divert6 socket\n");
		fd[1] = socket_divert(AF_INET6);
		if (fd[1] == -1) {
			DLOG_PERROR("socket (DIVERT6)");
			goto exiterr;
		}
		DLOG_CONDUP("binding divert6 socket\n");
		if (bind(fd[1], (struct sockaddr*)&bp6, sizeof(bp6)) < 0)
		{
			DLOG_PERROR("bind (DIVERT6)");
			goto exiterr;
		}
		fdct++;
	}
#endif
	fdmax = (fd[0] > fd[1] ? fd[0] : fd[1]) + 1;

	DLOG_CONDUP("initializing raw sockets\n");
	if (!rawsend_preinit(false, false))
		goto exiterr;


	if (params.droproot && !droproot(params.uid, params.user, params.gid, params.gid_count))
		goto exiterr;
	print_id();
	if (params.droproot && !test_list_files())
		goto exiterr;

	if (params.daemon) daemonize();

	if (Fpid)
	{
		if (fprintf(Fpid, "%d", getpid()) <= 0)
		{
			DLOG_PERROR("write pidfile");
			goto exiterr;
		}
		fclose(Fpid);
		Fpid = NULL;
	}

	pre_desync();

	for (;;)
	{
		FD_ZERO(&fdset);
		for (i = 0; i < fdct; i++) FD_SET(fd[i], &fdset);
		r = select(fdmax, &fdset, NULL, NULL, NULL);
		if (r == -1)
		{
			if (errno == EINTR)
			{
				// a signal received
				continue;
			}
			DLOG_PERROR("select");
			goto exiterr;
		}
		for (i = 0; i < fdct; i++)
		{
			if (FD_ISSET(fd[i], &fdset))
			{
				socklen = sizeof(sa_from);
				rd = recvfrom(fd[i], buf, sizeof(buf), 0, (struct sockaddr*)&sa_from, &socklen);
				if (rd < 0)
				{
					DLOG_PERROR("recvfrom");
					goto exiterr;
				}
				else if (rd > 0)
				{
					uint32_t mark = 0;
					uint8_t verdict;
					size_t len = rd;

					ReloadCheck();

					DLOG("\npacket: id=%u len=%zu\n", id, len);
					verdict = processPacketData(&mark, NULL, NULL, buf, &len);
					switch (verdict & VERDICT_MASK)
					{
					case VERDICT_PASS:
					case VERDICT_MODIFY:
						if ((verdict & VERDICT_MASK) == VERDICT_PASS)
							DLOG("packet: id=%u reinject unmodified\n", id);
						else
							DLOG("packet: id=%u reinject modified len=%zu\n", id, len);
						wr = sendto(fd[i], buf, len, 0, (struct sockaddr*)&sa_from, socklen);
						if (wr < 0)
							DLOG_PERROR("reinject sendto");
						else if (wr != len)
							DLOG_ERR("reinject sendto: not all data was reinjected. received %zu, sent %zd\n", len, wr);
						break;
					default:
						DLOG("packet: id=%u drop\n", id);
					}
					id++;
				}
				else
				{
					DLOG("unexpected zero size recvfrom\n");
				}
			}
		}
	}

	res = 0;
exiterr:
	if (Fpid) fclose(Fpid);
	if (fd[0] != -1) close(fd[0]);
	if (fd[1] != -1) close(fd[1]);
	return res;
}


#elif defined (__CYGWIN__)

static int win_main(const char *windivert_filter)
{
	size_t len;
	unsigned int id;
	uint8_t verdict;
	bool bOutbound;
	uint8_t packet[16384];
	uint32_t mark;
	WINDIVERT_ADDRESS wa;
	char ifname[IFNAMSIZ];

	if (params.daemon) daemonize();

	if (*params.pidfile && !writepid(params.pidfile))
	{
		DLOG_ERR("could not write pidfile");
		return ERROR_TOO_MANY_OPEN_FILES; // code 4 = The system cannot open the file
	}

	if (!win_dark_init(&params.ssid_filter, &params.nlm_filter))
	{
		DLOG_ERR("win_dark_init failed. win32 error %u (0x%08X)\n", w_win32_error, w_win32_error);
		return w_win32_error;
	}

	pre_desync();

	for (;;)
	{
		if (!logical_net_filter_match())
		{
			DLOG_CONDUP("logical network is not present. waiting it to appear.\n");
			do
			{
				if (bQuit)
				{
					DLOG("QUIT requested\n");
					win_dark_deinit();
					return 0;
				}
				usleep(500000);
			} while (!logical_net_filter_match());
			DLOG_CONDUP("logical network now present\n");
		}

		if (!windivert_init(windivert_filter))
		{
			win_dark_deinit();
			return w_win32_error;
		}

		DLOG_CONDUP("windivert initialized. capture is started.\n");

		for (id = 0;; id++)
		{
			len = sizeof(packet);
			if (!windivert_recv(packet, &len, &wa))
			{
				if (errno == ENOBUFS)
				{
					DLOG("windivert: ignoring too large packet\n");
					continue; // too large packet
				}
				else if (errno == ENODEV)
				{
					DLOG_CONDUP("logical network disappeared. deinitializing windivert.\n");
					rawsend_cleanup();
					break;
				}
				else if (errno == EINTR)
				{
					DLOG("QUIT requested\n");
					win_dark_deinit();
					return 0;
				}
				DLOG_ERR("windivert: recv failed. errno %d\n", errno);
				win_dark_deinit();
				return w_win32_error;
			}

			ReloadCheck();

			*ifname = 0;
			snprintf(ifname, sizeof(ifname), "%u.%u", wa.Network.IfIdx, wa.Network.SubIfIdx);
			DLOG("\npacket: id=%u len=%zu %s IPv6=%u IPChecksum=%u TCPChecksum=%u UDPChecksum=%u IfIdx=%u.%u\n", id, len, wa.Outbound ? "outbound" : "inbound", wa.IPv6, wa.IPChecksum, wa.TCPChecksum, wa.UDPChecksum, wa.Network.IfIdx, wa.Network.SubIfIdx);
			if (wa.Impostor)
			{
				DLOG("windivert: passing impostor packet\n");
				verdict = VERDICT_PASS;
			}
			else if (wa.Loopback)
			{
				DLOG("windivert: passing loopback packet\n");
				verdict = VERDICT_PASS;
			}
			else
			{
				mark = 0;
				// pseudo interface id IfIdx.SubIfIdx
				verdict = processPacketData(&mark, ifname, ifname, packet, &len);
			}
			switch (verdict & VERDICT_MASK)
			{
			case VERDICT_PASS:
			case VERDICT_MODIFY:
				if ((verdict & VERDICT_MASK) == VERDICT_PASS)
					DLOG("packet: id=%u reinject unmodified\n", id);
				else
					DLOG("packet: id=%u reinject modified len=%zu\n", id, len);
				if (!windivert_send(packet, len, &wa))
					DLOG_ERR("windivert: reinject of packet id=%u failed\n", id);
				break;
			default:
				DLOG("packet: id=%u drop\n", id);
			}
		}
	}
	win_dark_deinit();
	return 0;
}

#endif // multiple OS divert handlers




static void exit_clean(int code)
{
	cleanup_params(&params);
	exit(code);
}


static bool parse_uid(const char *opt, uid_t *uid, gid_t *gid, int *gid_count, int max_gids)
{
	unsigned int u;
	char c, *p, *e;

	*gid_count = 0;
	if ((e = strchr(optarg, ':'))) *e++ = 0;
	if (sscanf(opt, "%u", &u) != 1) return false;
	*uid = (uid_t)u;
	for (p = e; p; )
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}
		if (p)
		{
			if (sscanf(p, "%u", &u) != 1) return false;
			if (*gid_count >= max_gids) return false;
			gid[(*gid_count)++] = (gid_t)u;
		}
		if (e) *e++ = c;
		p = e;
	}
	return true;
}

static bool parse_ws_scale_factor(char *s, uint16_t *wsize, uint8_t *wscale)
{
	int v;
	char *p;

	if ((p = strchr(s, ':'))) *p++ = 0;
	v = atoi(s);
	if (v < 0 || v>65535)
	{
		DLOG_ERR("bad wsize\n");
		return false;
	}
	*wsize = (uint16_t)v;
	if (p && *p)
	{
		v = atoi(p);
		if (v < 0 || v>255)
		{
			DLOG_ERR("bad wscale\n");
			return false;
		}
		*wscale = (uint8_t)v;
	}
	return true;
}

static bool parse_cutoff(const char *opt, unsigned int *value, char *mode)
{
	*mode = (*opt == 'n' || *opt == 'd' || *opt == 's') ? *opt++ : 'n';
	return sscanf(opt, "%u", value) > 0;
}
static bool parse_net32_signed(const char *opt, uint32_t *value)
{
	if (((opt[0] == '0' && opt[1] == 'x') || (opt[0] == '-' && opt[1] == '0' && opt[2] == 'x')) && sscanf(opt + 2 + (opt[0] == '-'), "%X", (int32_t*)value) > 0)
	{
		if (opt[0] == '-') *value = -*value;
		return true;
	}
	else
	{
		return sscanf(opt, "%d", (int32_t*)value) > 0;
	}
}
static void load_file_or_exit(const char *filename, void *buf, size_t *size, size_t *offset)
{
	size_t ofs;

	// 0xaabbcc
	// filename
	// @filename
	// +123@filename

	if (offset) *offset = 0;
	if (filename[0] == '0' && filename[1] == 'x')
	{
		if (!parse_hex_str(filename + 2, buf, size) || !*size)
		{
			DLOG_ERR("invalid hex string: %s\n", filename + 2);
			exit_clean(1);
		}
		DLOG("read %zu bytes from hex string\n", *size);
	}
	else
	{
		ofs = 0;
		if (filename[0] == '+')
		{
			filename++;
			if (sscanf(filename, "%zu", &ofs) != 1)
			{
				DLOG("offset read error: %s\n", filename);
				exit_clean(1);
			}
			while (*filename && *filename != '@') filename++;
			if (*filename == '@') filename++;
		}
		else if (filename[0] == '@')
			filename++;
		if (!load_file_nonempty(filename, buf, size))
		{
			DLOG_ERR("could not read %s\n", filename);
			exit_clean(1);
		}
		DLOG("read %zu bytes from '%s'. offset=%zu\n", *size, filename, ofs);
		if (ofs >= *size)
		{
			DLOG("'%s' : offset %zu is out of data range %zu\n", filename, ofs, *size);
			exit_clean(1);
		}
		if (offset)
			*offset = ofs;
		else
			memmove(buf, (uint8_t*)buf + ofs, *size -= ofs);
	}
}

static bool parse_autottl(const char *s, autottl *t, int8_t def_delta, uint8_t def_min, uint8_t def_max)
{
	bool neg = true;
	unsigned int delta, min, max;

	t->delta = def_delta;
	t->min = def_min;
	t->max = def_max;
	if (s)
	{
		// "-" means disable
		if (s[0] == '-' && s[1] == 0)
			memset(t, 0, sizeof(*t));
		else
		{
			max = t->max;
			if (*s == '+')
			{
				neg = false;
				s++;
			}
			else if (*s == '-')
				s++;
			switch (sscanf(s, "%u:%u-%u", &delta, &min, &max))
			{
			case 3:
				if ((delta && !max) || max > 255) return false;
				t->max = (uint8_t)max;
			case 2:
				if ((delta && !min) || min > 255 || min > max) return false;
				t->min = (uint8_t)min;
			case 1:
				if (delta > 127) return false;
				t->delta = (int8_t)(neg ? -delta : delta);
				break;
			default:
				return false;
			}
		}
	}
	return true;
}

static bool parse_l7_list(char *opt, uint32_t *l7)
{
	char *e, *p, c;

	for (p = opt, *l7 = 0; p; )
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (!strcmp(p, "http"))
			*l7 |= L7_PROTO_HTTP;
		else if (!strcmp(p, "tls"))
			*l7 |= L7_PROTO_TLS;
		else if (!strcmp(p, "quic"))
			*l7 |= L7_PROTO_QUIC;
		else if (!strcmp(p, "wireguard"))
			*l7 |= L7_PROTO_WIREGUARD;
		else if (!strcmp(p, "dht"))
			*l7 |= L7_PROTO_DHT;
		else if (!strcmp(p, "discord"))
			*l7 |= L7_PROTO_DISCORD;
		else if (!strcmp(p, "stun"))
			*l7 |= L7_PROTO_STUN;
		else if (!strcmp(p, "unknown"))
			*l7 |= L7_PROTO_UNKNOWN;
		else return false;

		if (e) *e++ = c;
		p = e;
	}
	return true;
}

static bool parse_pf_list(char *opt, struct port_filters_head *pfl)
{
	char *e, *p, c;
	port_filter pf;
	bool b;

	for (p = opt; p; )
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}

		b = pf_parse(p, &pf) && port_filter_add(pfl, &pf);
		if (e) *e++ = c;
		if (!b) return false;

		p = e;
	}
	return true;
}

static bool wf_make_l3(char *opt, bool *ipv4, bool *ipv6)
{
	char *e, *p, c;

	for (p = opt, *ipv4 = *ipv6 = false; p; )
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (!strcmp(p, "ipv4"))
			*ipv4 = true;
		else if (!strcmp(p, "ipv6"))
			*ipv6 = true;
		else return false;

		if (e) *e++ = c;
		p = e;
	}
	return true;
}

static bool parse_httpreqpos(const char *s, struct proto_pos *sp)
{
	if (!strcmp(s, "method"))
	{
		sp->marker = PM_HTTP_METHOD;
		sp->pos = 2;
	}
	else if (!strcmp(s, "host"))
	{
		sp->marker = PM_HOST;
		sp->pos = 1;
	}
	else
		return false;
	return true;
}
static bool parse_tlspos(const char *s, struct proto_pos *sp)
{
	if (!strcmp(s, "sni"))
	{
		sp->marker = PM_HOST;
		sp->pos = 1;
	}
	else if (!strcmp(s, "sniext"))
	{
		sp->marker = PM_SNI_EXT;
		sp->pos = 1;
	}
	else if (!strcmp(s, "snisld"))
	{
		sp->marker = PM_HOST_MIDSLD;
		sp->pos = 0;
	}
	else
		return false;
	return true;
}

static bool parse_int16(const char *p, int16_t *v)
{
	if (*p == '+' || *p == '-' || *p >= '0' && *p <= '9')
	{
		int i = atoi(p);
		*v = (int16_t)i;
		return *v == i; // check overflow
	}
	return false;
}
static bool parse_posmarker(const char *opt, uint8_t *posmarker)
{
	if (!strcmp(opt, "host"))
		*posmarker = PM_HOST;
	else if (!strcmp(opt, "endhost"))
		*posmarker = PM_HOST_END;
	else if (!strcmp(opt, "sld"))
		*posmarker = PM_HOST_SLD;
	else if (!strcmp(opt, "midsld"))
		*posmarker = PM_HOST_MIDSLD;
	else if (!strcmp(opt, "endsld"))
		*posmarker = PM_HOST_ENDSLD;
	else if (!strcmp(opt, "method"))
		*posmarker = PM_HTTP_METHOD;
	else if (!strcmp(opt, "sniext"))
		*posmarker = PM_SNI_EXT;
	else
		return false;
	return true;
}
static bool parse_split_pos(char *opt, struct proto_pos *split)
{
	if (parse_int16(opt, &split->pos))
	{
		split->marker = PM_ABS;
		return !!split->pos;
	}
	else
	{
		char c, *p = opt;
		bool b;

		for (; *opt && *opt != '+' && *opt != '-'; opt++);
		c = *opt; *opt = 0;
		b = parse_posmarker(p, &split->marker);
		*opt = c;
		if (!b) return false;
		if (*opt)
			return parse_int16(opt, &split->pos);
		else
			split->pos = 0;
	}
	return true;
}
static bool parse_split_pos_list(char *opt, struct proto_pos *splits, int splits_size, int *split_count)
{
	char c, *e, *p;

	for (p = opt, *split_count = 0; p && *split_count < splits_size; (*split_count)++)
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}
		if (!parse_split_pos(p, splits + *split_count)) return false;
		if (e) *e++ = c;
		p = e;
	}
	if (p) return false; // too much splits
	return true;
}

static bool parse_domain_list(char *opt, hostlist_pool **pp)
{
	char *e, *p, c;

	for (p = opt; p; )
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (*p && !AppendHostlistItem(pp, p)) return false;

		if (e) *e++ = c;
		p = e;
	}
	return true;
}

static bool parse_ip_list(char *opt, ipset *pp)
{
	char *e, *p, c;

	for (p = opt; p; )
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (*p && !AppendIpsetItem(pp, p)) return false;

		if (e) *e++ = c;
		p = e;
	}
	return true;
}

static bool parse_tlsmod_list(char *opt, struct fake_tls_mod *tls_mod)
{
	char *e, *e2, *p, c, c2;

	tls_mod->mod &= FAKE_TLS_MOD_SAVE_MASK;
	tls_mod->mod |= FAKE_TLS_MOD_SET;
	for (p = opt; p; )
	{
		for (e2 = p; *e2 && *e2 != ',' && *e2 != '='; e2++);

		if ((e = strchr(e2, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (*e2 == '=')
		{
			c2 = *e2;
			*e2 = 0;
		}
		else
			e2 = NULL;

		if (!strcmp(p, "rnd"))
			tls_mod->mod |= FAKE_TLS_MOD_RND;
		else if (!strcmp(p, "rndsni"))
			tls_mod->mod |= FAKE_TLS_MOD_RND_SNI;
		else if (!strcmp(p, "sni"))
		{
			tls_mod->mod |= FAKE_TLS_MOD_SNI;
			if (!e2 || !e2[1] || e2[1] == ',') goto err;
			strncpy(tls_mod->sni, e2 + 1, sizeof(tls_mod->sni) - 1);
			tls_mod->sni[sizeof(tls_mod->sni) - 1 - 1] = 0;
		}
		else if (!strcmp(p, "padencap"))
			tls_mod->mod |= FAKE_TLS_MOD_PADENCAP;
		else if (!strcmp(p, "dupsid"))
			tls_mod->mod |= FAKE_TLS_MOD_DUP_SID;
		else if (strcmp(p, "none"))
			goto err;

		if (e2) *e2 = c2;
		if (e) *e++ = c;
		p = e;
	}
	return true;
err:
	if (e2) *e2 = c2;
	if (e) *e++ = c;
	return false;
}

static bool parse_hostfakesplit_mod(char *opt, struct hostfakesplit_mod *hfs_mod)
{
	char *e, *e2, *p, c, c2;

	for (p = opt; p; )
	{
		for (e2 = p; *e2 && *e2 != ',' && *e2 != '='; e2++);

		if ((e = strchr(e2, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (*e2 == '=')
		{
			c2 = *e2;
			*e2 = 0;
		}
		else
			e2 = NULL;

		if (!strcmp(p, "host"))
		{
			if (!e2 || !e2[1] || e2[1] == ',') goto err;
			strncpy(hfs_mod->host, e2 + 1, sizeof(hfs_mod->host) - 1);
			hfs_mod->host[sizeof(hfs_mod->host) - 1 - 1] = 0;
			hfs_mod->host_size = strlen(hfs_mod->host); // cache value
		}
		else if (!strcmp(p, "altorder"))
		{
			if (!e2 || !e2[1] || e2[1] == ',') goto err;
			hfs_mod->ordering = atoi(e2 + 1);
			if (hfs_mod->ordering < 0 || hfs_mod->ordering>1) goto err;
		}
		else if (strcmp(p, "none"))
			goto err;

		if (e2) *e2 = c2;
		if (e) *e++ = c;
		p = e;
	}
	return true;
err:
	if (e2) *e2 = c2;
	if (e) *e++ = c;
	return false;
}

static bool parse_fakedsplit_mod(char *opt, struct fakedsplit_mod *fs_mod)
{
	char *e, *e2, *p, c, c2;

	for (p = opt; p; )
	{
		for (e2 = p; *e2 && *e2 != ',' && *e2 != '='; e2++);

		if ((e = strchr(e2, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (*e2 == '=')
		{
			c2 = *e2;
			*e2 = 0;
		}
		else
			e2 = NULL;

		if (!strcmp(p, "altorder"))
		{
			if (!e2 || !e2[1] || e2[1] == ',') goto err;
			fs_mod->ordering = atoi(e2 + 1);
			// unsplitted altorder in 0x03 mask. 0x04 reserved. splitted altorder in 0x18 mask
			if ((fs_mod->ordering & 0xFFFFFFE4) || (((fs_mod->ordering>>3) & 3)>2)) goto err;
		}
		else if (strcmp(p, "none"))
			goto err;

		if (e2) *e2 = c2;
		if (e) *e++ = c;
		p = e;
	}
	return true;
err:
	if (e2) *e2 = c2;
	if (e) *e++ = c;
	return false;
}

static bool parse_tcpmod(char *opt, struct tcp_mod *tcp_mod)
{
	char *e, *e2, *p, c, c2;

	for (p = opt; p; )
	{
		for (e2 = p; *e2 && *e2 != ',' && *e2 != '='; e2++);

		if ((e = strchr(e2, ',')))
		{
			c = *e;
			*e = 0;
		}

		if (*e2 == '=')
		{
			c2 = *e2;
			*e2 = 0;
		}
		else
			e2 = NULL;

		if (!strcmp(p, "seq"))
		{
			tcp_mod->seq = true;
		}
		else if (strcmp(p, "none"))
			goto err;

		if (e2) *e2 = c2;
		if (e) *e++ = c;
		p = e;
	}
	return true;
err:
	if (e2) *e2 = c2;
	if (e) *e++ = c;
	return false;
}

static bool parse_fooling(char *opt, unsigned int *fooling_mode)
{
	char *e, *p = opt;
	while (p)
	{
		e = strchr(p, ',');
		if (e) *e++ = 0;
		if (!strcmp(p, "md5sig"))
			*fooling_mode |= FOOL_MD5SIG;
		else if (!strcmp(p, "ts"))
			*fooling_mode |= FOOL_TS;
		else if (!strcmp(p, "badsum"))
			*fooling_mode |= FOOL_BADSUM;
		else if (!strcmp(p, "badseq"))
			*fooling_mode |= FOOL_BADSEQ;
		else if (!strcmp(p, "datanoack"))
			*fooling_mode |= FOOL_DATANOACK;
		else if (!strcmp(p, "hopbyhop"))
			*fooling_mode |= FOOL_HOPBYHOP;
		else if (!strcmp(p, "hopbyhop2"))
			*fooling_mode |= FOOL_HOPBYHOP2;
		else if (strcmp(p, "none"))
			return false;
		p = e;
	}
	return true;
}

static bool parse_strlist(char *opt, struct str_list_head *list)
{
	char *e, *p = optarg;
	while (p)
	{
		e = strchr(p, ',');
		if (e) *e++ = 0;
		if (*p && !strlist_add(list, p))
			return false;
		p = e;
	}
	return true;
}

static bool parse_tcpflags(char *opt, uint16_t *fl)
{
	unsigned int u;
	char *e, *p, c;

	if (sscanf(optarg, "0x%X", &u)<=0 && sscanf(optarg, "%u", &u)<=0)
	{
		*fl=0;
		for (p = opt; p; )
		{
			if ((e = strchr(p, ',')))
			{
				c = *e;
				*e = 0;
			}

			if (!strcasecmp(p, "FIN"))
				*fl |= TH_FIN;
			else if (!strcasecmp(p, "SYN"))
				*fl |= TH_SYN;
			else if (!strcasecmp(p, "RST"))
				*fl |= TH_RST;
			else if (!strcasecmp(p, "PSH") || !strcasecmp(p, "PUSH"))
				*fl |= TH_PUSH;
			else if (!strcasecmp(p, "ACK"))
				*fl |= TH_ACK;
			else if (!strcasecmp(p, "URG"))
				*fl |= TH_URG;
			else if (!strcasecmp(p, "ECE"))
				*fl |= 0x40;
			else if (!strcasecmp(p, "CWR"))
				*fl |= 0x80;
			else if (!strcasecmp(p, "AE") || !strcasecmp(p, "AECN") || !strcasecmp(p, "ACCECN"))
				*fl |= 0x100;
			else if (!strcasecmp(p, "R1"))
				*fl |= 0x200;
			else if (!strcasecmp(p, "R2"))
				*fl |= 0x400;
			else if (!strcasecmp(p, "R3"))
				*fl |= 0x800;
			else
				return false;
			if (e) *e++ = c;
			p = e;
		}

		return true;
	}
	else
	{
		*fl = u & 0xFFF;
		return *fl==u;
	}
}



static void split_compat(struct desync_profile *dp)
{
	if (!dp->split_count)
	{
		dp->splits[dp->split_count].marker = PM_ABS;
		dp->splits[dp->split_count].pos = 2;
		dp->split_count++;
	}
	if ((dp->seqovl.marker != PM_ABS || dp->seqovl.pos < 0) && (dp->desync_mode == DESYNC_FAKEDSPLIT || dp->desync_mode == DESYNC_MULTISPLIT || dp->desync_mode2 == DESYNC_FAKEDSPLIT || dp->desync_mode2 == DESYNC_MULTISPLIT))
	{
		DLOG_ERR("split seqovl supports only absolute positive positions\n");
		exit_clean(1);
	}
}

static void SplitDebug(void)
{
	struct desync_profile_list *dpl;
	const struct desync_profile *dp;
	LIST_FOREACH(dpl, &params.desync_profiles, next)
	{
		dp = &dpl->dp;
		for (int x = 0; x < dp->split_count; x++)
			DLOG("profile %d multisplit %s %d\n", dp->n, posmarker_name(dp->splits[x].marker), dp->splits[x].pos);
		if (!PROTO_POS_EMPTY(&dp->seqovl)) DLOG("profile %d seqovl %s %d\n", dp->n, posmarker_name(dp->seqovl.marker), dp->seqovl.pos);
		if (!PROTO_POS_EMPTY(&dp->hostfakesplit_midhost)) DLOG("profile %d hostfakesplit midhost %s %d\n", dp->n, posmarker_name(dp->hostfakesplit_midhost.marker), dp->hostfakesplit_midhost.pos);
	}
}

static bool onetime_tls_mod_blob(int profile_n, int fake_n, const struct fake_tls_mod *tls_mod, uint8_t *fake_tls, size_t *fake_tls_size, size_t fake_tls_buf_size, struct fake_tls_mod_cache *modcache)
{
	const uint8_t *ext;
	size_t extlen;

	modcache->extlen_offset = modcache->padlen_offset = 0;
	if (tls_mod->mod & (FAKE_TLS_MOD_RND_SNI | FAKE_TLS_MOD_SNI | FAKE_TLS_MOD_PADENCAP))
	{
		if (!TLSFindExtLen(fake_tls, *fake_tls_size, &modcache->extlen_offset))
		{
			DLOG_ERR("profile %d fake[%d] padencap set but tls fake structure invalid\n", profile_n, fake_n);
			return false;
		}
		DLOG("profile %d fake[%d] tls extensions length offset : %zu\n", profile_n, fake_n, modcache->extlen_offset);
		if (tls_mod->mod & (FAKE_TLS_MOD_RND_SNI | FAKE_TLS_MOD_SNI))
		{
			size_t slen;
			if (!TLSFindExt(fake_tls, *fake_tls_size, 0, &ext, &extlen, false))
			{
				DLOG_ERR("profile %d fake[%d] sni mod is set but tls fake does not have SNI\n", profile_n, fake_n);
				return false;
			}
			uint8_t *sniext = fake_tls + (ext - fake_tls);
			if (!TLSAdvanceToHostInSNI(&ext, &extlen, &slen))
			{
				DLOG_ERR("profile %d fake[%d] sni set but tls fake has invalid SNI structure\n", profile_n, fake_n);
				return false;
			}
			uint8_t *sni = fake_tls + (ext - fake_tls);
			if (tls_mod->mod & FAKE_TLS_MOD_SNI)
			{
				size_t slen_new = strlen(tls_mod->sni);
				ssize_t slen_delta = slen_new - slen;
				char *s1 = NULL;
				if (params.debug)
				{
					if ((s1 = malloc(slen + 1)))
					{
						memcpy(s1, sni, slen); s1[slen] = 0;
					}
				}
				if (slen_delta)
				{
					if ((*fake_tls_size + slen_delta) > fake_tls_buf_size)
					{
						DLOG_ERR("profile %d fake[%d] not enough space for new SNI\n", profile_n, fake_n);
						free(s1);
						return false;
					}
					memmove(sni + slen_new, sni + slen, fake_tls + *fake_tls_size - (sni + slen));
					phton16(fake_tls + 3, (uint16_t)(pntoh16(fake_tls + 3) + slen_delta));
					phton24(fake_tls + 6, (uint32_t)(pntoh24(fake_tls + 6) + slen_delta));
					phton16(fake_tls + modcache->extlen_offset, (uint16_t)(pntoh16(fake_tls + modcache->extlen_offset) + slen_delta));
					phton16(sniext - 2, (uint16_t)(pntoh16(sniext - 2) + slen_delta));
					phton16(sniext, (uint16_t)(pntoh16(sniext) + slen_delta));
					phton16(sni - 2, (uint16_t)(pntoh16(sni - 2) + slen_delta));
					*fake_tls_size += slen_delta;
					slen = slen_new;
				}
				DLOG("profile %d fake[%d] change SNI : %s => %s size_delta=%zd\n", profile_n, fake_n, s1, tls_mod->sni, slen_delta);
				free(s1);

				memcpy(sni, tls_mod->sni, slen_new);
			}
			if (tls_mod->mod & FAKE_TLS_MOD_RND_SNI)
			{
				if (!slen)
				{
					DLOG_ERR("profile %d fake[%d] rndsni set but tls fake has zero sized SNI\n", profile_n, fake_n);
					return false;
				}

				char *s1 = NULL, *s2 = NULL;
				if (params.debug)
				{
					if ((s1 = malloc(slen + 1)))
					{
						memcpy(s1, sni, slen); s1[slen] = 0;
					}
				}

				fill_random_az(sni, 1);
				if (slen >= 7) // domain name in SNI must be at least 3 chars long to enable xxx.tls randomization
				{
					fill_random_az09(sni + 1, slen - 5);
					sni[slen - 4] = '.';
					memcpy(sni + slen - 3, tld[random() % (sizeof(tld) / sizeof(*tld))], 3);
				}
				else
					fill_random_az09(sni + 1, slen - 1);

				if (params.debug)
				{
					if (s1 && (s2 = malloc(slen + 1)))
					{
						memcpy(s2, sni, slen); s2[slen] = 0;
						DLOG("profile %d fake[%d] generated random SNI : %s -> %s\n", profile_n, fake_n, s1, s2);
					}
					free(s1); free(s2);
				}
			}
		}
		if (tls_mod->mod & FAKE_TLS_MOD_PADENCAP)
		{
			if (TLSFindExt(fake_tls, *fake_tls_size, 21, &ext, &extlen, false))
			{
				if ((ext - fake_tls + extlen) != *fake_tls_size)
				{
					DLOG_ERR("profile %d fake[%d] tls padding ext is present but it's not at the end. padding ext offset %zu, padding ext size %zu, fake size %zu\n", profile_n, fake_n, ext - fake_tls, extlen, *fake_tls_size);
					return false;
				}
				modcache->padlen_offset = ext - fake_tls - 2;
				DLOG("profile %d fake[%d] tls padding ext is present, padding length offset %zu\n", profile_n, fake_n, modcache->padlen_offset);
			}
			else
			{
				if ((*fake_tls_size + 4) > fake_tls_buf_size)
				{
					DLOG_ERR("profile %d fake[%d] tls padding is absent and there's no space to add it\n", profile_n, fake_n);
					return false;
				}
				phton16(fake_tls + *fake_tls_size, 21);
				*fake_tls_size += 2;
				modcache->padlen_offset = *fake_tls_size;
				phton16(fake_tls + *fake_tls_size, 0);
				*fake_tls_size += 2;
				phton16(fake_tls + modcache->extlen_offset, pntoh16(fake_tls + modcache->extlen_offset) + 4);
				phton16(fake_tls + 3, pntoh16(fake_tls + 3) + 4); // increase tls record len
				phton24(fake_tls + 6, pntoh24(fake_tls + 6) + 4); // increase tls handshake len
				DLOG("profile %d fake[%d] tls padding is absent. added. padding length offset %zu\n", profile_n, fake_n, modcache->padlen_offset);
			}
		}
	}
	return true;
}
static bool onetime_tls_mod(struct desync_profile *dp)
{
	struct blob_item *fake_tls;
	struct fake_tls_mod *tls_mod;
	int n = 0;

	LIST_FOREACH(fake_tls, &dp->fake_tls, next)
	{
		++n;
		tls_mod = (struct fake_tls_mod *)fake_tls->extra2;
		if (!tls_mod) continue;
		if (dp->n && !(tls_mod->mod & (FAKE_TLS_MOD_SET | FAKE_TLS_MOD_CUSTOM_FAKE)))
			tls_mod->mod |= FAKE_TLS_MOD_RND | FAKE_TLS_MOD_RND_SNI | FAKE_TLS_MOD_DUP_SID; // old behavior compat + dup_sid
		if (!(tls_mod->mod & ~FAKE_TLS_MOD_SAVE_MASK))
			continue;

		if (!IsTLSClientHello(fake_tls->data, fake_tls->size, false) || (fake_tls->size < (44 + fake_tls->data[43]))) // has session id ?
		{
			DLOG("profile %d fake[%d] tls mod set but tls fake structure invalid.\n", dp->n, n);
			return false;
		}
		if (!fake_tls->extra)
		{
			fake_tls->extra = malloc(sizeof(struct fake_tls_mod_cache));
			if (!fake_tls->extra) return false;
		}
		if (!onetime_tls_mod_blob(dp->n, n, tls_mod, fake_tls->data, &fake_tls->size, fake_tls->size_buf, (struct fake_tls_mod_cache*)fake_tls->extra))
			return false;
		if (fake_tls->offset >= fake_tls->size)
		{
			DLOG("profile %d fake[%d] tls mod shrinked data to %zu and offset %zu is now out of data range\n", dp->n, n, fake_tls->size, fake_tls->offset);
			return false;
		}
	}
	return true;
}

static struct blob_item *load_blob_to_collection(const char *filename, struct blob_collection_head *blobs, size_t max_size, size_t size_reserve)
{
	struct blob_item *blob = blob_collection_add(blobs);
	uint8_t *p;

	if (!blob || (!(blob->data = malloc(max_size + size_reserve))))
	{
		DLOG_ERR("out of memory\n");
		exit_clean(1);
	}
	blob->size = max_size;
	load_file_or_exit(filename, blob->data, &blob->size, &blob->offset);
	p = realloc(blob->data, blob->size + size_reserve);
	if (!p)
	{
		DLOG_ERR("out of memory\n");
		exit_clean(1);
	}
	blob->data = p;
	blob->size_buf = blob->size + size_reserve;
	return blob;
}
static struct blob_item *load_const_blob_to_collection(const void *data, size_t sz, struct blob_collection_head *blobs, size_t size_reserve, size_t offset)
{
	if (offset >= sz)
	{
		DLOG_ERR("offset %zu is out of data range %zu\n", offset, sz);
		exit_clean(1);
	}
	struct blob_item *blob = blob_collection_add(blobs);
	if (!blob || (!(blob->data = malloc(sz + size_reserve))))
	{
		DLOG_ERR("out of memory\n");
		exit_clean(1);
	}
	blob->size = sz;
	blob->size_buf = sz + size_reserve;
	blob->offset = offset;
	memcpy(blob->data, data, sz);
	return blob;
}


#ifdef __CYGWIN__
static bool wf_make_pf(char *opt, const char *l4, const char *portname, char *buf, size_t len)
{
	char *e, *p, c, s1[64];
	port_filter pf;
	int n;

	if (len < 3) return false;

	for (n = 0, p = opt, *buf = '(', buf[1] = 0; p; n++)
	{
		if ((e = strchr(p, ',')))
		{
			c = *e;
			*e = 0;
		}
		if (!pf_parse(p, &pf)) return false;

		if (pf.from == pf.to)
			snprintf(s1, sizeof(s1), "(%s.%s %s %u)", l4, portname, pf.neg ? "!=" : "==", pf.from);
		else
			snprintf(s1, sizeof(s1), "(%s.%s %s %u %s %s.%s %s %u)", l4, portname, pf.neg ? "<" : ">=", pf.from, pf.neg ? "or" : "and", l4, portname, pf.neg ? ">" : "<=", pf.to);
		if (n) strncat(buf, " or ", len - strlen(buf) - 1);
		strncat(buf, s1, len - strlen(buf) - 1);

		if (e) *e++ = c;
		p = e;
	}
	strncat(buf, ")", len - strlen(buf) - 1);
	return true;
}

#define DIVERT_NO_LOCALNETSv4_DST "(" \
                   "(ip.DstAddr < 127.0.0.1 or ip.DstAddr > 127.255.255.255) and " \
                   "(ip.DstAddr < 10.0.0.0 or ip.DstAddr > 10.255.255.255) and " \
                   "(ip.DstAddr < 192.168.0.0 or ip.DstAddr > 192.168.255.255) and " \
                   "(ip.DstAddr < 172.16.0.0 or ip.DstAddr > 172.31.255.255) and " \
                   "(ip.DstAddr < 169.254.0.0 or ip.DstAddr > 169.254.255.255))"
#define DIVERT_NO_LOCALNETSv4_SRC "(" \
                   "(ip.SrcAddr < 127.0.0.1 or ip.SrcAddr > 127.255.255.255) and " \
                   "(ip.SrcAddr < 10.0.0.0 or ip.SrcAddr > 10.255.255.255) and " \
                   "(ip.SrcAddr < 192.168.0.0 or ip.SrcAddr > 192.168.255.255) and " \
                   "(ip.SrcAddr < 172.16.0.0 or ip.SrcAddr > 172.31.255.255) and " \
                   "(ip.SrcAddr < 169.254.0.0 or ip.SrcAddr > 169.254.255.255))"

#define DIVERT_NO_LOCALNETSv6_DST "(" \
                   "(ipv6.DstAddr > ::1) and " \
                   "(ipv6.DstAddr < 2001::0 or ipv6.DstAddr >= 2001:1::0) and " \
                   "(ipv6.DstAddr < fc00::0 or ipv6.DstAddr >= fe00::0) and " \
                   "(ipv6.DstAddr < fe80::0 or ipv6.DstAddr >= fec0::0) and " \
                   "(ipv6.DstAddr < ff00::0 or ipv6.DstAddr >= ffff::0))"
#define DIVERT_NO_LOCALNETSv6_SRC "(" \
                   "(ipv6.SrcAddr > ::1) and " \
                   "(ipv6.SrcAddr < 2001::0 or ipv6.SrcAddr >= 2001:1::0) and " \
                   "(ipv6.SrcAddr < fc00::0 or ipv6.SrcAddr >= fe00::0) and " \
                   "(ipv6.SrcAddr < fe80::0 or ipv6.SrcAddr >= fec0::0) and " \
                   "(ipv6.SrcAddr < ff00::0 or ipv6.SrcAddr >= ffff::0))"

#define DIVERT_NO_LOCALNETS_SRC "(" DIVERT_NO_LOCALNETSv4_SRC " or " DIVERT_NO_LOCALNETSv6_SRC ")"
#define DIVERT_NO_LOCALNETS_DST "(" DIVERT_NO_LOCALNETSv4_DST " or " DIVERT_NO_LOCALNETSv6_DST ")"

#define DIVERT_TCP_NOT_EMPTY "(!tcp or tcp.Syn or tcp.Rst or tcp.Fin or tcp.PayloadLength>0)"
#define DIVERT_TCP_INBOUNDS "(tcp.Ack and tcp.Syn or tcp.Rst or tcp.Fin)"

// HTTP/1.? 30(2|7)
#define DIVERT_HTTP_REDIRECT "tcp.PayloadLength>=12 and tcp.Payload32[0]==0x48545450 and tcp.Payload16[2]==0x2F31 and tcp.Payload[6]==0x2E and tcp.Payload16[4]==0x2033 and tcp.Payload[10]==0x30 and (tcp.Payload[11]==0x32 or tcp.Payload[11]==0x37)"

#define DIVERT_PROLOG "!impostor and !loopback"

static bool wf_make_filter(
	char *wf, size_t len,
	unsigned int IfIdx, unsigned int SubIfIdx,
	bool ipv4, bool ipv6,
	const char *pf_tcp_src, const char *pf_tcp_dst,
	const char *pf_udp_src, const char *pf_udp_dst,
	const struct str_list_head *wf_raw_part,
	bool bFilterOutLAN)
{
	char pf_dst_buf[8192], iface[64];
	struct str_list *wfpart;
	int n;
	const char *pf_dst;
	const char *f_tcpin = *pf_tcp_src ? dp_list_have_autohostlist(&params.desync_profiles) ? "(" DIVERT_TCP_INBOUNDS " or (" DIVERT_HTTP_REDIRECT "))" : DIVERT_TCP_INBOUNDS : "";
	const char *f_tcp_not_empty = (*pf_tcp_src && !dp_list_need_all_out(&params.desync_profiles)) ? DIVERT_TCP_NOT_EMPTY " and " : "";
	snprintf(iface, sizeof(iface), " ifIdx=%u and subIfIdx=%u and", IfIdx, SubIfIdx);

	snprintf(wf, len, "%s and%s%s\n(",
		DIVERT_PROLOG,
		IfIdx ? iface : "",
		ipv4 ? ipv6 ? "" : " ip and" : " ipv6 and"
	);

	n = 0;
	if (!LIST_EMPTY(wf_raw_part))
	{
		LIST_FOREACH(wfpart, wf_raw_part, next)
		{
			snprintf(wf + strlen(wf), len - strlen(wf), "%s(\n%s\n )", n ? "\n or\n " : "\n ", wfpart->str);
			n++;
		}
	}

	if (*pf_tcp_src || *pf_udp_src)
	{
		if (*pf_tcp_src && *pf_udp_src)
		{
			snprintf(pf_dst_buf, sizeof(pf_dst_buf), "(%s or %s)", pf_tcp_dst, pf_udp_dst);
			pf_dst = pf_dst_buf;
		}
		else
			pf_dst = *pf_tcp_dst ? pf_tcp_dst : pf_udp_dst;

		snprintf(wf + strlen(wf), len - strlen(wf), n++ ? "\n or\n " : "\n ");

		snprintf(wf + strlen(wf), len - strlen(wf),
			"(\n  (outbound and %s%s)\n  or\n  (inbound and tcp%s%s%s%s%s)\n )",
			f_tcp_not_empty,
			pf_dst,
			*pf_tcp_src ? "" : " and false",
			*f_tcpin ? " and " : "",
			*f_tcpin ? f_tcpin : "",
			*pf_tcp_src ? " and " : "",
			*pf_tcp_src ? pf_tcp_src : "");

	}
	strncat(wf, "\n)", len - strlen(wf) - 1);

	if (bFilterOutLAN)
		snprintf(wf + strlen(wf), len - strlen(wf), "\nand\n(\n outbound and %s\n or\n inbound and %s\n)\n",
			ipv4 ? ipv6 ? DIVERT_NO_LOCALNETS_DST : DIVERT_NO_LOCALNETSv4_DST : DIVERT_NO_LOCALNETSv6_DST,
			ipv4 ? ipv6 ? DIVERT_NO_LOCALNETS_SRC : DIVERT_NO_LOCALNETSv4_SRC : DIVERT_NO_LOCALNETSv6_SRC);

	return true;
}

static unsigned int hash_jen(const void *data, unsigned int len)
{
	unsigned int hash;
	HASH_JEN(data, len, hash);
	return hash;
}

#endif


static void exithelp(void)
{
	printf(
#if !defined( __OpenBSD__) && !defined(__ANDROID__)
		" @<config_file>|$<config_file>\t\t\t\t; read file for options. must be the only argument. other options are ignored.\n\n"
#endif
#ifdef __ANDROID__
		" --debug=0|1|syslog|android|@<filename>\n"
#else
		" --debug=0|1|syslog|@<filename>\n"
#endif
		" --version\t\t\t\t\t\t; print version and exit\n"
		" --dry-run\t\t\t\t\t\t; verify parameters and exit with code 0 if successful\n"
		" --comment=any_text\n"
#ifdef __linux__
		" --qnum=<nfqueue_number>\n"
#elif defined(BSD) && !defined(__APPLE__)
		" --port=<port>\t\t\t\t\t\t; divert port\n"
#endif
		" --daemon\t\t\t\t\t\t; daemonize\n"
		" --pidfile=<filename>\t\t\t\t\t; write pid to file\n"
#ifndef __CYGWIN__
		" --user=<username>\t\t\t\t\t; drop root privs\n"
		" --uid=uid[:gid1,gid2,...]\t\t\t\t; drop root privs\n"
#endif
#ifdef __linux__
		" --bind-fix4\t\t\t\t\t\t; apply outgoing interface selection fix for generated ipv4 packets\n"
		" --bind-fix6\t\t\t\t\t\t; apply outgoing interface selection fix for generated ipv6 packets\n"
#endif
		" --ctrack-timeouts=S:E:F[:U]\t\t\t\t; internal conntrack timeouts for TCP SYN, ESTABLISHED, FIN stages, UDP timeout. default %u:%u:%u:%u\n"
		" --ctrack-disable=[0|1]\t\t\t\t\t; 1 or no argument disables conntrack\n"
		" --ipcache-lifetime=<int>\t\t\t\t; time in seconds to keep cached hop count and domain name (default %u). 0 = no expiration\n"
		" --ipcache-hostname=[0|1]\t\t\t\t; 1 or no argument enables ip->hostname caching\n"
#ifdef __CYGWIN__
		"\nWINDIVERT FILTER:\n"
		" --wf-iface=<int>[.<int>]\t\t\t\t; numeric network interface and subinterface indexes\n"
		" --wf-l3=ipv4|ipv6\t\t\t\t\t; L3 protocol filter. multiple comma separated values allowed.\n"
		" --wf-tcp=[~]port1[-port2]\t\t\t\t; TCP port filter. ~ means negation. multiple comma separated values allowed.\n"
		" --wf-udp=[~]port1[-port2]\t\t\t\t; UDP port filter. ~ means negation. multiple comma separated values allowed.\n"
		" --wf-raw-part=<filter>|@<filename>\t\t\t; partial raw windivert filter string or filename\n"
		" --wf-filter-lan=0|1\t\t\t\t\t; add excluding filter for non-global IP (default : 1)\n"
		" --wf-raw=<filter>|@<filename>\t\t\t\t; full raw windivert filter string or filename. replaces --wf-tcp,--wf-udp,--wf-raw-part\n"
		" --wf-save=<filename>\t\t\t\t\t; save windivert filter string to a file and exit\n"
		"\nLOGICAL NETWORK FILTER:\n"
		" --ssid-filter=ssid1[,ssid2,ssid3,...]\t\t\t; enable winws only if any of specified wifi SSIDs connected\n"
		" --nlm-filter=net1[,net2,net3,...]\t\t\t; enable winws only if any of specified NLM network is connected. names and GUIDs are accepted.\n"
		" --nlm-list[=all]\t\t\t\t\t; list Network List Manager (NLM) networks. connected only or all.\n"
#endif
		"\nMULTI-STRATEGY:\n"
		" --new\t\t\t\t\t\t\t; begin new strategy\n"
		" --skip\t\t\t\t\t\t\t; do not use this strategy\n"
		" --filter-l3=ipv4|ipv6\t\t\t\t\t; L3 protocol filter. multiple comma separated values allowed.\n"
		" --filter-tcp=[~]port1[-port2]|*\t\t\t; TCP port filter. ~ means negation. setting tcp and not setting udp filter denies udp. comma separated list allowed.\n"
		" --filter-udp=[~]port1[-port2]|*\t\t\t; UDP port filter. ~ means negation. setting udp and not setting tcp filter denies tcp. comma separated list allowed.\n"
		" --filter-l7=[http|tls|quic|wireguard|dht|discord|stun|unknown] ; L6-L7 protocol filter. multiple comma separated values allowed.\n"
#ifdef HAS_FILTER_SSID
		" --filter-ssid=ssid1[,ssid2,ssid3,...]\t\t\t; per profile wifi SSID filter\n"
#endif
		" --ipset=<filename>\t\t\t\t\t; ipset include filter (one ip/CIDR per line, ipv4 and ipv6 accepted, gzip supported, multiple ipsets allowed)\n"
		" --ipset-ip=<ip_list>\t\t\t\t\t; comma separated fixed subnet list\n"
		" --ipset-exclude=<filename>\t\t\t\t; ipset exclude filter (one ip/CIDR per line, ipv4 and ipv6 accepted, gzip supported, multiple ipsets allowed)\n"
		" --ipset-exclude-ip=<ip_list>\t\t\t\t; comma separated fixed subnet list\n"
		"\nHOSTLIST FILTER:\n"
		" --hostlist=<filename>\t\t\t\t\t; apply dpi desync only to the listed hosts (one host per line, subdomains auto apply, gzip supported, multiple hostlists allowed)\n"
		" --hostlist-domains=<domain_list>\t\t\t; comma separated fixed domain list\n"
		" --hostlist-exclude=<filename>\t\t\t\t; do not apply dpi desync to the listed hosts (one host per line, subdomains auto apply, gzip supported, multiple hostlists allowed)\n"
		" --hostlist-exclude-domains=<domain_list>\t\t; comma separated fixed domain list\n"
		" --hostlist-auto=<filename>\t\t\t\t; detect DPI blocks and build hostlist automatically\n"
		" --hostlist-auto-fail-threshold=<int>\t\t\t; how many failed attempts cause hostname to be added to auto hostlist (default : %d)\n"
		" --hostlist-auto-fail-time=<int>\t\t\t; all failed attemps must be within these seconds (default : %d)\n"
		" --hostlist-auto-retrans-threshold=<int>\t\t; how many request retransmissions cause attempt to fail (default : %d)\n"
		" --hostlist-auto-debug=<logfile>\t\t\t; debug auto hostlist positives\n"
		"\nTAMPER:\n"
		" --wsize=<window_size>[:<scale_factor>]\t\t\t; set window size. 0 = do not modify. OBSOLETE !\n"
		" --wssize=<window_size>[:<scale_factor>]\t\t; set window size for server. 0 = do not modify. default scale_factor = 0.\n"
		" --wssize-cutoff=[n|d|s]N\t\t\t\t; apply server wsize only to packet numbers (n, default), data packet numbers (d), relative sequence (s) less than N\n"
		" --wssize-forced-cutoff=0|1\t\t\t\t; 1(default)=auto cutoff wssize on known protocol\n"
		" --synack-split=[syn|synack|acksyn]\t\t\t; perform TCP split handshake : send SYN only, SYN+ACK or ACK+SYN\n"
		" --orig-ttl=<int>\t\t\t\t\t; set TTL for original packets\n"
		" --orig-ttl6=<int>\t\t\t\t\t; set ipv6 hop limit for original packets. by default ttl value is used\n"
		" --orig-autottl=[<delta>[:<min>[-<max>]]|-]\t\t; auto ttl mode for both ipv4 and ipv6. default: +%d:%u-%u\n"
		" --orig-autottl6=[<delta>[:<min>[-<max>]]|-]\t\t; overrides --orig-autottl for ipv6 only\n"
		" --orig-tcp-flags-set=<int|0xHEX|flaglist>\t\t; set these tcp flags (flags |= value). value can be int, hex or comma separated list : FIN,SYN,RST,PSH,ACK,URG,ECE,CWR,AE,R1,R2,R3\n"
		" --orig-tcp-flags-unset=<int|0xHEX|flaglist>\t\t; unset these tcp flags (flags &= ~value)\n"
		" --orig-mod-start=[n|d|s]N\t\t\t\t; apply orig TTL mod to packet numbers (n, default), data packet numbers (d), relative sequence (s) greater or equal than N\n"
		" --orig-mod-cutoff=[n|d|s]N\t\t\t\t; apply orig TTL mod to packet numbers (n, default), data packet numbers (d), relative sequence (s) less than N\n"
		" --dup=<int>\t\t\t\t\t\t; duplicate original packets. send N dups before original.\n"
		" --dup-replace=[0|1]\t\t\t\t\t; 1 or no argument means do not send original, only dups\n"
		" --dup-ttl=<int>\t\t\t\t\t; set TTL for dups\n"
		" --dup-ttl6=<int>\t\t\t\t\t; set ipv6 hop limit for dups. by default ttl value is used\n"
		" --dup-autottl=[<delta>[:<min>[-<max>]]|-]\t\t; auto ttl mode for both ipv4 and ipv6. default: %d:%u-%u\n"
		" --dup-autottl6=[<delta>[:<min>[-<max>]]|-]\t\t; overrides --dup-autottl for ipv6 only\n"
		" --dup-tcp-flags-set=<int|0xHEX|flaglist>\t\t; set these tcp flags (flags |= value). value can be int, hex or comma separated list : FIN,SYN,RST,PSH,ACK,URG,ECE,CWR,AE,R1,R2,R3\n"
		" --dup-tcp-flags-unset=<int|0xHEX|flaglist>\t\t; unset these tcp flags (flags &= ~value)\n"
		" --dup-fooling=<mode>[,<mode>]\t\t\t\t; can use multiple comma separated values. modes : none md5sig badseq badsum datanoack ts hopbyhop hopbyhop2\n"
		" --dup-ts-increment=<int|0xHEX>\t\t\t\t; ts fooling TSval signed increment for dup. default %d\n"
		" --dup-badseq-increment=<int|0xHEX>\t\t\t; badseq fooling seq signed increment for dup. default %d\n"
		" --dup-badack-increment=<int|0xHEX>\t\t\t; badseq fooling ackseq signed increment for dup. default %d\n"
		" --dup-ip-id=same|zero|seq|rnd\t\t\t\t; ipv4 ip_id mode for dupped packets\n"
		" --dup-start=[n|d|s]N\t\t\t\t\t; apply dup to packet numbers (n, default), data packet numbers (d), relative sequence (s) greater or equal than N\n"
		" --dup-cutoff=[n|d|s]N\t\t\t\t\t; apply dup to packet numbers (n, default), data packet numbers (d), relative sequence (s) less than N\n"
		" --hostcase\t\t\t\t\t\t; change Host: => host:\n"
		" --hostspell\t\t\t\t\t\t; exact spelling of \"Host\" header. must be 4 chars. default is \"host\"\n"
		" --hostnospace\t\t\t\t\t\t; remove space after Host: and add it to User-Agent: to preserve packet size\n"
		" --domcase\t\t\t\t\t\t; mix domain case : Host: TeSt.cOm\n"
		" --methodeol\t\t\t\t\t\t; add '\\n' before method and remove space from Host:\n"
		" --ip-id=zero|seq|seqgroup|rnd\t\t\t\t; ipv4 ip_id assignment scheme\n"
		" --dpi-desync=[<mode0>,]<mode>[,<mode2>]\t\t; try to desync dpi state. modes :\n"
		"\t\t\t\t\t\t\t; synack syndata fake fakeknown rst rstack hopbyhop destopt ipfrag1\n"
		"\t\t\t\t\t\t\t; multisplit multidisorder fakedsplit fakeddisorder hostfakesplit ipfrag2 udplen tamper\n"
#ifdef __linux__
		" --dpi-desync-fwmark=<int|0xHEX>\t\t\t; override fwmark for desync packet. default = 0x%08X (%u)\n"
#elif defined(SO_USER_COOKIE)
		" --dpi-desync-sockarg=<int|0xHEX>\t\t\t; override sockarg (SO_USER_COOKIE) for desync packet. default = 0x%08X (%u)\n"
#endif
		" --dpi-desync-ttl=<int>\t\t\t\t\t; set ttl for fakes packets\n"
		" --dpi-desync-ttl6=<int>\t\t\t\t; set ipv6 hop limit for fake packet. by default --dpi-desync-ttl value is used.\n"
		" --dpi-desync-autottl=[<delta>[:<min>[-<max>]]|-]\t; auto ttl mode for both ipv4 and ipv6. default: %d:%u-%u\n"
		" --dpi-desync-autottl6=[<delta>[:<min>[-<max>]]|-]\t; overrides --dpi-desync-autottl for ipv6 only\n"
		" --dpi-desync-tcp-flags-set=<int|0xHEX|flaglist>\t; set these tcp flags (flags |= value). value can be int, hex or comma separated list : FIN,SYN,RST,PSH,ACK,URG,ECE,CWR,AE,R1,R2,R3\n"
		" --dpi-desync-tcp-flags-unset=<int|0xHEX|flaglist>\t; unset these tcp flags (flags &= ~value)\n"
		" --dpi-desync-fooling=<mode>[,<mode>]\t\t\t; can use multiple comma separated values. modes : none md5sig badseq badsum datanoack ts hopbyhop hopbyhop2\n"
		" --dpi-desync-repeats=<N>\t\t\t\t; send every desync packet N times\n"
		" --dpi-desync-skip-nosni=0|1\t\t\t\t; 1(default)=do not act on ClientHello without SNI\n"
		" --dpi-desync-split-pos=N|-N|marker+N|marker-N\t\t; comma separated list of split positions\n"
		"\t\t\t\t\t\t\t; markers: method,host,endhost,sld,endsld,midsld,sniext\n"
		"\t\t\t\t\t\t\t; full list is only used by multisplit and multidisorder\n"
		"\t\t\t\t\t\t\t; fakedsplit/fakeddisorder use first l7-protocol-compatible parameter if present, first abs value otherwise\n"
		" --dpi-desync-split-seqovl=N|-N|marker+N|marker-N\t; use sequence overlap before first sent original split segment\n"
		" --dpi-desync-split-seqovl-pattern=[+ofs]@<filename>|0xHEX ; pattern for the fake part of overlap\n"
		" --dpi-desync-fakedsplit-pattern=[+ofs]@<filename>|0xHEX ; fake pattern for fakedsplit/fakeddisorder\n"
		" --dpi-desync-fakedsplit-mod=mod[,mod]\t\t\t; mods can be none,altorder=0|1|2|3 + 0|8|16\n"
		" --dpi-desync-hostfakesplit-midhost=marker+N|marker-N\t; additionally split real hostname at specified marker. must be within host..endhost or won't be splitted.\n"
		" --dpi-desync-hostfakesplit-mod=mod[,mod]\t\t; mods can be none,host=<hostname>,altorder=0|1\n"
		" --dpi-desync-ipfrag-pos-udp=<8..%u>\t\t\t; ip frag position starting from the transport header. multiple of 8, default %u.\n"
		" --dpi-desync-ipfrag-pos-tcp=<8..%u>\t\t\t; ip frag position starting from the transport header. multiple of 8, default %u.\n"
		" --dpi-desync-ts-increment=<int|0xHEX>\t\t\t; ts fooling TSval signed increment. default %d\n"
		" --dpi-desync-badseq-increment=<int|0xHEX>\t\t; badseq fooling seq signed increment. default %d\n"
		" --dpi-desync-badack-increment=<int|0xHEX>\t\t; badseq fooling ackseq signed increment. default %d\n"
		" --dpi-desync-any-protocol=0|1\t\t\t\t; 0(default)=desync only http and tls  1=desync any nonempty data packet\n"
		" --dpi-desync-fake-tcp-mod=mod[,mod]\t\t\t; comma separated list of tcp fake mods. available mods : none,seq\n"
		" --dpi-desync-fake-http=[+ofs]@<filename>|0xHEX\t\t; fake http request\n"
		" --dpi-desync-fake-tls=[+ofs]@<filename>|0xHEX|![+offset] ; fake TLS ClientHello (for https)\n"
		" --dpi-desync-fake-tls-mod=mod[,mod]\t\t\t; comma separated list of TLS fake mods. available mods : none,rnd,rndsni,sni=<sni>,dupsid,padencap\n"
		" --dpi-desync-fake-unknown=[+ofs]@<filename>|0xHEX\t; unknown protocol fake payload\n"
		" --dpi-desync-fake-syndata=[+ofs]@<filename>|0xHEX\t; SYN data payload\n"
		" --dpi-desync-fake-quic=[+ofs]@<filename>|0xHEX\t\t; fake QUIC Initial\n"
		" --dpi-desync-fake-wireguard=[+ofs]@<filename>|0xHEX\t; fake wireguard handshake initiation\n"
		" --dpi-desync-fake-dht=[+ofs]@<filename>|0xHEX\t\t; DHT protocol fake payload (d1...e)\n"
		" --dpi-desync-fake-discord=[+ofs]@<filename>|0xHEX\t; discord protocol fake payload (Voice IP Discovery)\n"
		" --dpi-desync-fake-stun=[+ofs]@<filename>|0xHEX\t\t; STUN protocol fake payload\n"
		" --dpi-desync-fake-unknown-udp=[+ofs]@<filename>|0xHEX\t; unknown udp protocol fake payload\n"
		" --dpi-desync-udplen-increment=<int>\t\t\t; increase or decrease udp packet length by N bytes (default %u). negative values decrease length.\n"
		" --dpi-desync-udplen-pattern=[+ofs]@<filename>|0xHEX\t; udp tail fill pattern\n"
		" --dpi-desync-start=[n|d|s]N\t\t\t\t; apply dpi desync only to packet numbers (n, default), data packet numbers (d), relative sequence (s) greater or equal than N\n"
		" --dpi-desync-cutoff=[n|d|s]N\t\t\t\t; apply dpi desync only to packet numbers (n, default), data packet numbers (d), relative sequence (s) less than N\n",
		CTRACK_T_SYN, CTRACK_T_EST, CTRACK_T_FIN, CTRACK_T_UDP,
		IPCACHE_LIFETIME,
		HOSTLIST_AUTO_FAIL_THRESHOLD_DEFAULT, HOSTLIST_AUTO_FAIL_TIME_DEFAULT, HOSTLIST_AUTO_RETRANS_THRESHOLD_DEFAULT,
		AUTOTTL_DEFAULT_ORIG_DELTA, AUTOTTL_DEFAULT_ORIG_MIN, AUTOTTL_DEFAULT_ORIG_MAX,
		AUTOTTL_DEFAULT_DUP_DELTA, AUTOTTL_DEFAULT_DUP_MIN, AUTOTTL_DEFAULT_DUP_MAX,
		TS_INCREMENT_DEFAULT, BADSEQ_INCREMENT_DEFAULT, BADSEQ_ACK_INCREMENT_DEFAULT,
#if defined(__linux__) || defined(SO_USER_COOKIE)
		DPI_DESYNC_FWMARK_DEFAULT, DPI_DESYNC_FWMARK_DEFAULT,
#endif
		AUTOTTL_DEFAULT_DESYNC_DELTA, AUTOTTL_DEFAULT_DESYNC_MIN, AUTOTTL_DEFAULT_DESYNC_MAX,
		DPI_DESYNC_MAX_FAKE_LEN, IPFRAG_UDP_DEFAULT,
		DPI_DESYNC_MAX_FAKE_LEN, IPFRAG_TCP_DEFAULT,
		TS_INCREMENT_DEFAULT, BADSEQ_INCREMENT_DEFAULT, BADSEQ_ACK_INCREMENT_DEFAULT,
		UDPLEN_INCREMENT_DEFAULT
	);
	exit(1);
}
static void exithelp_clean(void)
{
	cleanup_params(&params);
	exithelp();
}

#if !defined( __OpenBSD__) && !defined(__ANDROID__)
// no static to not allow optimizer to inline this func (save stack)
void config_from_file(const char *filename)
{
	// config from a file
	char buf[MAX_CONFIG_FILE_SIZE];
	buf[0] = 'x';	// fake argv[0]
	buf[1] = ' ';
	size_t bufsize = sizeof(buf) - 3;
	if (!load_file(filename, buf + 2, &bufsize))
	{
		DLOG_ERR("could not load config file '%s'\n", filename);
		exit_clean(1);
	}
	buf[bufsize + 2] = 0;
	// wordexp fails if it sees \t \n \r between args
	replace_char(buf, '\n', ' ');
	replace_char(buf, '\r', ' ');
	replace_char(buf, '\t', ' ');
	if (wordexp(buf, &params.wexp, WRDE_NOCMD))
	{
		DLOG_ERR("failed to split command line options from file '%s'\n", filename);
		exit_clean(1);
	}
}
#endif

void check_dp(const struct desync_profile *dp)
{
	// only linux has connbytes limiter
	if ((dp->desync_any_proto && !dp->desync_cutoff &&
		(dp->desync_mode == DESYNC_FAKE || dp->desync_mode == DESYNC_RST || dp->desync_mode == DESYNC_RSTACK ||
			dp->desync_mode == DESYNC_FAKEDSPLIT || dp->desync_mode == DESYNC_FAKEDDISORDER || dp->desync_mode == DESYNC_HOSTFAKESPLIT ||
			dp->desync_mode2 == DESYNC_FAKEDSPLIT || dp->desync_mode2 == DESYNC_FAKEDDISORDER || dp->desync_mode2 == DESYNC_HOSTFAKESPLIT))
		||
		dp->dup_repeats && !dp->dup_cutoff)
	{
#ifdef __linux__
		DLOG_CONDUP("WARNING !!! in profile %d you are using --dpi-desync-any-protocol without --dpi-desync-cutoff or --dup without --dup-cutoff\n", dp->n);
		DLOG_CONDUP("WARNING !!! it's completely ok if connbytes or payload based ip/nf tables limiter is applied. Make sure it exists.\n");
#else
		DLOG_CONDUP("WARNING !!! possible TRASH FLOOD configuration detected in profile %d\n", dp->n);
		DLOG_CONDUP("WARNING !!! in profile %d you are using --dpi-desync-any-protocol without --dpi-desync-cutoff or --dup without --dup-cutoff\n", dp->n);
		DLOG_CONDUP("WARNING !!! fakes or dups will be sent on every processed packet\n");
		DLOG_CONDUP("WARNING !!! make sure it's really what you want\n");
#ifdef __CYGWIN__
		DLOG_CONDUP("WARNING !!! in most cases this is acceptable only with custom payload based windivert filter (--wf-raw, --wf-raw-part)\n");
#endif
#endif
	}
}

#define STRINGIFY(x) #x
#define TOSTRING(x) STRINGIFY(x)
#if defined(ZAPRET_GH_VER) || defined (ZAPRET_GH_HASH)
#ifdef __ANDROID__
#define PRINT_VER printf("github android version %s (%s)\n\n", TOSTRING(ZAPRET_GH_VER), TOSTRING(ZAPRET_GH_HASH))
#else
#define PRINT_VER printf("github version %s (%s)\n\n", TOSTRING(ZAPRET_GH_VER), TOSTRING(ZAPRET_GH_HASH))
#endif
#else
#ifdef __ANDROID__
#define PRINT_VER printf("self-built android version %s %s\n\n", __DATE__, __TIME__)
#else
#define PRINT_VER printf("self-built version %s %s\n\n", __DATE__, __TIME__)
#endif
#endif

enum opt_indices {
	IDX_DEBUG,
	IDX_DRY_RUN,
	IDX_VERSION,
	IDX_COMMENT,
#ifdef __linux__
	IDX_QNUM,
#elif defined(BSD)
	IDX_PORT,
#endif
	IDX_DAEMON,
	IDX_PIDFILE,
#ifndef __CYGWIN__
	IDX_USER,
	IDX_UID,
#endif
	IDX_WSIZE,
	IDX_WSSIZE,
	IDX_WSSIZE_CUTOFF,
	IDX_WSSIZE_FORCED_CUTOFF,
	IDX_SYNACK_SPLIT,
	IDX_CTRACK_TIMEOUTS,
	IDX_CTRACK_DISABLE,
	IDX_IPCACHE_LIFETIME,
	IDX_IPCACHE_HOSTNAME,
	IDX_HOSTCASE,
	IDX_HOSTSPELL,
	IDX_HOSTNOSPACE,
	IDX_DOMCASE,
	IDX_METHODEOL,
	IDX_IP_ID,
	IDX_DPI_DESYNC,
#ifdef __linux__
	IDX_DPI_DESYNC_FWMARK,
#elif defined(SO_USER_COOKIE)
	IDX_DPI_DESYNC_SOCKARG,
#endif
	IDX_DUP,
	IDX_DUP_TTL,
	IDX_DUP_TTL6,
	IDX_DUP_AUTOTTL,
	IDX_DUP_AUTOTTL6,
	IDX_DUP_TCP_FLAGS_SET,
	IDX_DUP_TCP_FLAGS_UNSET,
	IDX_DUP_FOOLING,
	IDX_DUP_TS_INCREMENT,
	IDX_DUP_BADSEQ_INCREMENT,
	IDX_DUP_BADACK_INCREMENT,
	IDX_DUP_REPLACE,
	IDX_DUP_IP_ID,
	IDX_DUP_START,
	IDX_DUP_CUTOFF,
	IDX_ORIG_TTL,
	IDX_ORIG_TTL6,
	IDX_ORIG_AUTOTTL,
	IDX_ORIG_AUTOTTL6,
	IDX_ORIG_TCP_FLAGS_SET,
	IDX_ORIG_TCP_FLAGS_UNSET,
	IDX_ORIG_MOD_START,
	IDX_ORIG_MOD_CUTOFF,
	IDX_DPI_DESYNC_TTL,
	IDX_DPI_DESYNC_TTL6,
	IDX_DPI_DESYNC_AUTOTTL,
	IDX_DPI_DESYNC_AUTOTTL6,
	IDX_DPI_DESYNC_TCP_FLAGS_SET,
	IDX_DPI_DESYNC_TCP_FLAGS_UNSET,
	IDX_DPI_DESYNC_FOOLING,
	IDX_DPI_DESYNC_REPEATS,
	IDX_DPI_DESYNC_SKIP_NOSNI,
	IDX_DPI_DESYNC_SPLIT_POS,
	IDX_DPI_DESYNC_SPLIT_HTTP_REQ,
	IDX_DPI_DESYNC_SPLIT_TLS,
	IDX_DPI_DESYNC_SPLIT_SEQOVL,
	IDX_DPI_DESYNC_SPLIT_SEQOVL_PATTERN,
	IDX_DPI_DESYNC_FAKEDSPLIT_PATTERN,
	IDX_DPI_DESYNC_FAKEDSPLIT_MOD,
	IDX_DPI_DESYNC_HOSTFAKESPLIT_MIDHOST,
	IDX_DPI_DESYNC_HOSTFAKESPLIT_MOD,
	IDX_DPI_DESYNC_IPFRAG_POS_TCP,
	IDX_DPI_DESYNC_IPFRAG_POS_UDP,
	IDX_DPI_DESYNC_TS_INCREMENT,
	IDX_DPI_DESYNC_BADSEQ_INCREMENT,
	IDX_DPI_DESYNC_BADACK_INCREMENT,
	IDX_DPI_DESYNC_ANY_PROTOCOL,
	IDX_DPI_DESYNC_FAKE_TCP_MOD,
	IDX_DPI_DESYNC_FAKE_HTTP,
	IDX_DPI_DESYNC_FAKE_TLS,
	IDX_DPI_DESYNC_FAKE_TLS_MOD,
	IDX_DPI_DESYNC_FAKE_UNKNOWN,
	IDX_DPI_DESYNC_FAKE_SYNDATA,
	IDX_DPI_DESYNC_FAKE_QUIC,
	IDX_DPI_DESYNC_FAKE_WIREGUARD,
	IDX_DPI_DESYNC_FAKE_DHT,
	IDX_DPI_DESYNC_FAKE_DISCORD,
	IDX_DPI_DESYNC_FAKE_STUN,
	IDX_DPI_DESYNC_FAKE_UNKNOWN_UDP,
	IDX_DPI_DESYNC_UDPLEN_INCREMENT,
	IDX_DPI_DESYNC_UDPLEN_PATTERN,
	IDX_DPI_DESYNC_CUTOFF,
	IDX_DPI_DESYNC_START,
	IDX_HOSTLIST,
	IDX_HOSTLIST_DOMAINS,
	IDX_HOSTLIST_EXCLUDE,
	IDX_HOSTLIST_EXCLUDE_DOMAINS,
	IDX_HOSTLIST_AUTO,
	IDX_HOSTLIST_AUTO_FAIL_THRESHOLD,
	IDX_HOSTLIST_AUTO_FAIL_TIME,
	IDX_HOSTLIST_AUTO_RETRANS_THRESHOLD,
	IDX_HOSTLIST_AUTO_DEBUG,
	IDX_NEW,
	IDX_SKIP,
	IDX_FILTER_L3,
	IDX_FILTER_TCP,
	IDX_FILTER_UDP,
	IDX_FILTER_L7,
#ifdef HAS_FILTER_SSID
	IDX_FILTER_SSID,
#endif
	IDX_IPSET,
	IDX_IPSET_IP,
	IDX_IPSET_EXCLUDE,
	IDX_IPSET_EXCLUDE_IP,
#ifdef __linux__
	IDX_BIND_FIX4,
	IDX_BIND_FIX6,
#elif defined(__CYGWIN__)
	IDX_WF_IFACE,
	IDX_WF_L3,
	IDX_WF_TCP,
	IDX_WF_UDP,
	IDX_WF_RAW,
	IDX_WF_RAW_PART,
	IDX_WF_FILTER_LAN,
	IDX_WF_SAVE,
	IDX_SSID_FILTER,
	IDX_NLM_FILTER,
	IDX_NLM_LIST,
#endif
	IDX_LAST,
};

static const struct option long_options[] = {
	[IDX_DEBUG] = {"debug", optional_argument, 0, 0},
	[IDX_DRY_RUN] = {"dry-run", no_argument, 0, 0},
	[IDX_VERSION] = {"version", no_argument, 0, 0},
	[IDX_COMMENT] = {"comment", optional_argument, 0, 0},
#ifdef __linux__
	[IDX_QNUM] = {"qnum", required_argument, 0, 0},
#elif defined(BSD)
	[IDX_PORT] = {"port", required_argument, 0, 0},
#endif
	[IDX_DAEMON] = {"daemon", no_argument, 0, 0},
	[IDX_PIDFILE] = {"pidfile", required_argument, 0, 0},
#ifndef __CYGWIN__
	[IDX_USER] = {"user", required_argument, 0, 0},
	[IDX_UID] = {"uid", required_argument, 0, 0},
#endif
	[IDX_WSIZE] = {"wsize", required_argument, 0, 0},
	[IDX_WSSIZE] = {"wssize", required_argument, 0, 0},
	[IDX_WSSIZE_CUTOFF] = {"wssize-cutoff", required_argument, 0, 0},
	[IDX_WSSIZE_FORCED_CUTOFF] = {"wssize-forced-cutoff", required_argument, 0, 0},
	[IDX_SYNACK_SPLIT] = {"synack-split", optional_argument, 0, 0},
	[IDX_CTRACK_TIMEOUTS] = {"ctrack-timeouts", required_argument, 0, 0},
	[IDX_CTRACK_DISABLE] = {"ctrack-disable", optional_argument, 0, 0},
	[IDX_IPCACHE_LIFETIME] = {"ipcache-lifetime", required_argument, 0, 0},
	[IDX_IPCACHE_HOSTNAME] = {"ipcache-hostname", optional_argument, 0, 0},
	[IDX_HOSTCASE] = {"hostcase", no_argument, 0, 0},
	[IDX_HOSTSPELL] = {"hostspell", required_argument, 0, 0},
	[IDX_HOSTNOSPACE] = {"hostnospace", no_argument, 0, 0},
	[IDX_DOMCASE] = {"domcase", no_argument, 0, 0},
	[IDX_METHODEOL] = {"methodeol", no_argument, 0, 0},
	[IDX_IP_ID] = {"ip-id", required_argument, 0, 0},
	[IDX_DPI_DESYNC] = {"dpi-desync", required_argument, 0, 0},
#ifdef __linux__
	[IDX_DPI_DESYNC_FWMARK] = {"dpi-desync-fwmark", required_argument, 0, 0},
#elif defined(SO_USER_COOKIE)
	[IDX_DPI_DESYNC_SOCKARG] = {"dpi-desync-sockarg", required_argument, 0, 0},
#endif
	[IDX_DUP] = {"dup", required_argument, 0, 0},
	[IDX_DUP_TTL] = {"dup-ttl", required_argument, 0, 0},
	[IDX_DUP_TTL6] = {"dup-ttl6", required_argument, 0, 0},
	[IDX_DUP_AUTOTTL] = {"dup-autottl", optional_argument, 0, 0},
	[IDX_DUP_AUTOTTL6] = {"dup-autottl6", optional_argument, 0, 0},
	[IDX_DUP_TCP_FLAGS_SET] = {"dup-tcp-flags-set", optional_argument, 0, 0},
	[IDX_DUP_TCP_FLAGS_UNSET] = {"dup-tcp-flags-unset", optional_argument, 0, 0},
	[IDX_DUP_FOOLING] = {"dup-fooling", required_argument, 0, 0},
	[IDX_DUP_TS_INCREMENT] = {"dup-ts-increment", required_argument, 0, 0},
	[IDX_DUP_BADSEQ_INCREMENT] = {"dup-badseq-increment", required_argument, 0, 0},
	[IDX_DUP_BADACK_INCREMENT] = {"dup-badack-increment", required_argument, 0, 0},
	[IDX_DUP_REPLACE] = {"dup-replace", optional_argument, 0, 0},
	[IDX_DUP_IP_ID] = {"dup-ip-id", required_argument, 0, 0},
	[IDX_DUP_START] = {"dup-start", required_argument, 0, 0},
	[IDX_DUP_CUTOFF] = {"dup-cutoff", required_argument, 0, 0},
	[IDX_ORIG_TTL] = {"orig-ttl", required_argument, 0, 0},
	[IDX_ORIG_TTL6] = {"orig-ttl6", required_argument, 0, 0},
	[IDX_ORIG_AUTOTTL] = {"orig-autottl", optional_argument, 0, 0},
	[IDX_ORIG_AUTOTTL6] = {"orig-autottl6", optional_argument, 0, 0},
	[IDX_ORIG_TCP_FLAGS_SET] = {"orig-tcp-flags-set", optional_argument, 0, 0},
	[IDX_ORIG_TCP_FLAGS_UNSET] = {"orig-tcp-flags-unset", optional_argument, 0, 0},
	[IDX_ORIG_MOD_START] = {"orig-mod-start", required_argument, 0, 0},
	[IDX_ORIG_MOD_CUTOFF] = {"orig-mod-cutoff", required_argument, 0, 0},
	[IDX_DPI_DESYNC_TTL] = {"dpi-desync-ttl", required_argument, 0, 0},
	[IDX_DPI_DESYNC_TTL6] = {"dpi-desync-ttl6", required_argument, 0, 0},
	[IDX_DPI_DESYNC_AUTOTTL] = {"dpi-desync-autottl", optional_argument, 0, 0},
	[IDX_DPI_DESYNC_AUTOTTL6] = {"dpi-desync-autottl6", optional_argument, 0, 0},
	[IDX_DPI_DESYNC_TCP_FLAGS_SET] = {"dpi-desync-tcp-flags-set", optional_argument, 0, 0},
	[IDX_DPI_DESYNC_TCP_FLAGS_UNSET] = {"dpi-desync-tcp-flags-unset", optional_argument, 0, 0},
	[IDX_DPI_DESYNC_FOOLING] = {"dpi-desync-fooling", required_argument, 0, 0},
	[IDX_DPI_DESYNC_REPEATS] = {"dpi-desync-repeats", required_argument, 0, 0},
	[IDX_DPI_DESYNC_SKIP_NOSNI] = {"dpi-desync-skip-nosni", optional_argument, 0, 0},
	[IDX_DPI_DESYNC_SPLIT_POS] = {"dpi-desync-split-pos", required_argument, 0, 0},
	[IDX_DPI_DESYNC_SPLIT_HTTP_REQ] = {"dpi-desync-split-http-req", required_argument, 0, 0},
	[IDX_DPI_DESYNC_SPLIT_TLS] = {"dpi-desync-split-tls", required_argument, 0, 0},
	[IDX_DPI_DESYNC_SPLIT_SEQOVL] = {"dpi-desync-split-seqovl", required_argument, 0, 0},
	[IDX_DPI_DESYNC_SPLIT_SEQOVL_PATTERN] = {"dpi-desync-split-seqovl-pattern", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKEDSPLIT_PATTERN] = {"dpi-desync-fakedsplit-pattern", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKEDSPLIT_MOD] = {"dpi-desync-fakedsplit-mod", required_argument, 0, 0},
	[IDX_DPI_DESYNC_HOSTFAKESPLIT_MIDHOST] = {"dpi-desync-hostfakesplit-midhost", required_argument, 0, 0},
	[IDX_DPI_DESYNC_HOSTFAKESPLIT_MOD] = {"dpi-desync-hostfakesplit-mod", required_argument, 0, 0},
	[IDX_DPI_DESYNC_IPFRAG_POS_TCP] = {"dpi-desync-ipfrag-pos-tcp", required_argument, 0, 0},
	[IDX_DPI_DESYNC_IPFRAG_POS_UDP] = {"dpi-desync-ipfrag-pos-udp", required_argument, 0, 0},
	[IDX_DPI_DESYNC_TS_INCREMENT] = {"dpi-desync-ts-increment", required_argument, 0, 0},
	[IDX_DPI_DESYNC_BADSEQ_INCREMENT] = {"dpi-desync-badseq-increment", required_argument, 0, 0},
	[IDX_DPI_DESYNC_BADACK_INCREMENT] = {"dpi-desync-badack-increment", required_argument, 0, 0},
	[IDX_DPI_DESYNC_ANY_PROTOCOL] = {"dpi-desync-any-protocol", optional_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_TCP_MOD] = {"dpi-desync-fake-tcp-mod", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_HTTP] = {"dpi-desync-fake-http", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_TLS] = {"dpi-desync-fake-tls", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_TLS_MOD] = {"dpi-desync-fake-tls-mod", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_UNKNOWN] = {"dpi-desync-fake-unknown", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_SYNDATA] = {"dpi-desync-fake-syndata", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_QUIC] = {"dpi-desync-fake-quic", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_WIREGUARD] = {"dpi-desync-fake-wireguard", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_DHT] = {"dpi-desync-fake-dht", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_DISCORD] = {"dpi-desync-fake-discord", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_STUN] = {"dpi-desync-fake-stun", required_argument, 0, 0},
	[IDX_DPI_DESYNC_FAKE_UNKNOWN_UDP] = {"dpi-desync-fake-unknown-udp", required_argument, 0, 0},
	[IDX_DPI_DESYNC_UDPLEN_INCREMENT] = {"dpi-desync-udplen-increment", required_argument, 0, 0},
	[IDX_DPI_DESYNC_UDPLEN_PATTERN] = {"dpi-desync-udplen-pattern", required_argument, 0, 0},
	[IDX_DPI_DESYNC_CUTOFF] = {"dpi-desync-cutoff", required_argument, 0, 0},
	[IDX_DPI_DESYNC_START] = {"dpi-desync-start", required_argument, 0, 0},
	[IDX_HOSTLIST] = {"hostlist", required_argument, 0, 0},
	[IDX_HOSTLIST_DOMAINS] = {"hostlist-domains", required_argument, 0, 0},
	[IDX_HOSTLIST_EXCLUDE] = {"hostlist-exclude", required_argument, 0, 0},
	[IDX_HOSTLIST_EXCLUDE_DOMAINS] = {"hostlist-exclude-domains", required_argument, 0, 0},
	[IDX_HOSTLIST_AUTO] = {"hostlist-auto", required_argument, 0, 0},
	[IDX_HOSTLIST_AUTO_FAIL_THRESHOLD] = {"hostlist-auto-fail-threshold", required_argument, 0, 0},
	[IDX_HOSTLIST_AUTO_FAIL_TIME] = {"hostlist-auto-fail-time", required_argument, 0, 0},
	[IDX_HOSTLIST_AUTO_RETRANS_THRESHOLD] = {"hostlist-auto-retrans-threshold", required_argument, 0, 0},
	[IDX_HOSTLIST_AUTO_DEBUG] = {"hostlist-auto-debug", required_argument, 0, 0},
	[IDX_NEW] = {"new", no_argument, 0, 0},
	[IDX_SKIP] = {"skip", no_argument, 0, 0},
	[IDX_FILTER_L3] = {"filter-l3", required_argument, 0, 0},
	[IDX_FILTER_TCP] = {"filter-tcp", required_argument, 0, 0},
	[IDX_FILTER_UDP] = {"filter-udp", required_argument, 0, 0},
	[IDX_FILTER_L7] = {"filter-l7", required_argument, 0, 0},
#ifdef HAS_FILTER_SSID
	[IDX_FILTER_SSID] = {"filter-ssid", required_argument, 0, 0},
#endif
	[IDX_IPSET] = {"ipset", required_argument, 0, 0},
	[IDX_IPSET_IP] = {"ipset-ip", required_argument, 0, 0},
	[IDX_IPSET_EXCLUDE] = {"ipset-exclude", required_argument, 0, 0},
	[IDX_IPSET_EXCLUDE_IP] = {"ipset-exclude-ip", required_argument, 0, 0},
#ifdef __linux__
	[IDX_BIND_FIX4] = {"bind-fix4", no_argument, 0, 0},
	[IDX_BIND_FIX6] = {"bind-fix6", no_argument, 0, 0},
#elif defined(__CYGWIN__)
	[IDX_WF_IFACE] = {"wf-iface", required_argument, 0, 0},
	[IDX_WF_L3] = {"wf-l3", required_argument, 0, 0},
	[IDX_WF_TCP] = {"wf-tcp", required_argument, 0, 0},
	[IDX_WF_UDP] = {"wf-udp", required_argument, 0, 0},
	[IDX_WF_RAW] = {"wf-raw", required_argument, 0, 0},
	[IDX_WF_RAW_PART] = {"wf-raw-part", required_argument, 0, 0},
	[IDX_WF_FILTER_LAN] = {"wf-filter-lan", required_argument, 0, 0},
	[IDX_WF_SAVE] = {"wf-save", required_argument, 0, 0},
	[IDX_SSID_FILTER] = {"ssid-filter", required_argument, 0, 0},
	[IDX_NLM_FILTER] = {"nlm-filter", required_argument, 0, 0},
	[IDX_NLM_LIST] = {"nlm-list", optional_argument, 0, 0},
#endif
	[IDX_LAST] = {NULL, 0, NULL, 0},
};

int main(int argc, char **argv)
{
	set_console_io_buffering();
	set_env_exedir(argv[0]);

#ifdef __CYGWIN__
	if (service_run(argc, argv))
	{
		// we were running as service. now exit.
		return 0;
	}
#endif
	int result, v;
	int option_index = 0;
	bool bSkip = false, bDry = false;
	struct hostlist_file *anon_hl = NULL, *anon_hl_exclude = NULL;
	struct ipset_file *anon_ips = NULL, *anon_ips_exclude = NULL;
#ifdef __CYGWIN__
	char windivert_filter[16384], wf_pf_tcp_src[4096], wf_pf_tcp_dst[4096], wf_pf_udp_src[4096], wf_pf_udp_dst[4096], wf_save_file[256];
	bool wf_ipv4 = true, wf_ipv6 = true, wf_filter_lan = true;
	unsigned int IfIdx = 0, SubIfIdx = 0;
	unsigned int hash_wf_tcp = 0, hash_wf_udp = 0, hash_wf_raw = 0, hash_wf_raw_part = 0, hash_ssid_filter = 0, hash_nlm_filter = 0;
	*windivert_filter = *wf_pf_tcp_src = *wf_pf_tcp_dst = *wf_pf_udp_src = *wf_pf_udp_dst = *wf_save_file = 0;
#endif

	srandom(time(NULL));
	aes_init_keygen_tables(); // required for aes

	PRINT_VER;

	memset(&params, 0, sizeof(params));

	struct desync_profile_list *dpl;
	struct desync_profile *dp;
	int desync_profile_count = 0;

	if (!(dpl = dp_list_add(&params.desync_profiles)))
	{
		DLOG_ERR("desync_profile_add: out of memory\n");
		exit_clean(1);
	}
	dp = &dpl->dp;
	dp->n = ++desync_profile_count;

#ifdef __linux__
	params.qnum = -1;
#elif defined(BSD)
	params.port = 0;
#endif
	params.desync_fwmark = DPI_DESYNC_FWMARK_DEFAULT;
	params.ctrack_t_syn = CTRACK_T_SYN;
	params.ctrack_t_est = CTRACK_T_EST;
	params.ctrack_t_fin = CTRACK_T_FIN;
	params.ctrack_t_udp = CTRACK_T_UDP;
	params.ipcache_lifetime = IPCACHE_LIFETIME;

	LIST_INIT(&params.hostlists);
	LIST_INIT(&params.ipsets);

#ifdef __CYGWIN__
	LIST_INIT(&params.ssid_filter);
	LIST_INIT(&params.nlm_filter);
	LIST_INIT(&params.wf_raw_part);
#else
	if (can_drop_root())
	{
		params.uid = params.gid[0] = 0x7FFFFFFF; // default uid:gid
		params.gid_count = 1;
		params.droproot = true;
	}
#endif

#if !defined( __OpenBSD__) && !defined(__ANDROID__)
	if (argc >= 2 && (argv[1][0] == '@' || argv[1][0] == '$'))
	{
		config_from_file(argv[1] + 1);
		argv = params.wexp.we_wordv;
		argc = params.wexp.we_wordc;
	}
#endif

	if (argc < 2) exithelp_clean();
	while ((v = getopt_long_only(argc, argv, "", long_options, &option_index)) != -1)
	{
		if (v)
		{
			if (bDry)
				exit_clean(1);
			else
				exithelp_clean();
		}
		switch (option_index)
		{
		case IDX_DEBUG:
			if (optarg)
			{
				if (*optarg == '@')
				{
					strncpy(params.debug_logfile, optarg + 1, sizeof(params.debug_logfile));
					params.debug_logfile[sizeof(params.debug_logfile) - 1] = 0;
					FILE *F = fopen(params.debug_logfile, "wt");
					if (!F)
					{
						fprintf(stderr, "cannot create %s\n", params.debug_logfile);
						exit_clean(1);
					}
					fclose(F);
					params.debug = true;
					params.debug_target = LOG_TARGET_FILE;
				}
				else if (!strcmp(optarg, "syslog"))
				{
					params.debug = true;
					params.debug_target = LOG_TARGET_SYSLOG;
					openlog(progname, LOG_PID, LOG_USER);
				}
#ifdef __ANDROID__
				else if (!strcmp(optarg, "android"))
				{
					if (!params.debug) params.debug = 1;
					params.debug_target = LOG_TARGET_ANDROID;
				}
#endif
				else if (optarg[0] >= '0' && optarg[0] <= '1')
				{
					params.debug = atoi(optarg);
					params.debug_target = LOG_TARGET_CONSOLE;
				}
				else
				{
					fprintf(stderr, "invalid debug mode : %s\n", optarg);
					exit_clean(1);
				}
			}
			else
			{
				params.debug = true;
				params.debug_target = LOG_TARGET_CONSOLE;
			}
			break;
		case IDX_DRY_RUN:
			bDry = true;
			break;
		case IDX_VERSION:
			exit_clean(0);
			break;
		case IDX_COMMENT:
			break;
#ifdef __linux__
		case IDX_QNUM:
			params.qnum = atoi(optarg);
			if (params.qnum < 0 || params.qnum>65535)
			{
				DLOG_ERR("bad qnum\n");
				exit_clean(1);
			}
			break;
#elif defined(BSD)
		case IDX_PORT:
		{
			int i = atoi(optarg);
			if (i <= 0 || i > 65535)
			{
				DLOG_ERR("bad port number\n");
				exit_clean(1);
			}
			params.port = (uint16_t)i;
		}
		break;
#endif
		case IDX_DAEMON:
			params.daemon = true;
			break;
		case IDX_PIDFILE:
			snprintf(params.pidfile, sizeof(params.pidfile), "%s", optarg);
			break;
#ifndef __CYGWIN__
		case IDX_USER:
		{
			free(params.user); params.user = NULL;
			struct passwd *pwd = getpwnam(optarg);
			if (!pwd)
			{
				DLOG_ERR("non-existent username supplied\n");
				exit_clean(1);
			}
			params.uid = pwd->pw_uid;
			params.gid[0] = pwd->pw_gid;
			params.gid_count = 1;
			if (!(params.user = strdup(optarg)))
			{
				DLOG_ERR("strdup: out of memory\n");
				exit_clean(1);
			}
			params.droproot = true;
			break;
		}
		case IDX_UID:
			free(params.user); params.user = NULL;
			if (!parse_uid(optarg, &params.uid, params.gid, &params.gid_count, MAX_GIDS))
			{
				DLOG_ERR("--uid should be : uid[:gid,gid,...]\n");
				exit_clean(1);
			}
			if (!params.gid_count)
			{
				params.gid[0] = 0x7FFFFFFF;
				params.gid_count = 1;
			}
			params.droproot = true;
			break;
#endif
		case IDX_WSIZE:
			if (!parse_ws_scale_factor(optarg, &dp->wsize, &dp->wscale))
				exit_clean(1);
			break;
		case IDX_WSSIZE:
			if (!parse_ws_scale_factor(optarg, &dp->wssize, &dp->wsscale))
				exit_clean(1);
			break;
		case IDX_WSSIZE_CUTOFF:
			if (!parse_cutoff(optarg, &dp->wssize_cutoff, &dp->wssize_cutoff_mode))
			{
				DLOG_ERR("invalid wssize-cutoff value\n");
				exit_clean(1);
			}
			break;
		case IDX_WSSIZE_FORCED_CUTOFF:
			dp->wssize_no_forced_cutoff = !atoi(optarg);
			break;
		case IDX_SYNACK_SPLIT:
			dp->synack_split = SS_SYN;
			if (optarg)
			{
				if (!strcmp(optarg, "synack"))
					dp->synack_split = SS_SYNACK;
				else if (!strcmp(optarg, "acksyn"))
					dp->synack_split = SS_ACKSYN;
				else if (strcmp(optarg, "syn"))
				{
					DLOG_ERR("invalid synack-split value\n");
					exit_clean(1);
				}
			}
			break;
		case IDX_CTRACK_TIMEOUTS:
			if (sscanf(optarg, "%u:%u:%u:%u", &params.ctrack_t_syn, &params.ctrack_t_est, &params.ctrack_t_fin, &params.ctrack_t_udp) < 3)
			{
				DLOG_ERR("invalid ctrack-timeouts value\n");
				exit_clean(1);
			}
			break;
		case IDX_CTRACK_DISABLE:
			params.ctrack_disable = !optarg || atoi(optarg);
			break;
		case IDX_IPCACHE_LIFETIME:
			if (sscanf(optarg, "%u", &params.ipcache_lifetime) != 1)
			{
				DLOG_ERR("invalid ipcache-lifetime value\n");
				exit_clean(1);
			}
			break;
		case IDX_IPCACHE_HOSTNAME:
			params.cache_hostname = !optarg || atoi(optarg);
			break;
		case IDX_HOSTCASE:
			dp->hostcase = true;
			break;
		case IDX_HOSTSPELL:
			if (strlen(optarg) != 4)
			{
				DLOG_ERR("hostspell must be exactly 4 chars long\n");
				exit_clean(1);
			}
			dp->hostcase = true;
			memcpy(dp->hostspell, optarg, 4);
			break;
		case IDX_HOSTNOSPACE:
			if (dp->methodeol)
			{
				DLOG_ERR("--hostnospace and --methodeol are incompatible\n");
				exit_clean(1);
			}
			dp->hostnospace = true;
			break;
		case IDX_DOMCASE:
			dp->domcase = true;
			break;
		case IDX_METHODEOL:
			if (dp->hostnospace)
			{
				DLOG_ERR("--hostnospace and --methodeol are incompatible\n");
				exit_clean(1);
			}
			dp->methodeol = true;
			break;
		case IDX_IP_ID:
			if (!strcmp(optarg,"zero"))
				dp->ip_id_mode = IPID_ZERO;
			else if (!strcmp(optarg,"seq"))
				dp->ip_id_mode = IPID_SEQ;
			else if (!strcmp(optarg,"seqgroup"))
				dp->ip_id_mode = IPID_SEQ_GROUP;
			else if (!strcmp(optarg,"rnd"))
				dp->ip_id_mode = IPID_RND;
			else
			{
				DLOG_ERR("invalid ip_id mode : %s\n",optarg);
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC:
		{
			char *mode = optarg, *mode2, *mode3;
			mode2 = mode ? strchr(mode, ',') : NULL;
			if (mode2) *mode2++ = 0;
			mode3 = mode2 ? strchr(mode2, ',') : NULL;
			if (mode3) *mode3++ = 0;

			dp->desync_mode0 = desync_mode_from_string(mode);
			if (desync_valid_zero_stage(dp->desync_mode0))
			{
				mode = mode2;
				mode2 = mode3;
				mode3 = NULL;
			}
			else
			{
				dp->desync_mode0 = DESYNC_NONE;
			}
			dp->desync_mode = desync_mode_from_string(mode);
			dp->desync_mode2 = desync_mode_from_string(mode2);
			if (dp->desync_mode0 == DESYNC_INVALID || dp->desync_mode == DESYNC_INVALID || dp->desync_mode2 == DESYNC_INVALID)
			{
				DLOG_ERR("invalid dpi-desync mode\n");
				exit_clean(1);
			}
			if (mode3)
			{
				DLOG_ERR("invalid desync combo : %s+%s+%s\n", mode, mode2, mode3);
				exit_clean(1);
			}
			if (dp->desync_mode2 && (desync_only_first_stage(dp->desync_mode) || !(desync_valid_first_stage(dp->desync_mode) && desync_valid_second_stage(dp->desync_mode2))))
			{
				DLOG_ERR("invalid desync combo : %s+%s\n", mode, mode2);
				exit_clean(1);
			}
#if defined(__OpenBSD__)
			if (dp->desync_mode == DESYNC_IPFRAG2 || dp->desync_mode2 == DESYNC_IPFRAG2)
			{
				DLOG_ERR("OpenBSD has checksum issues with fragmented packets. ipfrag disabled.\n");
				exit_clean(1);
			}
#endif
		}
		break;
#if defined(__linux__)
		case IDX_DPI_DESYNC_FWMARK:
#elif defined(SO_USER_COOKIE)
		case IDX_DPI_DESYNC_SOCKARG:
#endif
#if defined(__linux__) || defined(SO_USER_COOKIE)
			params.desync_fwmark = 0;
			if (sscanf(optarg, "0x%X", &params.desync_fwmark) <= 0) sscanf(optarg, "%u", &params.desync_fwmark);
			if (!params.desync_fwmark)
			{
				DLOG_ERR("fwmark/sockarg should be decimal or 0xHEX and should not be zero\n");
				exit_clean(1);
			}
			break;
#endif

		case IDX_DUP:
			if (sscanf(optarg, "%u", &dp->dup_repeats) < 1 || dp->dup_repeats > 1024)
			{
				DLOG_ERR("dup-repeats must be within 0..1024\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_TTL:
			dp->dup_ttl = (uint8_t)atoi(optarg);
			break;
		case IDX_DUP_TTL6:
			dp->dup_ttl6 = (uint8_t)atoi(optarg);
			break;
		case IDX_DUP_AUTOTTL:
			if (!parse_autottl(optarg, &dp->dup_autottl, AUTOTTL_DEFAULT_DUP_DELTA, AUTOTTL_DEFAULT_DUP_MIN, AUTOTTL_DEFAULT_DUP_MAX))
			{
				DLOG_ERR("dup-autottl value error\n");
				exit_clean(1);
			}
			params.autottl_present = true;
			break;
		case IDX_DUP_AUTOTTL6:
			if (!parse_autottl(optarg, &dp->dup_autottl6, AUTOTTL_DEFAULT_DUP_DELTA, AUTOTTL_DEFAULT_DUP_MIN, AUTOTTL_DEFAULT_DUP_MAX))
			{
				DLOG_ERR("dup-autottl6 value error\n");
				exit_clean(1);
			}
			params.autottl_present = true;
			break;
		case IDX_DUP_TCP_FLAGS_SET:
			if (!parse_tcpflags(optarg, &dp->dup_tcp_flags_set))
			{
				DLOG_ERR("invalid tcp flags\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_TCP_FLAGS_UNSET:
			if (!parse_tcpflags(optarg, &dp->dup_tcp_flags_unset))
			{
				DLOG_ERR("invalid tcp flags\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_REPLACE:
			dp->dup_replace = !optarg || atoi(optarg);
			break;
		case IDX_DUP_FOOLING:
			if (!parse_fooling(optarg, &dp->dup_fooling_mode))
			{
				DLOG_ERR("fooling allowed values : none,md5sig,ts,badseq,badsum,datanoack,hopbyhop,hopbyhop2\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_TS_INCREMENT:
			if (!parse_net32_signed(optarg, &dp->dup_ts_increment))
			{
				DLOG_ERR("dup-ts-increment should be signed decimal or signed 0xHEX\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_BADSEQ_INCREMENT:
			if (!parse_net32_signed(optarg, &dp->dup_badseq_increment))
			{
				DLOG_ERR("dup-badseq-increment should be signed decimal or signed 0xHEX\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_BADACK_INCREMENT:
			if (!parse_net32_signed(optarg, &dp->dup_badseq_ack_increment))
			{
				DLOG_ERR("dup-badack-increment should be signed decimal or signed 0xHEX\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_CUTOFF:
			if (!parse_cutoff(optarg, &dp->dup_cutoff, &dp->dup_cutoff_mode))
			{
				DLOG_ERR("invalid dup-cutoff value\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_START:
			if (!parse_cutoff(optarg, &dp->dup_start, &dp->dup_start_mode))
			{
				DLOG_ERR("invalid dup-start value\n");
				exit_clean(1);
			}
			break;
		case IDX_DUP_IP_ID:
			if (!strcmp(optarg,"zero"))
				dp->dup_ip_id_mode = IPID_ZERO;
			else if (!strcmp(optarg,"same"))
				dp->dup_ip_id_mode = IPID_SAME;
			else if (!strcmp(optarg,"seq"))
				dp->dup_ip_id_mode = IPID_SEQ;
			else if (!strcmp(optarg,"rnd"))
				dp->dup_ip_id_mode = IPID_RND;
			else
			{
				DLOG_ERR("invalid dup ip_id mode : %s\n",optarg);
				exit_clean(1);
			}
			break;

		case IDX_ORIG_TTL:
			dp->orig_mod_ttl = (uint8_t)atoi(optarg);
			break;
		case IDX_ORIG_TTL6:
			dp->orig_mod_ttl6 = (uint8_t)atoi(optarg);
			break;
		case IDX_ORIG_AUTOTTL:
			if (!parse_autottl(optarg, &dp->orig_autottl, AUTOTTL_DEFAULT_ORIG_DELTA, AUTOTTL_DEFAULT_ORIG_MIN, AUTOTTL_DEFAULT_ORIG_MAX))
			{
				DLOG_ERR("orig-autottl value error\n");
				exit_clean(1);
			}
			params.autottl_present = true;
			break;
		case IDX_ORIG_AUTOTTL6:
			if (!parse_autottl(optarg, &dp->orig_autottl6, AUTOTTL_DEFAULT_ORIG_DELTA, AUTOTTL_DEFAULT_ORIG_MIN, AUTOTTL_DEFAULT_ORIG_MAX))
			{
				DLOG_ERR("orig-autottl6 value error\n");
				exit_clean(1);
			}
			params.autottl_present = true;
			break;
		case IDX_ORIG_TCP_FLAGS_SET:
			if (!parse_tcpflags(optarg, &dp->orig_tcp_flags_set))
			{
				DLOG_ERR("invalid tcp flags\n");
				exit_clean(1);
			}
			break;
		case IDX_ORIG_TCP_FLAGS_UNSET:
			if (!parse_tcpflags(optarg, &dp->orig_tcp_flags_unset))
			{
				DLOG_ERR("invalid tcp flags\n");
				exit_clean(1);
			}
			break;
		case IDX_ORIG_MOD_CUTOFF:
			if (!parse_cutoff(optarg, &dp->orig_mod_cutoff, &dp->orig_mod_cutoff_mode))
			{
				DLOG_ERR("invalid orig-mod-cutoff value\n");
				exit_clean(1);
			}
			break;
		case IDX_ORIG_MOD_START:
			if (!parse_cutoff(optarg, &dp->orig_mod_start, &dp->orig_mod_start_mode))
			{
				DLOG_ERR("invalid orig-mod-start value\n");
				exit_clean(1);
			}
			break;

		case IDX_DPI_DESYNC_TTL:
			dp->desync_ttl = (uint8_t)atoi(optarg);
			break;
		case IDX_DPI_DESYNC_TTL6:
			dp->desync_ttl6 = (uint8_t)atoi(optarg);
			break;
		case IDX_DPI_DESYNC_AUTOTTL:
			if (!parse_autottl(optarg, &dp->desync_autottl, AUTOTTL_DEFAULT_DESYNC_DELTA, AUTOTTL_DEFAULT_DESYNC_MIN, AUTOTTL_DEFAULT_DESYNC_MAX))
			{
				DLOG_ERR("dpi-desync-autottl value error\n");
				exit_clean(1);
			}
			params.autottl_present = true;
			break;
		case IDX_DPI_DESYNC_AUTOTTL6:
			if (!parse_autottl(optarg, &dp->desync_autottl6, AUTOTTL_DEFAULT_DESYNC_DELTA, AUTOTTL_DEFAULT_DESYNC_MIN, AUTOTTL_DEFAULT_DESYNC_MAX))
			{
				DLOG_ERR("dpi-desync-autottl6 value error\n");
				exit_clean(1);
			}
			params.autottl_present = true;
			break;
		case IDX_DPI_DESYNC_TCP_FLAGS_SET:
			if (!parse_tcpflags(optarg, &dp->desync_tcp_flags_set))
			{
				DLOG_ERR("invalid tcp flags\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_TCP_FLAGS_UNSET:
			if (!parse_tcpflags(optarg, &dp->desync_tcp_flags_unset))
			{
				DLOG_ERR("invalid tcp flags\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_FOOLING:
			if (!parse_fooling(optarg, &dp->desync_fooling_mode))
			{
				DLOG_ERR("fooling allowed values : none,md5sig,ts,badseq,badsum,datanoack,hopbyhop,hopbyhop2\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_REPEATS:
			if (sscanf(optarg, "%u", &dp->desync_repeats) < 1 || !dp->desync_repeats || dp->desync_repeats > 1024)
			{
				DLOG_ERR("dpi-desync-repeats must be within 1..1024\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_SKIP_NOSNI:
			dp->desync_skip_nosni = !optarg || atoi(optarg);
			break;
		case IDX_DPI_DESYNC_SPLIT_POS:
		{
			int ct;
			if (!parse_split_pos_list(optarg, dp->splits + dp->split_count, MAX_SPLITS - dp->split_count, &ct))
			{
				DLOG_ERR("could not parse split pos list or too much positions (before parsing - %u, max - %u) : %s\n", dp->split_count, MAX_SPLITS, optarg);
				exit_clean(1);
			}
			dp->split_count += ct;
			break;
		}
		case IDX_DPI_DESYNC_SPLIT_HTTP_REQ:
			// obsolete arg
			DLOG_CONDUP("WARNING ! --dpi-desync-split-http-req is deprecated. use --dpi-desync-split-pos with markers.\n", MAX_SPLITS);
			if (dp->split_count >= MAX_SPLITS)
			{
				DLOG_ERR("Too much splits. max splits: %u\n", MAX_SPLITS);
				exit_clean(1);
			}
			if (!parse_httpreqpos(optarg, dp->splits + dp->split_count))
			{
				DLOG_ERR("Invalid argument for dpi-desync-split-http-req\n");
				exit_clean(1);
			}
			dp->split_count++;
			break;
		case IDX_DPI_DESYNC_SPLIT_TLS:
			// obsolete arg
			DLOG_CONDUP("WARNING ! --dpi-desync-split-tls is deprecated. use --dpi-desync-split-pos with markers.\n", MAX_SPLITS);
			if (dp->split_count >= MAX_SPLITS)
			{
				DLOG_ERR("Too much splits. max splits: %u\n", MAX_SPLITS);
				exit_clean(1);
			}
			if (!parse_tlspos(optarg, dp->splits + dp->split_count))
			{
				DLOG_ERR("Invalid argument for dpi-desync-split-tls\n");
				exit_clean(1);
			}
			dp->split_count++;
			break;
		case IDX_DPI_DESYNC_SPLIT_SEQOVL:
			if (!strcmp(optarg, "0"))
			{
				// allow zero = disable seqovl
				dp->seqovl.marker = PM_ABS;
				dp->seqovl.pos = 0;
			}
			else if (!parse_split_pos(optarg, &dp->seqovl))
			{
				DLOG_ERR("Invalid argument for dpi-desync-split-seqovl\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_SPLIT_SEQOVL_PATTERN:
		{
			char buf[sizeof(dp->seqovl_pattern)];
			size_t sz = sizeof(buf);
			load_file_or_exit(optarg, buf, &sz, NULL);
			fill_pattern(dp->seqovl_pattern, sizeof(dp->seqovl_pattern), buf, sz, 0);
			break;
		}
		case IDX_DPI_DESYNC_FAKEDSPLIT_PATTERN:
		{
			free(dp->fsplit_pattern);
			if (!(dp->fsplit_pattern = malloc(dp->fsplit_pattern_size=32768)))
			{
				DLOG_ERR("out of memory\n");
				exit_clean(1);
			}
			load_file_or_exit(optarg, dp->fsplit_pattern, &dp->fsplit_pattern_size, NULL);
			dp->fsplit_pattern = realloc(dp->fsplit_pattern, dp->fsplit_pattern_size);
			break;
		}
		case IDX_DPI_DESYNC_FAKEDSPLIT_MOD:
			if (!parse_fakedsplit_mod(optarg, &dp->fs_mod))
			{
				DLOG_ERR("Invalid fakedsplit mod : %s\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_HOSTFAKESPLIT_MIDHOST:
			if (!strcmp(optarg, "0"))
			{
				// allow zero = disable midhost split
				dp->hostfakesplit_midhost.marker = PM_ABS;
				dp->hostfakesplit_midhost.pos = 0;
			}
			else if (!parse_split_pos(optarg, &dp->hostfakesplit_midhost))
			{
				DLOG_ERR("Invalid argument for dpi-desync-hostfakesplit-midhost\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_HOSTFAKESPLIT_MOD:
			if (!parse_hostfakesplit_mod(optarg, &dp->hfs_mod))
			{
				DLOG_ERR("Invalid hostfakesplit mod : %s\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_IPFRAG_POS_TCP:
			if (sscanf(optarg, "%u", &dp->desync_ipfrag_pos_tcp) < 1 || dp->desync_ipfrag_pos_tcp<1 || dp->desync_ipfrag_pos_tcp>DPI_DESYNC_MAX_FAKE_LEN)
			{
				DLOG_ERR("dpi-desync-ipfrag-pos-tcp must be within 1..%u range\n", DPI_DESYNC_MAX_FAKE_LEN);
				exit_clean(1);
			}
			if (dp->desync_ipfrag_pos_tcp & 7)
			{
				DLOG_ERR("dpi-desync-ipfrag-pos-tcp must be multiple of 8\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_IPFRAG_POS_UDP:
			if (sscanf(optarg, "%u", &dp->desync_ipfrag_pos_udp) < 1 || dp->desync_ipfrag_pos_udp<1 || dp->desync_ipfrag_pos_udp>DPI_DESYNC_MAX_FAKE_LEN)
			{
				DLOG_ERR("dpi-desync-ipfrag-pos-udp must be within 1..%u range\n", DPI_DESYNC_MAX_FAKE_LEN);
				exit_clean(1);
			}
			if (dp->desync_ipfrag_pos_udp & 7)
			{
				DLOG_ERR("dpi-desync-ipfrag-pos-udp must be multiple of 8\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_TS_INCREMENT:
			if (!parse_net32_signed(optarg, &dp->desync_ts_increment))
			{
				DLOG_ERR("dpi-desync-ts-increment should be signed decimal or signed 0xHEX\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_BADSEQ_INCREMENT:
			if (!parse_net32_signed(optarg, &dp->desync_badseq_increment))
			{
				DLOG_ERR("dpi-desync-badseq-increment should be signed decimal or signed 0xHEX\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_BADACK_INCREMENT:
			if (!parse_net32_signed(optarg, &dp->desync_badseq_ack_increment))
			{
				DLOG_ERR("dpi-desync-badack-increment should be signed decimal or signed 0xHEX\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_ANY_PROTOCOL:
			dp->desync_any_proto = !optarg || atoi(optarg);
			break;
		case IDX_DPI_DESYNC_FAKE_TCP_MOD:
			if (!parse_tcpmod(optarg, &dp->tcp_mod))
			{
				DLOG_ERR("Invalid tcp mod : %s\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_FAKE_HTTP:
			load_blob_to_collection(optarg, &dp->fake_http, FAKE_MAX_TCP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_TLS:
		{
			if (optarg[0] == '!' && (optarg[1] == 0 || optarg[1] == '+'))
				dp->tls_fake_last = load_const_blob_to_collection(fake_tls_clienthello_default, sizeof(fake_tls_clienthello_default), &dp->fake_tls, 4 + sizeof(dp->tls_mod_last.sni), optarg[1] == '+' ? (size_t)atoi(optarg + 1) : 0);
			else
				dp->tls_fake_last = load_blob_to_collection(optarg, &dp->fake_tls, FAKE_MAX_TCP, 4 + sizeof(dp->tls_mod_last.sni));
			if (!(dp->tls_fake_last->extra2 = malloc(sizeof(struct fake_tls_mod))))
			{
				DLOG_ERR("out of memory\n");
				exit_clean(1);
			}
			struct fake_tls_mod *tls_mod = (struct fake_tls_mod*)dp->tls_fake_last->extra2;
			*tls_mod = dp->tls_mod_last;
			tls_mod->mod |= FAKE_TLS_MOD_CUSTOM_FAKE;
		}
		break;
		case IDX_DPI_DESYNC_FAKE_TLS_MOD:
			if (!parse_tlsmod_list(optarg, &dp->tls_mod_last))
			{
				DLOG_ERR("Invalid tls mod : %s\n", optarg);
				exit_clean(1);
			}
			if (dp->tls_fake_last)
				*(struct fake_tls_mod*)dp->tls_fake_last->extra2 = dp->tls_mod_last;
			break;
		case IDX_DPI_DESYNC_FAKE_UNKNOWN:
			load_blob_to_collection(optarg, &dp->fake_unknown, FAKE_MAX_TCP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_SYNDATA:
			dp->fake_syndata_size = sizeof(dp->fake_syndata);
			load_file_or_exit(optarg, dp->fake_syndata, &dp->fake_syndata_size, NULL);
			break;
		case IDX_DPI_DESYNC_FAKE_QUIC:
			load_blob_to_collection(optarg, &dp->fake_quic, FAKE_MAX_UDP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_WIREGUARD:
			load_blob_to_collection(optarg, &dp->fake_wg, FAKE_MAX_UDP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_DHT:
			load_blob_to_collection(optarg, &dp->fake_dht, FAKE_MAX_UDP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_DISCORD:
			load_blob_to_collection(optarg, &dp->fake_discord, FAKE_MAX_UDP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_STUN:
			load_blob_to_collection(optarg, &dp->fake_stun, FAKE_MAX_UDP, 0);
			break;
		case IDX_DPI_DESYNC_FAKE_UNKNOWN_UDP:
			load_blob_to_collection(optarg, &dp->fake_unknown_udp, FAKE_MAX_UDP, 0);
			break;
		case IDX_DPI_DESYNC_UDPLEN_INCREMENT:
			if (sscanf(optarg, "%d", &dp->udplen_increment) < 1 || dp->udplen_increment > 0x7FFF || dp->udplen_increment < -0x8000)
			{
				DLOG_ERR("dpi-desync-udplen-increment must be integer within -32768..32767 range\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_UDPLEN_PATTERN:
		{
			char buf[sizeof(dp->udplen_pattern)];
			size_t sz = sizeof(buf);
			load_file_or_exit(optarg, buf, &sz, NULL);
			fill_pattern(dp->udplen_pattern, sizeof(dp->udplen_pattern), buf, sz, 0);
		}
		break;
		case IDX_DPI_DESYNC_CUTOFF:
			if (!parse_cutoff(optarg, &dp->desync_cutoff, &dp->desync_cutoff_mode))
			{
				DLOG_ERR("invalid desync-cutoff value\n");
				exit_clean(1);
			}
			break;
		case IDX_DPI_DESYNC_START:
			if (!parse_cutoff(optarg, &dp->desync_start, &dp->desync_start_mode))
			{
				DLOG_ERR("invalid desync-start value\n");
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST:
			if (bSkip) break;
			if (!RegisterHostlist(dp, false, optarg))
			{
				DLOG_ERR("failed to register hostlist '%s'\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_DOMAINS:
			if (bSkip) break;
			if (!anon_hl && !(anon_hl = RegisterHostlist(dp, false, NULL)))
			{
				DLOG_ERR("failed to register anonymous hostlist\n");
				exit_clean(1);
			}
			if (!parse_domain_list(optarg, &anon_hl->hostlist))
			{
				DLOG_ERR("failed to add domains to anonymous hostlist\n");
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_EXCLUDE:
			if (bSkip) break;
			if (!RegisterHostlist(dp, true, optarg))
			{
				DLOG_ERR("failed to register hostlist '%s'\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_EXCLUDE_DOMAINS:
			if (bSkip) break;
			if (!anon_hl_exclude && !(anon_hl_exclude = RegisterHostlist(dp, true, NULL)))
			{
				DLOG_ERR("failed to register anonymous hostlist\n");
				exit_clean(1);
			}
			if (!parse_domain_list(optarg, &anon_hl_exclude->hostlist))
			{
				DLOG_ERR("failed to add domains to anonymous hostlist\n");
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_AUTO:
			if (bSkip) break;
			if (dp->hostlist_auto)
			{
				DLOG_ERR("only one auto hostlist per profile is supported\n");
				exit_clean(1);
			}
			{
				FILE *F = fopen(optarg, "a+b");
				if (!F)
				{
					DLOG_ERR("cannot create %s\n", optarg);
					exit_clean(1);
				}
				bool bGzip = is_gzip(F);
				fclose(F);
				if (bGzip)
				{
					DLOG_ERR("gzipped auto hostlists are not supported\n");
					exit_clean(1);
				}
			}
			if (!(dp->hostlist_auto = RegisterHostlist(dp, false, optarg)))
			{
				DLOG_ERR("failed to register hostlist '%s'\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_AUTO_FAIL_THRESHOLD:
			dp->hostlist_auto_fail_threshold = atoi(optarg);
			if (dp->hostlist_auto_fail_threshold < 1 || dp->hostlist_auto_fail_threshold>20)
			{
				DLOG_ERR("auto hostlist fail threshold must be within 1..20\n");
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_AUTO_FAIL_TIME:
			dp->hostlist_auto_fail_time = atoi(optarg);
			if (dp->hostlist_auto_fail_time < 1)
			{
				DLOG_ERR("auto hostlist fail time is not valid\n");
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_AUTO_RETRANS_THRESHOLD:
			dp->hostlist_auto_retrans_threshold = atoi(optarg);
			if (dp->hostlist_auto_retrans_threshold < 2 || dp->hostlist_auto_retrans_threshold>10)
			{
				DLOG_ERR("auto hostlist fail threshold must be within 2..10\n");
				exit_clean(1);
			}
			break;
		case IDX_HOSTLIST_AUTO_DEBUG:
		{
			FILE *F = fopen(optarg, "a+t");
			if (!F)
			{
				DLOG_ERR("cannot create %s\n", optarg);
				exit_clean(1);
			}
			fclose(F);
			strncpy(params.hostlist_auto_debuglog, optarg, sizeof(params.hostlist_auto_debuglog));
			params.hostlist_auto_debuglog[sizeof(params.hostlist_auto_debuglog) - 1] = '\0';
		}
		break;

		case IDX_NEW:
			if (bSkip)
			{
				dp_clear(dp);
				dp_init(dp);
				dp->n = desync_profile_count;
				bSkip = false;
			}
			else
			{
				check_dp(dp);
				if (!(dpl = dp_list_add(&params.desync_profiles)))
				{
					DLOG_ERR("desync_profile_add: out of memory\n");
					exit_clean(1);
				}
				dp = &dpl->dp;
				dp->n = ++desync_profile_count;
			}
			anon_hl = anon_hl_exclude = NULL;
			anon_ips = anon_ips_exclude = NULL;
			break;
		case IDX_SKIP:
			bSkip = true;
			break;

		case IDX_FILTER_L3:
			if (!wf_make_l3(optarg, &dp->filter_ipv4, &dp->filter_ipv6))
			{
				DLOG_ERR("bad value for --filter-l3\n");
				exit_clean(1);
			}
			break;
		case IDX_FILTER_TCP:
			if (!parse_pf_list(optarg, &dp->pf_tcp))
			{
				DLOG_ERR("Invalid port filter : %s\n", optarg);
				exit_clean(1);
			}
			// deny tcp if not set
			if (!port_filters_deny_if_empty(&dp->pf_udp))
				exit_clean(1);
			break;
		case IDX_FILTER_UDP:
			if (!parse_pf_list(optarg, &dp->pf_udp))
			{
				DLOG_ERR("Invalid port filter : %s\n", optarg);
				exit_clean(1);
			}
			// deny tcp if not set
			if (!port_filters_deny_if_empty(&dp->pf_tcp))
				exit_clean(1);
			break;
		case IDX_FILTER_L7:
			if (!parse_l7_list(optarg, &dp->filter_l7))
			{
				DLOG_ERR("Invalid l7 filter : %s\n", optarg);
				exit_clean(1);
			}
			break;
#ifdef HAS_FILTER_SSID
		case IDX_FILTER_SSID:
			if (!parse_strlist(optarg, &dp->filter_ssid))
			{
				DLOG_ERR("strlist_add failed\n");
				exit_clean(1);
			}
			params.filter_ssid_present = true;
			break;
#endif
		case IDX_IPSET:
			if (bSkip) break;
			if (!RegisterIpset(dp, false, optarg))
			{
				DLOG_ERR("failed to register ipset '%s'\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_IPSET_IP:
			if (bSkip) break;
			if (!anon_ips && !(anon_ips = RegisterIpset(dp, false, NULL)))
			{
				DLOG_ERR("failed to register anonymous ipset\n");
				exit_clean(1);
			}
			if (!parse_ip_list(optarg, &anon_ips->ipset))
			{
				DLOG_ERR("failed to add subnets to anonymous ipset\n");
				exit_clean(1);
			}
			break;
		case IDX_IPSET_EXCLUDE:
			if (bSkip) break;
			if (!RegisterIpset(dp, true, optarg))
			{
				DLOG_ERR("failed to register ipset '%s'\n", optarg);
				exit_clean(1);
			}
			break;
		case IDX_IPSET_EXCLUDE_IP:
			if (bSkip) break;
			if (!anon_ips_exclude && !(anon_ips_exclude = RegisterIpset(dp, true, NULL)))
			{
				DLOG_ERR("failed to register anonymous ipset\n");
				exit_clean(1);
			}
			if (!parse_ip_list(optarg, &anon_ips_exclude->ipset))
			{
				DLOG_ERR("failed to add subnets to anonymous ipset\n");
				exit_clean(1);
			}
			break;


#ifdef __linux__
		case IDX_BIND_FIX4:
			params.bind_fix4 = true;
			break;
		case IDX_BIND_FIX6:
			params.bind_fix6 = true;
			break;
#elif defined(__CYGWIN__)
		case IDX_WF_IFACE:
			if (!sscanf(optarg, "%u.%u", &IfIdx, &SubIfIdx))
			{
				DLOG_ERR("bad value for --wf-iface\n");
				exit_clean(1);
			}
			break;
		case IDX_WF_L3:
			if (!wf_make_l3(optarg, &wf_ipv4, &wf_ipv6))
			{
				DLOG_ERR("bad value for --wf-l3\n");
				exit_clean(1);
			}
			break;
		case IDX_WF_TCP:
			hash_wf_tcp = hash_jen(optarg, strlen(optarg));
			if (!wf_make_pf(optarg, "tcp", "SrcPort", wf_pf_tcp_src, sizeof(wf_pf_tcp_src)) ||
				!wf_make_pf(optarg, "tcp", "DstPort", wf_pf_tcp_dst, sizeof(wf_pf_tcp_dst)))
			{
				DLOG_ERR("bad value for --wf-tcp\n");
				exit_clean(1);
			}
			break;
		case IDX_WF_UDP:
			hash_wf_udp = hash_jen(optarg, strlen(optarg));
			if (!wf_make_pf(optarg, "udp", "SrcPort", wf_pf_udp_src, sizeof(wf_pf_udp_src)) ||
				!wf_make_pf(optarg, "udp", "DstPort", wf_pf_udp_dst, sizeof(wf_pf_udp_dst)))
			{
				DLOG_ERR("bad value for --wf-udp\n");
				exit_clean(1);
			}
			break;
		case IDX_WF_RAW:
			hash_wf_raw = hash_jen(optarg, strlen(optarg));
			if (optarg[0] == '@')
			{
				size_t sz = sizeof(windivert_filter) - 1;
				load_file_or_exit(optarg, windivert_filter, &sz, NULL);
				windivert_filter[sz] = 0;
			}
			else
			{
				strncpy(windivert_filter, optarg, sizeof(windivert_filter));
				windivert_filter[sizeof(windivert_filter) - 1] = '\0';
			}
			break;
		case IDX_WF_RAW_PART:
			hash_wf_raw_part ^= hash_jen(optarg, strlen(optarg));
			{
				char wfpart[sizeof(windivert_filter)];
				if (optarg[0] == '@')
				{
					size_t sz = sizeof(wfpart) - 1;
					load_file_or_exit(optarg, wfpart, &sz, NULL);
					wfpart[sz] = 0;
				}
				else
				{
					strncpy(wfpart, optarg, sizeof(wfpart));
					wfpart[sizeof(wfpart) - 1] = '\0';
				}
				if (!strlist_add(&params.wf_raw_part, wfpart))
				{
					DLOG_ERR("out of memory\n");
					exit_clean(1);
				}
			}
			break;
		case IDX_WF_FILTER_LAN:
			wf_filter_lan = !!atoi(optarg);
			break;
		case IDX_WF_SAVE:
			strncpy(wf_save_file, optarg, sizeof(wf_save_file));
			wf_save_file[sizeof(wf_save_file) - 1] = '\0';
			break;
		case IDX_SSID_FILTER:
			hash_ssid_filter = hash_jen(optarg, strlen(optarg));
			if (!parse_strlist(optarg, &params.ssid_filter))
			{
				DLOG_ERR("strlist_add failed\n");
				exit_clean(1);
			}
			break;
		case IDX_NLM_FILTER:
			hash_nlm_filter = hash_jen(optarg, strlen(optarg));
			if (!parse_strlist(optarg, &params.nlm_filter))
			{
				DLOG_ERR("strlist_add failed\n");
				exit_clean(1);
			}
			break;
		case IDX_NLM_LIST:
			if (!nlm_list(optarg && !strcmp(optarg, "all")))
			{
				DLOG_ERR("could not get list of NLM networks\n");
				exit_clean(1);
			}
			exit_clean(0);

#endif
		}
	}
	if (bSkip)
	{
		LIST_REMOVE(dpl, next);
		dp_entry_destroy(dpl);
		desync_profile_count--;
	}
	else
		check_dp(dp);

	// do not need args from file anymore
#if !defined( __OpenBSD__) && !defined(__ANDROID__)
	cleanup_args(&params);
#endif
	argv = NULL; argc = 0;

#ifdef __linux__
	if (params.qnum < 0)
	{
		DLOG_ERR("Need queue number (--qnum)\n");
		exit_clean(1);
	}
#elif defined(BSD) && !defined(__APPLE__)
	if (!params.port)
	{
		DLOG_ERR("Need divert port (--port)\n");
		exit_clean(1);
	}
#endif

	DLOG("adding low-priority default empty desync profile\n");
	// add default empty profile
	if (!(dpl = dp_list_add(&params.desync_profiles)))
	{
		DLOG_ERR("desync_profile_add: out of memory\n");
		exit_clean(1);
	}

	DLOG_CONDUP("we have %d user defined desync profile(s) and default low priority profile 0\n", desync_profile_count);

#ifndef __CYGWIN__
	if (params.debug_target == LOG_TARGET_FILE && params.droproot && chown(params.debug_logfile, params.uid, -1))
		fprintf(stderr, "could not chown %s. log file may not be writable after privilege drop\n", params.debug_logfile);
	if (params.droproot && *params.hostlist_auto_debuglog && chown(params.hostlist_auto_debuglog, params.uid, -1))
		DLOG_ERR("could not chown %s. auto hostlist debug log may not be writable after privilege drop\n", params.hostlist_auto_debuglog);
#endif
	LIST_FOREACH(dpl, &params.desync_profiles, next)
	{
		dp = &dpl->dp;

		// not specified - use desync_ttl value instead
		if (dp->desync_ttl6 == 0xFF) dp->desync_ttl6 = dp->desync_ttl;
		if (dp->dup_ttl6 == 0xFF) dp->dup_ttl6 = dp->dup_ttl;
		if (dp->orig_mod_ttl6 == 0xFF) dp->orig_mod_ttl6 = dp->orig_mod_ttl;
		if (!dp->fsplit_pattern)
		{
			if ((dp->fsplit_pattern=calloc(64,1)))
				dp->fsplit_pattern_size=64;
			else
			{
				DLOG_ERR("out of memory\n");
				exit_clean(1);
			}
		}
		if (!AUTOTTL_ENABLED(dp->desync_autottl6)) dp->desync_autottl6 = dp->desync_autottl;
		if (!AUTOTTL_ENABLED(dp->orig_autottl6)) dp->orig_autottl6 = dp->orig_autottl;
		if (!AUTOTTL_ENABLED(dp->dup_autottl6)) dp->dup_autottl6 = dp->dup_autottl;
		if (AUTOTTL_ENABLED(dp->desync_autottl))
			DLOG("profile %d desync autottl ipv4 %s%d:%u-%u\n", dp->n, UNARY_PLUS(dp->desync_autottl.delta), dp->desync_autottl.delta, dp->desync_autottl.min, dp->desync_autottl.max);
		if (AUTOTTL_ENABLED(dp->desync_autottl6))
			DLOG("profile %d desync autottl ipv6 %s%d:%u-%u\n", dp->n, UNARY_PLUS(dp->desync_autottl6.delta), dp->desync_autottl6.delta, dp->desync_autottl6.min, dp->desync_autottl6.max);
		if (AUTOTTL_ENABLED(dp->orig_autottl))
			DLOG("profile %d orig autottl ipv4 %s%d:%u-%u\n", dp->n, UNARY_PLUS(dp->orig_autottl.delta), dp->orig_autottl.delta, dp->orig_autottl.min, dp->orig_autottl.max);
		if (AUTOTTL_ENABLED(dp->orig_autottl6))
			DLOG("profile %d orig autottl ipv6 %s%d:%u-%u\n", dp->n, UNARY_PLUS(dp->orig_autottl6.delta), dp->orig_autottl6.delta, dp->orig_autottl6.min, dp->orig_autottl6.max);
		if (AUTOTTL_ENABLED(dp->dup_autottl))
			DLOG("profile %d dup autottl ipv4 %s%d:%u-%u\n", dp->n, UNARY_PLUS(dp->dup_autottl.delta), dp->dup_autottl.delta, dp->dup_autottl.min, dp->dup_autottl.max);
		if (AUTOTTL_ENABLED(dp->dup_autottl6))
			DLOG("profile %d dup autottl ipv6 %s%d:%u-%u\n", dp->n, UNARY_PLUS(dp->dup_autottl6.delta), dp->dup_autottl6.delta, dp->dup_autottl6.min, dp->dup_autottl6.max);
		split_compat(dp);
		if (!dp_fake_defaults(dp))
		{
			DLOG_ERR("could not fill fake defaults\n");
			exit_clean(1);
		}
		if (!onetime_tls_mod(dp))
		{
			DLOG_ERR("could not mod tls\n");
			exit_clean(1);
		}
#ifndef __CYGWIN__
		if (params.droproot && dp->hostlist_auto && chown(dp->hostlist_auto->filename, params.uid, -1))
			DLOG_ERR("could not chown %s. auto hostlist file may not be writable after privilege drop\n", dp->hostlist_auto->filename);
#endif
	}

	if (!test_list_files())
		exit_clean(1);

	if (!LoadAllHostLists())
	{
		DLOG_ERR("hostlists load failed\n");
		exit_clean(1);
	}
	if (!LoadAllIpsets())
	{
		DLOG_ERR("ipset load failed\n");
		exit_clean(1);
	}

	DLOG("\nlists summary:\n");
	HostlistsDebug();
	IpsetsDebug();

	DLOG("\nsplits summary:\n");
	SplitDebug();
	DLOG("\n");

#ifdef __CYGWIN__
	if (!*windivert_filter)
	{
		if (!*wf_pf_tcp_src && !*wf_pf_udp_src && LIST_EMPTY(&params.wf_raw_part))
		{
			DLOG_ERR("windivert filter : must specify port or/and partial raw filter\n");
			exit_clean(1);
		}
		if (!wf_make_filter(windivert_filter, sizeof(windivert_filter), IfIdx, SubIfIdx, wf_ipv4, wf_ipv6, wf_pf_tcp_src, wf_pf_tcp_dst, wf_pf_udp_src, wf_pf_udp_dst, &params.wf_raw_part, wf_filter_lan))
		{
			DLOG_ERR("windivert filter : could not make filter\n");
			exit_clean(1);
		}
	}
	DLOG("windivert filter size: %zu\nwindivert filter:\n%s\n", strlen(windivert_filter), windivert_filter);
	if (*wf_save_file)
	{
		if (save_file(wf_save_file, windivert_filter, strlen(windivert_filter)))
		{
			DLOG_ERR("windivert filter: raw filter saved to %s\n", wf_save_file);
			exit_clean(0);
		}
		else
		{
			DLOG_ERR("windivert filter: could not save raw filter to %s\n", wf_save_file);
			exit_clean(1);
		}
	}
	HANDLE hMutexArg;
	{
		char mutex_name[128];
		snprintf(mutex_name, sizeof(mutex_name), "Global\\winws_arg_%u_%u_%u_%u_%u_%u_%u_%u_%u_%u", hash_wf_tcp, hash_wf_udp, hash_wf_raw, hash_wf_raw_part, hash_ssid_filter, hash_nlm_filter, IfIdx, SubIfIdx, wf_ipv4, wf_ipv6);

		hMutexArg = CreateMutexA(NULL, TRUE, mutex_name);
		if (hMutexArg && GetLastError() == ERROR_ALREADY_EXISTS)
		{
			CloseHandle(hMutexArg);	hMutexArg = NULL;
			DLOG_ERR("A copy of winws is already running with the same filter\n");
			goto exiterr;
		}
	}
#endif

	if (bDry)
	{
#ifndef __CYGWIN__
		if (params.droproot)
		{
			if (!droproot(params.uid, params.user, params.gid, params.gid_count))
				exit_clean(1);
#ifdef __linux__
			if (!dropcaps())
				exit_clean(1);
#endif
			print_id();
			if (!test_list_files())
				exit_clean(1);
		}
#endif
		DLOG_CONDUP("command line parameters verified\n");
		exit_clean(0);
	}

	if (params.ctrack_disable)
		DLOG_CONDUP("conntrack disabled ! some functions will not work. make sure it's what you want.\n");
	else
	{
		DLOG("initializing conntrack with timeouts tcp=%u:%u:%u udp=%u\n", params.ctrack_t_syn, params.ctrack_t_est, params.ctrack_t_fin, params.ctrack_t_udp);
		ConntrackPoolInit(&params.conntrack, 10, params.ctrack_t_syn, params.ctrack_t_est, params.ctrack_t_fin, params.ctrack_t_udp);
	}
	if (params.autottl_present || params.cache_hostname) DLOG("ipcache lifetime %us\n", params.ipcache_lifetime);

#ifdef __linux__
	result = nfq_main();
#elif defined(__APPLE__)
	result = utun_main();
#elif defined(BSD)
	result = dvt_main();
#elif defined(__CYGWIN__)
	result = win_main(windivert_filter);
#else
#error unsupported OS
#endif
ex:
	rawsend_cleanup();
	cleanup_params(&params);
#ifdef __CYGWIN__
	if (hMutexArg)
	{
		ReleaseMutex(hMutexArg);
		CloseHandle(hMutexArg);
	}
#endif
	return result;
exiterr:
	result = 1;
	goto ex;
}
