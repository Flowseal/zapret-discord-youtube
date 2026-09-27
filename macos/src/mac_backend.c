// macOS packet backend for nfqws, built as "macws".
//
// В macOS нет NFQUEUE, а divert-сокеты вырезаны из ядра (в pf нет divert-packet),
// поэтому nfqws/dvtws там неработоспособны. Здесь пакеты берутся из utun
// (pf-правило "pass out route-to (utunN ...)") и отправляются заново через
// raw-сокет, привязанный к uplink-интерфейсу (IP_BOUND_IF). Привязка к uplink
// плюс "user { >root }" в pf-правилах исключают повторный заворот наших же
// пакетов в utun.
//
// Только IPv4: в macOS SDK нет IPV6_HDRINCL, целиком собранный IPv6-фрейм
// через raw-сокет не отправить.

#ifdef __APPLE__

#define __FAVOR_BSD
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <ifaddrs.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/bpf.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <arpa/inet.h>

#include "mac_backend.h"
#include "params.h"
#include "checksum.h"

#define UTUN_LOCAL_DEFAULT	"10.77.77.1"
#define UTUN_PEER_DEFAULT	"10.77.77.2"
#define UTUN_LOCAL6_DEFAULT	"fd77:77::1"
#define UTUN_PEER6_DEFAULT	"fd77:77::2"
#define UTUN_MTU_DEFAULT	1500
#define PF_ANCHOR_DEFAULT	"zapret"
#define MAX_PPS_DEFAULT		200000

// способ инъекции: raw-сокет (по умолчанию) или запись кадра через BPF
enum inject_mode { INJ_AUTO = 0, INJ_RAW, INJ_BPF };
static enum inject_mode inject_mode = INJ_AUTO;
static int inject_sock = -1;
static bool inject_bound = false;            // стоит ли IP_BOUND_IF
static int bpf_fd = -1, bpf_dlt = 0;
static uint8_t bpf_hdr[16], bpf_hdr6[16];
static size_t bpf_hdr_len = 0, bpf_hdr6_len = 0;
static char inject_iface[IFNAMSIZ] = "";
static uint64_t inj_ok = 0, inj_fail = 0;
// аудит провода: сверяем, что отправленный кадр реально прошёл через интерфейс
#define AUDIT_SLOTS 128
struct audit_rec { uint32_t saddr, daddr, seq; uint16_t sport, dport, len; bool seen; };
static struct audit_rec wire_audit[AUDIT_SLOTS];
static unsigned audit_pos = 0;
static uint64_t audit_sent = 0, audit_seen = 0;
static bool audit_on = false;
// Входящие пакеты нужны движку: по TTL входящего SYN-ACK он вычисляет autottl
// (фейк с TTL, который дойдёт до DPI, но умрёт до сервера). Без этого autottl
// не работает вообще. Читаем их тем же bpf и отдаём движку только SYN/RST —
// этого достаточно и почти ничего не стоит.
#define INB_SLOTS 32
#define INB_MAX 256
static uint8_t inb_buf[INB_SLOTS][INB_MAX];
static size_t inb_len[INB_SLOTS];
static unsigned inb_head = 0, inb_tail = 0;
static bool inbound_on = true;
static struct in_addr uplink_addr4 = { 0 };
static uint32_t pps_limit = MAX_PPS_DEFAULT, pps_count = 0;
static time_t pps_sec = 0;
static bool overload = false;
static char pf_anchor_loaded[64] = "";

static const char *env_or(const char *name, const char *dflt)
{
	const char *v = getenv(name);
	return (v && *v) ? v : dflt;
}

static bool run_cmd(const char *fmt, ...)
{
	char cmd[512];
	va_list a;
	int rc;

	va_start(a, fmt);
	vsnprintf(cmd, sizeof(cmd), fmt, a);
	va_end(a);
	DLOG("running: %s\n", cmd);
	rc = system(cmd);
	if (rc)
	{
		DLOG_ERR("command failed (rc=%d): %s\n", rc, cmd);
		return false;
	}
	return true;
}

// вывести результат команды в лог движка построчно
// расширенная диагностика (дампы pf и т.п.) — только по запросу
static bool mac_diag_on(void)
{
	const char *e = getenv("MACWS_DIAG");
	return e && *e && strcmp(e, "0");
}

static void log_cmd(const char *prefix, const char *fmt, ...)
{
	char cmd[512], line[512], *p;
	va_list a;
	FILE *f;

	va_start(a, fmt);
	vsnprintf(cmd, sizeof(cmd), fmt, a);
	va_end(a);
	if (!(f = popen(cmd, "r"))) return;
	while (fgets(line, sizeof(line), f))
	{
		for (p = line; *p; p++) if (*p=='\n' || *p=='\r') { *p = 0; break; }
		if (*line) DLOG_CONDUP("%s%s\n", prefix, line);
	}
	pclose(f);
}

static bool read_line_cmd(const char *cmd, char *out, size_t len)
{
	FILE *f = popen(cmd, "r");
	char *p;

	if (!f) return false;
	*out = 0;
	if (!fgets(out, (int)len, f)) { pclose(f); return false; }
	pclose(f);
	for (p = out; *p; p++) if (*p=='\n' || *p=='\r') { *p = 0; break; }
	return *out != 0;
}

// ------------------------------------------------------------------ uplink --

bool mac_uplink_detect(char *ifname, size_t len)
{
	const char *e = getenv("MACWS_UPLINK");
	char probe[160];

	if (e && *e)
	{
		snprintf(ifname, len, "%s", e);
		return true;
	}
	// маршрут до реального адреса, а не "default": VPN обычно ставит
	// 0.0.0.0/1 + 128.0.0.0/1, и default при этом остаётся на физическом интерфейсе
	snprintf(probe, sizeof(probe),
		"/sbin/route -n get %s 2>/dev/null | /usr/bin/awk '/interface:/{print $2;exit}'",
		env_or("MACWS_SELFTEST_DNS", "8.8.8.8"));
	if (read_line_cmd(probe, ifname, len)) return true;
	return read_line_cmd("/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2;exit}'", ifname, len);
}

// принадлежит ли адрес интерфейсу (проверка "пакет и интерфейс из одной сети")
bool mac_iface_has_addr4(const char *ifname, struct in_addr addr)
{
	struct ifaddrs *ifa, *p;
	bool found = false;

	if (getifaddrs(&ifa)) return false;
	for (p = ifa; p && !found; p = p->ifa_next)
		if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET && !strcmp(p->ifa_name, ifname))
			found = ((struct sockaddr_in*)p->ifa_addr)->sin_addr.s_addr == addr.s_addr;
	freeifaddrs(ifa);
	return found;
}

// имя интерфейса, которому принадлежит адрес (для подсказки про VPN)
static bool iface_by_addr4(struct in_addr addr, char *ifname, size_t len)
{
	struct ifaddrs *ifa, *p;
	bool found = false;

	if (getifaddrs(&ifa)) return false;
	for (p = ifa; p && !found; p = p->ifa_next)
		if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET &&
		    ((struct sockaddr_in*)p->ifa_addr)->sin_addr.s_addr == addr.s_addr)
		{
			snprintf(ifname, len, "%s", p->ifa_name);
			found = true;
		}
	freeifaddrs(ifa);
	return found;
}

// Проверка на "трафик уходит не через тот интерфейс, в который мы отправляем".
// Обычно это включённый VPN. Печатает подсказку один раз.
bool mac_check_source(const void *pkt, size_t len, const char *uplink)
{
	static bool warned = false;
	const struct ip *ip = (const struct ip*)pkt;
	char owner[IFNAMSIZ] = "?", src[INET_ADDRSTRLEN];

	if (warned || len < sizeof(struct ip) || ip->ip_v != 4) return true;
	if (mac_iface_has_addr4(uplink, ip->ip_src)) return true;

	warned = true;
	inet_ntop(AF_INET, &ip->ip_src, src, sizeof(src));
	iface_by_addr4(ip->ip_src, owner, sizeof(owner));
	DLOG_CONDUP("\n!!! packet source %s does not belong to %s (it belongs to %s)\n", src, uplink, owner);
	DLOG_CONDUP("!!! traffic leaves through another interface - most likely a VPN is up.\n");
	DLOG_CONDUP("!!! DPI bypass makes no sense for tunneled traffic: disable the VPN,\n");
	DLOG_CONDUP("!!! or point the backend at the right interface with MACWS_UPLINK=%s\n\n", owner);
	return false;
}

bool mac_iface_addr4(const char *ifname, struct in_addr *addr)
{
	struct ifaddrs *ifa, *p;
	bool found = false;

	if (getifaddrs(&ifa)) { DLOG_PERROR("getifaddrs"); return false; }
	for (p = ifa; p; p = p->ifa_next)
	{
		if (p->ifa_addr && p->ifa_addr->sa_family==AF_INET && !strcmp(p->ifa_name, ifname))
		{
			*addr = ((struct sockaddr_in*)p->ifa_addr)->sin_addr;
			found = true;
			break;
		}
	}
	freeifaddrs(ifa);
	return found;
}

bool mac_iface_addr6(const char *ifname, struct in6_addr *addr)
{
	struct ifaddrs *ifa, *p;
	bool found = false;

	if (getifaddrs(&ifa)) { DLOG_PERROR("getifaddrs"); return false; }
	for (p = ifa; p && !found; p = p->ifa_next)
	{
		if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET6 && !strcmp(p->ifa_name, ifname))
		{
			struct in6_addr *a = &((struct sockaddr_in6*)p->ifa_addr)->sin6_addr;
			// link-local и ULA нашего utun не годятся как источник
			if (IN6_IS_ADDR_LINKLOCAL(a) || IN6_IS_ADDR_LOOPBACK(a) || (a->s6_addr[0] & 0xFE) == 0xFC) continue;
			*addr = *a;
			found = true;
		}
	}
	freeifaddrs(ifa);
	return found;
}

// интерфейс, через который уходит ipv6
bool mac_uplink_detect6(char *ifname, size_t len)
{
	const char *e = getenv("MACWS_UPLINK6");
	char cmd[192];

	if (e && *e) { snprintf(ifname, len, "%s", e); return true; }
	snprintf(cmd, sizeof(cmd),
		"/sbin/route -n get -inet6 %s 2>/dev/null | /usr/bin/awk '/interface:/{print $2;exit}'",
		env_or("MACWS_SELFTEST_DNS6", "2001:4860:4860::8888"));
	return read_line_cmd(cmd, ifname, len);
}

// -------------------------------------------------------------------- utun --

const char *mac_utun_peer(void)
{
	return env_or("MACWS_UTUN_PEER", UTUN_PEER_DEFAULT);
}

const char *mac_utun_peer6(void)
{
	return env_or("MACWS_UTUN_PEER6", UTUN_PEER6_DEFAULT);
}

int mac_utun_open(char *ifname, size_t len)
{
	struct ctl_info ci;
	struct sockaddr_ctl sc;
	socklen_t l;
	int fd, unit, bufsize = 1 << 20;

	fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
	if (fd == -1) { DLOG_PERROR("utun: socket(SYSPROTO_CONTROL)"); return -1; }

	memset(&ci, 0, sizeof(ci));
	strncpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof(ci.ctl_name)-1);
	if (ioctl(fd, CTLIOCGINFO, &ci) == -1)
	{
		DLOG_PERROR("utun: ioctl(CTLIOCGINFO)");
		close(fd);
		return -1;
	}

	memset(&sc, 0, sizeof(sc));
	sc.sc_len = sizeof(sc);
	sc.sc_family = AF_SYSTEM;
	sc.ss_sysaddr = AF_SYS_CONTROL;
	sc.sc_id = ci.ctl_id;
	// sc_unit = N создаёт utun(N-1). Ищем первый свободный.
	for (unit = 100; unit <= 160; unit++)
	{
		sc.sc_unit = unit;
		if (!connect(fd, (struct sockaddr*)&sc, sizeof(sc))) break;
	}
	if (unit > 160)
	{
		DLOG_PERROR("utun: connect");
		close(fd);
		return -1;
	}

	l = (socklen_t)len;
	if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &l) == -1)
	{
		DLOG_PERROR("utun: getsockopt(UTUN_OPT_IFNAME)");
		close(fd);
		return -1;
	}
	if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize)) == -1)
		DLOG_PERROR("utun: setsockopt(SO_RCVBUF) (ignoring)");
	return fd;
}

bool mac_utun_config(const char *ifname)
{
	if (!run_cmd("/sbin/ifconfig %s inet %s %s mtu %s up",
		ifname,
		env_or("MACWS_UTUN_LOCAL", UTUN_LOCAL_DEFAULT),
		mac_utun_peer(),
		env_or("MACWS_UTUN_MTU", "1500")))
		return false;
	// ipv6 — не обязателен: без него просто не будет заворота v6
	{
		const char *l6 = env_or("MACWS_UTUN_LOCAL6", UTUN_LOCAL6_DEFAULT);
		const char *p6 = mac_utun_peer6();
		if (!run_cmd("/sbin/ifconfig %s inet6 %s %s prefixlen 128 2>/dev/null", ifname, l6, p6) &&
		    !(run_cmd("/sbin/ifconfig %s inet6 %s prefixlen 128 2>/dev/null", ifname, l6) &&
		      run_cmd("/sbin/route -q add -inet6 %s -interface %s 2>/dev/null", p6, ifname)))
			DLOG_CONDUP("utun: ipv6 address not configured, ipv6 will not be diverted\n");
	}
	return true;
}

// есть ли вообще маршрут в ipv6-интернет
bool mac_ipv6_available(void)
{
	char ifn[IFNAMSIZ];
	char cmd[192];

	snprintf(cmd, sizeof(cmd),
		"/sbin/route -n get -inet6 %s 2>/dev/null | /usr/bin/awk '/interface:/{print $2;exit}'",
		env_or("MACWS_SELFTEST_DNS6", "2001:4860:4860::8888"));
	return read_line_cmd(cmd, ifn, sizeof(ifn));
}

// --------------------------------------------------------------- checksum ---

bool mac_fix_csum4(void *pkt, size_t len)
{
	struct ip *ip = (struct ip*)pkt;
	size_t hlen, tlen;
	uint16_t was;
	bool valid = true;

	if (len < sizeof(struct ip) || ip->ip_v != 4) return true;
	hlen = (size_t)ip->ip_hl << 2;
	if (hlen < sizeof(struct ip) || len < hlen) return true;
	// у фрагментов транспортный заголовок есть только в первом
	if (ntohs(ip->ip_off) & (IP_OFFMASK|IP_MF)) return true;
	tlen = len - hlen;

	switch (ip->ip_p)
	{
	case IPPROTO_TCP:
		if (tlen >= sizeof(struct tcphdr))
		{
			struct tcphdr *tcp = (struct tcphdr*)((uint8_t*)pkt + hlen);
			was = tcp->th_sum;
			tcp4_fix_checksum(tcp, tlen, &ip->ip_src, &ip->ip_dst);
			valid = (was == tcp->th_sum);
		}
		break;
	case IPPROTO_UDP:
		if (tlen >= sizeof(struct udphdr))
		{
			struct udphdr *udp = (struct udphdr*)((uint8_t*)pkt + hlen);
			was = udp->uh_sum;
			udp4_fix_checksum(udp, tlen, &ip->ip_src, &ip->ip_dst);
			valid = (was == udp->uh_sum);
		}
		break;
	}
	ip4_fix_checksum(ip);
	return valid;
}

bool mac_fix_csum6(void *pkt, size_t len)
{
	struct ip6_hdr *ip6 = (struct ip6_hdr*)pkt;
	uint8_t nxt;
	size_t tlen;
	uint16_t was;
	bool valid = true;

	if (len < sizeof(struct ip6_hdr)) return true;
	if ((ip6->ip6_vfc & 0xF0) != 0x60) return true;
	nxt = ip6->ip6_nxt;
	tlen = len - sizeof(struct ip6_hdr);
	// расширенные заголовки не разбираем: таких пакетов в обходе не бывает
	switch (nxt)
	{
	case IPPROTO_TCP:
		if (tlen >= sizeof(struct tcphdr))
		{
			struct tcphdr *tcp = (struct tcphdr*)((uint8_t*)pkt + sizeof(struct ip6_hdr));
			was = tcp->th_sum;
			tcp6_fix_checksum(tcp, tlen, &ip6->ip6_src, &ip6->ip6_dst);
			valid = (was == tcp->th_sum);
		}
		break;
	case IPPROTO_UDP:
		if (tlen >= sizeof(struct udphdr))
		{
			struct udphdr *udp = (struct udphdr*)((uint8_t*)pkt + sizeof(struct ip6_hdr));
			was = udp->uh_sum;
			udp6_fix_checksum(udp, tlen, &ip6->ip6_src, &ip6->ip6_dst);
			valid = (was == udp->uh_sum);
		}
		break;
	}
	return valid;
}

// ip версия определяется по первому нибблу
bool mac_fix_csum(void *pkt, size_t len)
{
	if (!len) return true;
	return (((*(uint8_t*)pkt) >> 4) == 6) ? mac_fix_csum6(pkt, len) : mac_fix_csum4(pkt, len);
}

// Служебный трафик интерфейса (NDP/MLD, multicast, link-local) в utun попадает
// просто потому, что мы подняли на нём адреса. Обходить его не надо, и наружу
// отправлять нельзя.
bool mac_packet_routable(const void *pkt, size_t len)
{
	uint8_t v;

	if (len < sizeof(struct ip)) return false;
	v = (*(const uint8_t*)pkt) >> 4;
	if (v == 4)
	{
		const struct ip *ip = (const struct ip*)pkt;
		if (!ip->ip_src.s_addr) return false;
		if ((ntohl(ip->ip_dst.s_addr) >> 28) == 0xE) return false;   // 224.0.0.0/4
		return true;
	}
	if (v == 6)
	{
		const struct ip6_hdr *ip6 = (const struct ip6_hdr*)pkt;
		if (len < sizeof(struct ip6_hdr)) return false;
		if (IN6_IS_ADDR_MULTICAST(&ip6->ip6_dst)) return false;
		if (IN6_IS_ADDR_LINKLOCAL(&ip6->ip6_dst)) return false;
		if (IN6_IS_ADDR_LINKLOCAL(&ip6->ip6_src)) return false;
		if (IN6_IS_ADDR_UNSPECIFIED(&ip6->ip6_src)) return false;
		return true;
	}
	return false;
}

// ---------------------------------------------------------------- inject ----

static bool if_mac(const char *ifn, uint8_t mac[6])
{
	struct ifaddrs *ifa, *p;
	bool found = false;

	if (getifaddrs(&ifa)) { DLOG_PERROR("getifaddrs"); return false; }
	for (p = ifa; p; p = p->ifa_next)
	{
		if (p->ifa_addr && p->ifa_addr->sa_family == AF_LINK && !strcmp(p->ifa_name, ifn))
		{
			struct sockaddr_dl *dl = (struct sockaddr_dl*)p->ifa_addr;
			if (dl->sdl_alen == 6) { memcpy(mac, LLADDR(dl), 6); found = true; }
			break;
		}
	}
	freeifaddrs(ifa);
	return found;
}

// mac шлюза по умолчанию из таблицы arp
static bool gw_mac(uint8_t mac[6])
{
	char gw[64], cmd[192], line[128];
	unsigned x[6];
	int i;

	if (!read_line_cmd("/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2;exit}'", gw, sizeof(gw)))
		return false;
	snprintf(cmd, sizeof(cmd), "/usr/sbin/arp -n %s 2>/dev/null | /usr/bin/awk '{print $4;exit}'", gw);
	if (!read_line_cmd(cmd, line, sizeof(line))) return false;
	if (sscanf(line, "%x:%x:%x:%x:%x:%x", x, x+1, x+2, x+3, x+4, x+5) != 6) return false;
	for (i = 0; i < 6; i++) mac[i] = (uint8_t)x[i];
	return true;
}

// mac ipv6-маршрутизатора: gateway из таблицы маршрутов + NDP-кэш
static bool gw_mac6(uint8_t mac[6])
{
	char gw[128], cmd[256], line[160];
	unsigned x[6];
	int i, attempt;

	snprintf(cmd, sizeof(cmd),
		"/sbin/route -n get -inet6 %s 2>/dev/null | /usr/bin/awk '/gateway:/{print $2;exit}'",
		env_or("MACWS_SELFTEST_DNS6", "2001:4860:4860::8888"));
	if (!read_line_cmd(cmd, gw, sizeof(gw))) return false;

	for (attempt = 0; attempt < 2; attempt++)
	{
		snprintf(cmd, sizeof(cmd),
			"/usr/sbin/ndp -an 2>/dev/null | /usr/bin/awk '$1==\"%s\"{print $2;exit}'", gw);
		if (read_line_cmd(cmd, line, sizeof(line)) &&
		    sscanf(line, "%x:%x:%x:%x:%x:%x", x, x+1, x+2, x+3, x+4, x+5) == 6)
		{
			for (i = 0; i < 6; i++) mac[i] = (uint8_t)x[i];
			return true;
		}
		// запись могла быть incomplete — пнём соседа, чтобы она появилась
		if (!attempt) run_cmd("/sbin/ping6 -c 1 -i 1 %s >/dev/null 2>&1", gw);
	}
	return false;
}

// запись кадра напрямую в интерфейс: обходит стек ядра целиком
static bool bpf_init(const char *ifn)
{
	char dev[32];
	struct ifreq ifr;
	uint8_t smac[6], dmac[6];
	int i, yes = 1, bufsize = 1 << 20;

	if (bpf_fd != -1) return true;
	if (!ifn || !*ifn) return false;

	for (i = 0; i < 64; i++)
	{
		snprintf(dev, sizeof(dev), "/dev/bpf%d", i);
		if ((bpf_fd = open(dev, O_RDWR)) != -1) break;
	}
	if (bpf_fd == -1) { DLOG_PERROR("inject: open(/dev/bpf*)"); return false; }
	// размер буфера задаётся до привязки к интерфейсу, иначе не применится
	ioctl(bpf_fd, BIOCSBLEN, &bufsize);
	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "%s", ifn);
	if (ioctl(bpf_fd, BIOCSETIF, &ifr) == -1)
	{
		DLOG_PERROR("inject: ioctl(BIOCSETIF)");
		close(bpf_fd); bpf_fd = -1;
		return false;
	}
	if (ioctl(bpf_fd, BIOCSHDRCMPLT, &yes) == -1) DLOG_PERROR("inject: ioctl(BIOCSHDRCMPLT) (ignoring)");
	if (ioctl(bpf_fd, BIOCGDLT, &bpf_dlt) == -1)
	{
		DLOG_PERROR("inject: ioctl(BIOCGDLT)");
		close(bpf_fd); bpf_fd = -1;
		return false;
	}
	{
		const char *e = getenv("MACWS_WIRE_AUDIT");
		// сверка с проводом — отладочная функция, по умолчанию выключена
		if (e ? strcmp(e, "0") != 0 : mac_diag_on()) audit_on = true;
		if (audit_on || inbound_on)
		{
			int one = 1, fl;
			ioctl(bpf_fd, BIOCIMMEDIATE, &one);
			fl = fcntl(bpf_fd, F_GETFL, 0);
			fcntl(bpf_fd, F_SETFL, fl | O_NONBLOCK);
			DLOG_CONDUP("inject: bpf read enabled (%s%s)\n",
				audit_on ? "аудит провода" : "", inbound_on ? " входящие для autottl" : "");
		}
	}

	bpf_hdr_len = bpf_hdr6_len = 0;
	switch (bpf_dlt)
	{
	case DLT_EN10MB:
		if (!if_mac(ifn, smac))
		{
			DLOG_ERR("inject: no mac address on %s\n", ifn);
			close(bpf_fd); bpf_fd = -1;
			return false;
		}
		if (gw_mac(dmac))
		{
			memcpy(bpf_hdr, dmac, 6);
			memcpy(bpf_hdr + 6, smac, 6);
			bpf_hdr[12] = 0x08; bpf_hdr[13] = 0x00;   // ETHERTYPE_IP
			bpf_hdr_len = 14;
		}
		else
			DLOG_ERR("inject: no arp entry for the ipv4 gateway, ipv4 injection unavailable\n");
		if (gw_mac6(dmac))
		{
			memcpy(bpf_hdr6, dmac, 6);
			memcpy(bpf_hdr6 + 6, smac, 6);
			bpf_hdr6[12] = 0x86; bpf_hdr6[13] = 0xDD; // ETHERTYPE_IPV6
			bpf_hdr6_len = 14;
		}
		if (!bpf_hdr_len && !bpf_hdr6_len)
		{
			close(bpf_fd); bpf_fd = -1;
			return false;
		}
		break;
	case DLT_NULL:
	case DLT_LOOP:
		// у point-to-point интерфейсов вместо ethernet — 4 байта с семейством
		*(uint32_t*)bpf_hdr = (bpf_dlt == DLT_NULL) ? (uint32_t)AF_INET : htonl((uint32_t)AF_INET);
		*(uint32_t*)bpf_hdr6 = (bpf_dlt == DLT_NULL) ? (uint32_t)AF_INET6 : htonl((uint32_t)AF_INET6);
		bpf_hdr_len = bpf_hdr6_len = 4;
		break;
	case DLT_RAW:
		bpf_hdr_len = bpf_hdr6_len = 0;
		break;
	default:
		DLOG_ERR("inject: unsupported link type %d on %s\n", bpf_dlt, ifn);
		close(bpf_fd); bpf_fd = -1;
		return false;
	}
	DLOG_CONDUP("inject: bpf on %s, link type %d, header %zu bytes%s\n",
		ifn, bpf_dlt, bpf_hdr_len ? bpf_hdr_len : bpf_hdr6_len,
		bpf_hdr6_len ? " (ipv4+ipv6)" : " (ipv4 only)");
	return true;
}

// интерфейс выхода мог исчезнуть или измениться: пересоздаём bpf, не чаще раза в секунду
static bool bpf_reinit(void)
{
	static time_t last = 0;
	char ifn[IFNAMSIZ] = "";
	time_t now = time(NULL);

	if (now == last) return false;
	last = now;
	if (bpf_fd != -1) { close(bpf_fd); bpf_fd = -1; }
	if (!mac_uplink_detect(ifn, sizeof(ifn))) return false;
	if (strcmp(ifn, inject_iface))
		DLOG_CONDUP("inject: uplink changed %s -> %s\n", inject_iface, ifn);
	snprintf(inject_iface, sizeof(inject_iface), "%s", ifn);
	return bpf_init(inject_iface);
}

// запомнить отправленный tcp-пакет, чтобы потом найти его на проводе
static void audit_record(const void *pkt, size_t len)
{
	const struct ip *ip = (const struct ip*)pkt;
	size_t hl;
	const struct tcphdr *tcp;
	struct audit_rec *r;

	if (!audit_on || len < sizeof(struct ip) || ip->ip_v != 4 || ip->ip_p != IPPROTO_TCP) return;
	hl = (size_t)ip->ip_hl << 2;
	if (len < hl + sizeof(struct tcphdr)) return;
	tcp = (const struct tcphdr*)((const uint8_t*)pkt + hl);
	r = &wire_audit[audit_pos++ % AUDIT_SLOTS];
	r->saddr = ip->ip_src.s_addr; r->daddr = ip->ip_dst.s_addr;
	r->sport = tcp->th_sport; r->dport = tcp->th_dport;
	r->seq = tcp->th_seq; r->len = (uint16_t)len; r->seen = false;
	audit_sent++;
}

static void inb_push(const uint8_t *pkt, size_t len)
{
	unsigned next = (inb_head + 1) % INB_SLOTS;

	if (len > INB_MAX || next == inb_tail) return;   // очередь полна — не беда
	memcpy(inb_buf[inb_head], pkt, len);
	inb_len[inb_head] = len;
	inb_head = next;
}

bool mac_inbound_next(uint8_t *out, size_t outsize, size_t *len)
{
	if (inb_tail == inb_head) mac_wire_audit_drain();
	if (inb_tail == inb_head) return false;
	*len = inb_len[inb_tail];
	if (*len > outsize) { inb_tail = (inb_tail + 1) % INB_SLOTS; return false; }
	memcpy(out, inb_buf[inb_tail], *len);
	inb_tail = (inb_tail + 1) % INB_SLOTS;
	return true;
}

// прочитать, что реально прошло через интерфейс: отметить свои пакеты (аудит)
// и собрать входящие для движка
void mac_wire_audit_drain(void)
{
	static uint8_t *rbuf = NULL;
	static size_t rlen = 0;
	uint8_t *p, *end;
	ssize_t rd;
	unsigned i;

	if (bpf_fd == -1 || (!audit_on && !inbound_on)) return;
	if (!rbuf)
	{
		int blen = 0;
		if (ioctl(bpf_fd, BIOCGBLEN, &blen) == -1 || blen <= 0) blen = 1 << 20;
		if (!(rbuf = malloc((size_t)blen))) { audit_on = false; return; }
		rlen = (size_t)blen;
	}
	while ((rd = read(bpf_fd, rbuf, rlen)) > 0)
	{
		for (p = rbuf, end = rbuf + rd; p + sizeof(struct bpf_hdr) <= end; )
		{
			struct bpf_hdr *bh = (struct bpf_hdr*)p;
			uint8_t *frame = p + bh->bh_hdrlen;
			size_t caplen = bh->bh_caplen;

			if (bh->bh_hdrlen == 0 || frame + caplen > end) break;
			if (caplen > bpf_hdr_len + sizeof(struct ip) &&
			    (bpf_hdr_len != 14 || (frame[12] == 0x08 && frame[13] == 0x00)))
			{
				struct ip *ip = (struct ip*)(frame + bpf_hdr_len);
				size_t hl = (size_t)ip->ip_hl << 2;
				if (ip->ip_v == 4 && ip->ip_p == IPPROTO_TCP && caplen >= bpf_hdr_len + hl + sizeof(struct tcphdr))
				{
					struct tcphdr *tcp = (struct tcphdr*)(frame + bpf_hdr_len + hl);
					if (audit_on)
						for (i = 0; i < AUDIT_SLOTS; i++)
						{
							struct audit_rec *r = &wire_audit[i];
							if (!r->seen && r->saddr == ip->ip_src.s_addr && r->daddr == ip->ip_dst.s_addr &&
							    r->sport == tcp->th_sport && r->dport == tcp->th_dport && r->seq == tcp->th_seq)
							{
								r->seen = true;
								audit_seen++;
								break;
							}
						}
					// входящий к нам, с SYN или RST — движку для autottl
					if (inbound_on && uplink_addr4.s_addr &&
					    ip->ip_dst.s_addr == uplink_addr4.s_addr &&
					    ip->ip_src.s_addr != uplink_addr4.s_addr &&
					    (tcp->th_flags & (TH_SYN|TH_RST)))
					{
						size_t plen = (size_t)ntohs(ip->ip_len);
						if (plen && plen <= caplen - bpf_hdr_len) inb_push((uint8_t*)ip, plen);
					}
				}
			}
			p += BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
		}
	}
}

void mac_wire_audit_report(void)
{
	if (!audit_on) return;
	DLOG_CONDUP("wire audit: injected %llu tcp packets, confirmed on the wire %llu\n",
		(unsigned long long)audit_sent, (unsigned long long)audit_seen);
	if (audit_sent && !audit_seen)
		DLOG_CONDUP("wire audit: NOTHING reached the interface — инъекция не доходит до провода\n");
}

static bool bpf_send(const void *pkt, size_t len, bool v6)
{
	uint8_t frame[16384 + 16];
	uint8_t *hdr;
	size_t hlen, flen;
	ssize_t n;

	if (bpf_fd == -1 && !bpf_reinit()) return false;
	hdr = v6 ? bpf_hdr6 : bpf_hdr;
	hlen = v6 ? bpf_hdr6_len : bpf_hdr_len;
	if (v6 && !bpf_hdr6_len && bpf_dlt == DLT_EN10MB)
	{
		DLOG_ERR("inject: no ipv6 link header (no ndp entry for the ipv6 router)\n");
		return false;
	}
	if (len + hlen > sizeof(frame)) { DLOG_ERR("inject: packet too big (%zu)\n", len); return false; }
	if (hlen) memcpy(frame, hdr, hlen);
	memcpy(frame + hlen, pkt, len);
	// Движок оставляет контрольную сумму ip-заголовка нулевой: при отправке через
	// raw-сокет её считает ядро. Мы пишем кадр напрямую на провод, минуя ядро,
	// поэтому считаем сами — иначе первый маршрутизатор отбросит пакет.
	// Транспортную сумму не трогаем: fooling=badsum портит её намеренно.
	if (!v6 && len >= sizeof(struct ip))
	{
		struct ip *ip4 = (struct ip*)(frame + hlen);
		if (!ip4->ip_sum) ip4_fix_checksum(ip4);
	}
	flen = len + hlen;
	// минимальный ethernet-кадр 60 байт: короткие сегменты (например split-pos=1)
	// иначе может отбросить драйвер
	if (bpf_dlt == DLT_EN10MB && flen < 60) { memset(frame + flen, 0, 60 - flen); flen = 60; }
	n = write(bpf_fd, frame, flen);
	if (n != -1 && !v6) audit_record(pkt, len);
	if (n == -1)
	{
		// mac маршрутизатора мог измениться (смена сети) — перестроим заголовок
		if (bpf_dlt == DLT_EN10MB && (v6 ? gw_mac6(hdr) : gw_mac(hdr)))
		{
			memcpy(frame, hdr, hlen);
			n = write(bpf_fd, frame, flen);
		}
		// интерфейс мог вообще исчезнуть (отключили VPN, сменили сеть)
		if (n == -1 && bpf_reinit())
		{
			hdr = v6 ? bpf_hdr6 : bpf_hdr;
			hlen = v6 ? bpf_hdr6_len : bpf_hdr_len;
			if (hlen) memcpy(frame, hdr, hlen);
			n = write(bpf_fd, frame, flen);
		}
		if (n == -1) { DLOG_PERROR("inject: bpf write"); return false; }
	}
	return true;
}

// Считает на интерфейсе пакеты udp/53 к резолверу и от него. Нужно, чтобы
// отличить "наш пакет не ушёл" от "ответ пришёл, но не дошёл до приложения".
static void bpf_count_dns(const struct in_addr *resolver, int *out_q, int *in_a)
{
	static uint8_t *rbuf = NULL;
	static size_t rlen = 0;
	uint8_t *p, *end;
	ssize_t rd;
	int flags;

	if (bpf_fd == -1) return;
	if (!rbuf)
	{
		int blen = 0;
		if (ioctl(bpf_fd, BIOCGBLEN, &blen) == -1 || blen <= 0) blen = 32768;
		if (!(rbuf = malloc((size_t)blen))) return;
		rlen = (size_t)blen;
		flags = 1;
		ioctl(bpf_fd, BIOCIMMEDIATE, &flags);
		flags = fcntl(bpf_fd, F_GETFL, 0);
		fcntl(bpf_fd, F_SETFL, flags | O_NONBLOCK);
	}

	while ((rd = read(bpf_fd, rbuf, rlen)) > 0)
	{
		for (p = rbuf, end = rbuf + rd; p + sizeof(struct bpf_hdr) <= end; )
		{
			struct bpf_hdr *bh = (struct bpf_hdr*)p;
			uint8_t *frame = p + bh->bh_hdrlen;
			size_t caplen = bh->bh_caplen;

			if (bh->bh_hdrlen == 0 || frame + caplen > end) break;
			// у ethernet пропускаем 14 байт и проверяем ethertype, у utun (DLT_NULL) — 4
			if (caplen > bpf_hdr_len + 28 &&
			    (bpf_hdr_len != 14 || (frame[12] == 0x08 && frame[13] == 0x00)))
			{
				struct ip *ip = (struct ip*)(frame + bpf_hdr_len);
				size_t hl = (size_t)ip->ip_hl << 2;
				if (ip->ip_v == 4 && ip->ip_p == IPPROTO_UDP && caplen >= bpf_hdr_len + hl + 4)
				{
					uint16_t sp = ntohs(*(uint16_t*)(frame + bpf_hdr_len + hl));
					uint16_t dp = ntohs(*(uint16_t*)(frame + bpf_hdr_len + hl + 2));
					if (dp == 53 && ip->ip_dst.s_addr == resolver->s_addr) (*out_q)++;
					else if (sp == 53 && ip->ip_src.s_addr == resolver->s_addr) (*in_a)++;
				}
			}
			p += BPF_WORDALIGN(bh->bh_hdrlen + bh->bh_caplen);
		}
	}
}

static bool raw_init(void)
{
	int yes = 1, bufsize = 1 << 20;
	unsigned int idx;

	if (inject_sock != -1) return true;
	inject_sock = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
	if (inject_sock == -1) { DLOG_PERROR("inject: socket(SOCK_RAW)"); return false; }
	if (setsockopt(inject_sock, IPPROTO_IP, IP_HDRINCL, &yes, sizeof(yes)) == -1)
	{
		DLOG_PERROR("inject: setsockopt(IP_HDRINCL)");
		close(inject_sock);
		inject_sock = -1;
		return false;
	}
	if (setsockopt(inject_sock, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof(bufsize)) == -1)
		DLOG_PERROR("inject: setsockopt(SO_SNDBUF) (ignoring)");
	// IP_BOUND_IF жёстко прибивает пакет к uplink, но на части систем ломает
	// поиск маршрута (EHOSTUNREACH), поэтому по умолчанию выключено
	if (*inject_iface && getenv("MACWS_BOUND_IF") && strcmp(getenv("MACWS_BOUND_IF"), "0") &&
	    (idx = if_nametoindex(inject_iface)))
	{
		if (setsockopt(inject_sock, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof(idx)) == -1)
			DLOG_PERROR("inject: setsockopt(IP_BOUND_IF) (ignoring)");
		else
			inject_bound = true;
	}
	return true;
}

bool mac_inject_init(const char *uplink)
{
	const char *e;

	if (uplink && *uplink) snprintf(inject_iface, sizeof(inject_iface), "%s", uplink);
	e = getenv("MACWS_MAX_PPS");
	if (e && *e) pps_limit = (uint32_t)strtoul(e, NULL, 10);
	if (*inject_iface) mac_iface_addr4(inject_iface, &uplink_addr4);
	e = getenv("MACWS_INBOUND");
	if (e && !strcmp(e, "0")) inbound_on = false;
	e = getenv("MACWS_INJECT");
	if (e && !strcmp(e, "bpf"))
	{
		if (!bpf_init(inject_iface)) return false;
		inject_mode = INJ_BPF;
		return true;
	}
	if (e && !strcmp(e, "raw"))
	{
		inject_mode = INJ_RAW;
		return raw_init();
	}
	// по умолчанию пишем кадр через bpf: в свежих macOS raw-сокет с IP_HDRINCL
	// не находит маршрут (EHOSTUNREACH). Если bpf недоступен — остаётся raw.
	if (bpf_init(inject_iface))
	{
		inject_mode = INJ_BPF;
		return true;
	}
	DLOG_CONDUP("inject: bpf is not available, falling back to raw socket\n");
	return raw_init();
}

bool mac_inject_overload(void)
{
	return overload;
}

bool mac_inject4(void *pkt, size_t len)
{
	struct ip *ip = (struct ip*)pkt;
	struct sockaddr_in sa;
	uint16_t ip_len, ip_off;
	ssize_t n;
	time_t now;

	if (inject_mode != INJ_BPF && inject_sock == -1)
	{
		DLOG_ERR("inject: not initialized\n");
		return false;
	}
	if (len < sizeof(struct ip) || ip->ip_v != 4)
	{
		DLOG_ERR("inject: not an ipv4 packet (len=%zu)\n", len);
		return false;
	}

	// защита от шторма (например если pf всё-таки заворачивает наши же пакеты)
	now = time(NULL);
	if (now != pps_sec) { pps_sec = now; pps_count = 0; }
	if (pps_limit && ++pps_count > pps_limit)
	{
		if (!overload) DLOG_ERR("inject: more than %u packets per second, possible routing loop\n", pps_limit);
		overload = true;
		return false;
	}

	if (inject_mode == INJ_BPF) return bpf_send(pkt, len, false);

	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_len = sizeof(sa);
	sa.sin_addr = ip->ip_dst;

	// macOS ждёт ip_len и ip_off в host byte order при IP_HDRINCL (xnu ip_output)
	ip_len = ip->ip_len;
	ip_off = ip->ip_off;
	ip->ip_len = ntohs(ip_len);
	ip->ip_off = ntohs(ip_off);
	n = sendto(inject_sock, pkt, len, 0, (struct sockaddr*)&sa, sizeof(sa));
	if (n == -1 && inject_bound && (errno == EHOSTUNREACH || errno == ENETUNREACH))
	{
		// снимаем IP_BOUND_IF и пробуем ещё раз
		unsigned int zero = 0;
		DLOG_CONDUP("inject: %s with IP_BOUND_IF, retrying without it\n", strerror(errno));
		setsockopt(inject_sock, IPPROTO_IP, IP_BOUND_IF, &zero, sizeof(zero));
		inject_bound = false;
		n = sendto(inject_sock, pkt, len, 0, (struct sockaddr*)&sa, sizeof(sa));
	}
	ip->ip_len = ip_len;
	ip->ip_off = ip_off;

	if (n == -1)
	{
		int e = errno;
		DLOG_PERROR("inject: sendto");
		// raw-сокет не заработал: переходим на запись кадра через bpf
		if (inject_mode == INJ_AUTO && (e == EHOSTUNREACH || e == ENETUNREACH || e == EACCES || e == EPERM || e == EINVAL))
		{
			DLOG_CONDUP("inject: raw socket does not work, switching to bpf\n");
			if (bpf_init(inject_iface))
			{
				inject_mode = INJ_BPF;
				return bpf_send(pkt, len, false);
			}
		}
		return false;
	}
	if ((size_t)n != len)
	{
		DLOG_ERR("inject: sent %zd of %zu bytes\n", n, len);
		return false;
	}
	if (inject_mode == INJ_AUTO) inject_mode = INJ_RAW;   // raw работает, фиксируем
	return true;
}

// ipv6 отправляется только через bpf: в macOS SDK нет IPV6_HDRINCL
bool mac_inject6(void *pkt, size_t len)
{
	time_t now;

	if (len < sizeof(struct ip6_hdr) || ((*(uint8_t*)pkt) >> 4) != 6)
	{
		DLOG_ERR("inject: not an ipv6 packet (len=%zu)\n", len);
		return false;
	}
	now = time(NULL);
	if (now != pps_sec) { pps_sec = now; pps_count = 0; }
	if (pps_limit && ++pps_count > pps_limit)
	{
		if (!overload) DLOG_ERR("inject: more than %u packets per second, possible routing loop\n", pps_limit);
		overload = true;
		return false;
	}
	if (bpf_fd == -1 && !bpf_init(inject_iface))
	{
		DLOG_ERR("inject: ipv6 needs bpf, and it is not available\n");
		return false;
	}
	return bpf_send(pkt, len, true);
}

// общий вход: версия определяется по пакету
bool mac_inject(void *pkt, size_t len)
{
	bool r;

	if (!len) return false;
	r = (((*(uint8_t*)pkt) >> 4) == 6) ? mac_inject6(pkt, len) : mac_inject4(pkt, len);
	if (r) inj_ok++; else inj_fail++;
	return r;
}

void mac_inject_stats(uint64_t *ok, uint64_t *fail)
{
	*ok = inj_ok;
	*fail = inj_fail;
}

void mac_inject_cleanup(void)
{
	mac_wire_audit_drain();
	mac_wire_audit_report();
	if (inj_ok || inj_fail)
		DLOG_CONDUP("inject: %llu packets sent, %llu failed\n",
			(unsigned long long)inj_ok, (unsigned long long)inj_fail);
	if (inject_sock != -1) { close(inject_sock); inject_sock = -1; }
	if (bpf_fd != -1) { close(bpf_fd); bpf_fd = -1; }
}

bool inject_mode_is_bpf(void)
{
	return inject_mode == INJ_BPF;
}

const char *mac_inject_method(void)
{
	switch (inject_mode)
	{
	case INJ_BPF: return "bpf";
	case INJ_RAW: return "raw socket";
	default: return "raw socket (not confirmed yet)";
	}
}

// -------------------------------------------------------------------- pf ----

bool mac_pf_enabled(void)
{
	char line[128];
	return read_line_cmd("/sbin/pfctl -s info 2>/dev/null | /usr/bin/awk '/^Status: Enabled/{print \"1\";exit}'", line, sizeof(line));
}

bool mac_pf_load_rules(const char *rules)
{
	const char *anchor = env_or("MACWS_PF_ANCHOR", PF_ANCHOR_DEFAULT);
	char cmd[256];
	FILE *f;
	int rc;

	snprintf(cmd, sizeof(cmd), "/sbin/pfctl -a %s -f - 2>&1", anchor);
	if (!(f = popen(cmd, "w"))) { DLOG_PERROR("pf: popen(pfctl)"); return false; }
	fputs(rules, f);
	rc = pclose(f);
	if (rc)
	{
		DLOG_ERR("pf: pfctl -a %s -f - failed (rc=%d). rules:\n%s", anchor, rc, rules);
		return false;
	}
	snprintf(pf_anchor_loaded, sizeof(pf_anchor_loaded), "%s", anchor);
	DLOG_CONDUP("pf: loaded rules into anchor \"%s\"\n", anchor);
	if (!mac_pf_enabled())
		DLOG_CONDUP("pf: WARNING ! pf is disabled, rules will not work. enable it: pfctl -E\n");
	// что на самом деле в pf: без этого молчаливую неработу не отличить.
	// Отладочная диагностика — только при MACWS_DIAG=1 (DEBUG_TOOLS=1 в zapret.sh)
	if (mac_diag_on())
	{
		log_cmd("pf: ", "/sbin/pfctl -s info 2>/dev/null | /usr/bin/head -2");
		log_cmd("pf: anchor rule: ", "/sbin/pfctl -a %s -sr 2>/dev/null", anchor);
		log_cmd("pf: main ruleset: ", "/sbin/pfctl -sr 2>/dev/null | /usr/bin/head -10");
		log_cmd("pf: anchors: ", "/sbin/pfctl -sA 2>/dev/null | /usr/bin/head -10");
	}
	return true;
}

// ------------------------------------------------------------------ tso ----
// TCP к адресам за en0 (там есть TSO) отдаёт крупный запрос одним суперпакетом
// больше MTU. Когда pf уводит его route-to в utun, где TSO нет, а в пакете стоит
// DF, pf его выбрасывает (счётчик «datagrams that can't be fragmented»). Дальше
// TCP досылает хвост пробой раньше, чем голову, и ClientHello из двух сегментов
// приходит в движок задом наперёд: сборка срывается, голова уходит без desync.
// Пока заворот активен, TSO выключаем; исходное значение пишем в файл-метку,
// чтобы его вернул и zapret.sh, если движок завершится аварийно. /var/run
// чистится при загрузке — как и сам sysctl.
#define TSO_MARK "/var/run/macws.tso"
static int tso_saved = -1;

static void mac_tso_disable(void)
{
	int v = 0, off = 0;
	size_t sz = sizeof(v);
	const char *e = getenv("MACWS_TSO");
	FILE *f;

	if (e && !strcmp(e, "keep"))
	{
		DLOG_CONDUP("tso: MACWS_TSO=keep, leaving net.inet.tcp.tso as is\n");
		return;
	}
	if (sysctlbyname("net.inet.tcp.tso", &v, &sz, NULL, 0) == -1)
	{
		DLOG_PERROR("tso: sysctl net.inet.tcp.tso");
		return;
	}
	if (!v) return;
	if (sysctlbyname("net.inet.tcp.tso", NULL, NULL, &off, sizeof(off)) == -1)
	{
		DLOG_PERROR("tso: cannot set net.inet.tcp.tso=0");
		return;
	}
	tso_saved = v;
	if ((f = fopen(TSO_MARK, "w"))) { fprintf(f, "%d\n", v); fclose(f); }
	DLOG_CONDUP("tso: net.inet.tcp.tso=0 while diverting (was %d)\n", v);
}

static void mac_tso_restore(void)
{
	if (tso_saved < 0) return;
	if (sysctlbyname("net.inet.tcp.tso", NULL, NULL, &tso_saved, sizeof(tso_saved)) == -1)
		DLOG_PERROR("tso: cannot restore net.inet.tcp.tso");
	else
	{
		unlink(TSO_MARK);
		DLOG_CONDUP("tso: net.inet.tcp.tso=%d restored\n", tso_saved);
	}
	tso_saved = -1;
}

bool mac_pf_apply(const char *utun_if)
{
	const char *file = getenv("MACWS_PF_RULES");
	char *buf = NULL, *out = NULL, *s, *d, *tok;
	long size;
	size_t outsize;
	FILE *f;
	bool res = false;

	if (!file || !*file)
	{
		DLOG_CONDUP("pf: MACWS_PF_RULES is not set, not touching pf (set up route-to rules yourself)\n");
		return true;
	}
	if (!(f = fopen(file, "rb"))) { DLOG_PERROR("pf: cannot open MACWS_PF_RULES"); return false; }
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size < 0 || size > 1024*1024) { fclose(f); DLOG_ERR("pf: bad rules file size\n"); return false; }
	if (!(buf = malloc((size_t)size + 1))) { fclose(f); DLOG_ERR("pf: out of memory\n"); return false; }
	if (fread(buf, 1, (size_t)size, f) != (size_t)size) { fclose(f); free(buf); DLOG_ERR("pf: cannot read rules\n"); return false; }
	fclose(f);
	buf[size] = 0;

	// подстановка %UTUN% : имя интерфейса известно только после его создания
	outsize = (size_t)size + 64 * (strlen(buf) / 6 + 1) + 1;
	if (!(out = malloc(outsize))) { free(buf); DLOG_ERR("pf: out of memory\n"); return false; }
	for (s = buf, d = out; *s; )
	{
		if ((tok = strstr(s, "%UTUN%")) != NULL)
		{
			memcpy(d, s, (size_t)(tok - s));
			d += tok - s;
			d += sprintf(d, "%s", utun_if);
			s = tok + 6;
		}
		else
		{
			strcpy(d, s);
			d += strlen(s);
			break;
		}
	}
	*d = 0;
	res = mac_pf_load_rules(out);
	free(out);
	free(buf);
	if (res) mac_tso_disable();
	return res;
}

void mac_pf_flush(void)
{
	mac_tso_restore();
	if (!*pf_anchor_loaded) return;
	DLOG_CONDUP("pf: flushing anchor \"%s\"\n", pf_anchor_loaded);
	run_cmd("/sbin/pfctl -a %s -F all 2>/dev/null", pf_anchor_loaded);
	*pf_anchor_loaded = 0;
}

// -------------------------------------------------------------- selftest ----

// 1) инъекция: сами собираем DNS-запрос и ждём ответ на обычный udp-сокет
static bool selftest_inject(const char *uplink)
{
	uint8_t pkt[512];
	struct ip *ip = (struct ip*)pkt;
	struct udphdr *udp = (struct udphdr*)(pkt + sizeof(struct ip));
	uint8_t *dns = pkt + sizeof(struct ip) + sizeof(struct udphdr);
	static const uint8_t query[] = {
		0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		7,'e','x','a','m','p','l','e', 3,'c','o','m', 0, 0x00, 0x01, 0x00, 0x01
	};
	struct in_addr src;
	struct sockaddr_in sa;
	socklen_t salen;
	const char *resolver = env_or("MACWS_SELFTEST_DNS", "8.8.8.8");
	size_t dnslen = sizeof(query), udplen = sizeof(struct udphdr) + dnslen, iplen = sizeof(struct ip) + udplen;
	int s;
	fd_set fds;
	struct timeval tv = { 3, 0 };
	uint8_t reply[512];
	bool ok = false;

	if (!mac_iface_addr4(uplink, &src))
	{
		DLOG_CONDUP("selftest: no ipv4 address on %s\n", uplink);
		return false;
	}

	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s == -1) { DLOG_PERROR("selftest: socket"); return false; }
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_len = sizeof(sa);
	if (bind(s, (struct sockaddr*)&sa, sizeof(sa)) == -1) { DLOG_PERROR("selftest: bind"); close(s); return false; }
	salen = sizeof(sa);
	if (getsockname(s, (struct sockaddr*)&sa, &salen) == -1) { DLOG_PERROR("selftest: getsockname"); close(s); return false; }

	memset(pkt, 0, sizeof(pkt));
	ip->ip_v = 4;
	ip->ip_hl = sizeof(struct ip) >> 2;
	ip->ip_len = htons((uint16_t)iplen);
	ip->ip_id = htons(0x1234);
	ip->ip_ttl = 64;
	ip->ip_p = IPPROTO_UDP;
	ip->ip_src = src;
	if (!inet_aton(resolver, &ip->ip_dst)) { DLOG_ERR("selftest: bad MACWS_SELFTEST_DNS\n"); close(s); return false; }
	udp->uh_sport = sa.sin_port;
	udp->uh_dport = htons(53);
	udp->uh_ulen = htons((uint16_t)udplen);
	memcpy(dns, query, dnslen);
	ip4_fix_checksum(ip);
	udp4_fix_checksum(udp, udplen, &ip->ip_src, &ip->ip_dst);

	DLOG_CONDUP("selftest: injecting dns query %s:%u -> %s:53 (%zu bytes)\n",
		inet_ntoa(src), ntohs(sa.sin_port), resolver, iplen);
	if (!mac_inject4(pkt, iplen))
	{
		DLOG_CONDUP("selftest: INJECTION FAILED\n");
		close(s);
		return false;
	}

	FD_ZERO(&fds);
	FD_SET(s, &fds);
	if (select(s + 1, &fds, NULL, NULL, &tv) > 0)
	{
		ssize_t rd = recv(s, reply, sizeof(reply), 0);
		if (rd >= 12 && reply[0]==0xAB && reply[1]==0xCD)
		{
			DLOG_CONDUP("selftest: got dns reply (%zd bytes) -> injection works via %s\n", rd, mac_inject_method());
			ok = true;
		}
		else
			DLOG_CONDUP("selftest: got unexpected reply (%zd bytes)\n", rd);
	}
	else
		DLOG_CONDUP("selftest: no dns reply in 3s -> injection does NOT work (method: %s)\n", mac_inject_method());

	close(s);
	return ok;
}

// 1b) то же самое для ipv6
static bool selftest_inject6(const char *uplink)
{
	uint8_t pkt[512];
	struct ip6_hdr *ip6 = (struct ip6_hdr*)pkt;
	struct udphdr *udp = (struct udphdr*)(pkt + sizeof(struct ip6_hdr));
	uint8_t *dns = pkt + sizeof(struct ip6_hdr) + sizeof(struct udphdr);
	static const uint8_t query[] = {
		0xAB, 0xC6, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		7,'e','x','a','m','p','l','e', 3,'c','o','m', 0, 0x00, 0x01, 0x00, 0x01
	};
	struct in6_addr src;
	struct sockaddr_in6 sa;
	socklen_t salen;
	const char *resolver = env_or("MACWS_SELFTEST_DNS6", "2001:4860:4860::8888");
	size_t dnslen = sizeof(query), udplen = sizeof(struct udphdr) + dnslen;
	size_t iplen = sizeof(struct ip6_hdr) + udplen;
	int s;
	fd_set fds;
	struct timeval tv = { 3, 0 };
	uint8_t reply[512];
	char srcs[INET6_ADDRSTRLEN];
	bool ok = false;

	if (!mac_iface_addr6(uplink, &src))
	{
		DLOG_CONDUP("selftest6: no global ipv6 address on %s\n", uplink);
		return false;
	}

	s = socket(AF_INET6, SOCK_DGRAM, 0);
	if (s == -1) { DLOG_PERROR("selftest6: socket"); return false; }
	memset(&sa, 0, sizeof(sa));
	sa.sin6_family = AF_INET6;
	sa.sin6_len = sizeof(sa);
	if (bind(s, (struct sockaddr*)&sa, sizeof(sa)) == -1) { DLOG_PERROR("selftest6: bind"); close(s); return false; }
	salen = sizeof(sa);
	if (getsockname(s, (struct sockaddr*)&sa, &salen) == -1) { DLOG_PERROR("selftest6: getsockname"); close(s); return false; }

	memset(pkt, 0, sizeof(pkt));
	ip6->ip6_vfc = 0x60;
	ip6->ip6_plen = htons((uint16_t)udplen);
	ip6->ip6_nxt = IPPROTO_UDP;
	ip6->ip6_hlim = 64;
	ip6->ip6_src = src;
	if (inet_pton(AF_INET6, resolver, &ip6->ip6_dst) != 1)
	{
		DLOG_ERR("selftest6: bad MACWS_SELFTEST_DNS6\n");
		close(s);
		return false;
	}
	udp->uh_sport = sa.sin6_port;
	udp->uh_dport = htons(53);
	udp->uh_ulen = htons((uint16_t)udplen);
	memcpy(dns, query, dnslen);
	udp6_fix_checksum(udp, udplen, &ip6->ip6_src, &ip6->ip6_dst);

	inet_ntop(AF_INET6, &src, srcs, sizeof(srcs));
	DLOG_CONDUP("selftest6: injecting dns query [%s]:%u -> [%s]:53 (%zu bytes)\n",
		srcs, ntohs(sa.sin6_port), resolver, iplen);
	if (!mac_inject6(pkt, iplen))
	{
		DLOG_CONDUP("selftest6: INJECTION FAILED\n");
		close(s);
		return false;
	}

	FD_ZERO(&fds);
	FD_SET(s, &fds);
	if (select(s + 1, &fds, NULL, NULL, &tv) > 0)
	{
		ssize_t rd = recv(s, reply, sizeof(reply), 0);
		if (rd >= 12 && reply[0]==0xAB && reply[1]==0xC6)
		{
			DLOG_CONDUP("selftest6: got dns reply (%zd bytes) -> ipv6 injection works\n", rd);
			ok = true;
		}
		else
			DLOG_CONDUP("selftest6: got unexpected reply (%zd bytes)\n", rd);
	}
	else
		DLOG_CONDUP("selftest6: no dns reply in 3s -> ipv6 injection does NOT work\n");

	close(s);
	return ok;
}

// 2b) заворот ipv6 через pf + utun
static bool selftest_divert6(const char *uplink)
{
	char utun_if[IFNAMSIZ] = "", rules[512];
	const char *ip_s = env_or("MACWS_SELFTEST_DNS6", "2001:4860:4860::8888");
	int utun_fd, packets = 0, child_rc = -1;
	uid_t uid;
	pid_t pid;
	struct in6_addr dst;
	time_t deadline;
	bool ok;

	if (inet_pton(AF_INET6, ip_s, &dst) != 1) { DLOG_ERR("selftest6: bad MACWS_SELFTEST_DNS6\n"); return false; }

	if ((utun_fd = mac_utun_open(utun_if, sizeof(utun_if))) == -1) return false;
	DLOG_CONDUP("selftest6: created %s\n", utun_if);
	if (!mac_utun_config(utun_if)) { close(utun_fd); return false; }

	snprintf(rules, sizeof(rules),
		"pass out route-to (%s %s) inet6 proto udp from any to %s port 53 user { >root } no state\n",
		utun_if, mac_utun_peer6(), ip_s);
	if (!mac_pf_load_rules(rules)) { close(utun_fd); return false; }

	uid = (uid_t)atoi(env_or("SUDO_UID", "65534"));
	DLOG_CONDUP("selftest6: sending ipv6 dns query to [%s]:53 as uid %u\n", ip_s, uid);

	pid = fork();
	if (pid == 0)
	{
		static const uint8_t q[] = {
			0x5A, 0xA6, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			7,'e','x','a','m','p','l','e', 3,'c','o','m', 0, 0x00, 0x01, 0x00, 0x01
		};
		uint8_t reply[512];
		struct sockaddr_in6 to;
		struct timeval tv = { 2, 0 };
		int c, i;

		if (setgid((gid_t)uid) || setuid(uid)) _exit(3);
		memset(&to, 0, sizeof(to));
		to.sin6_family = AF_INET6;
		to.sin6_len = sizeof(to);
		to.sin6_port = htons(53);
		to.sin6_addr = dst;
		if ((c = socket(AF_INET6, SOCK_DGRAM, 0)) == -1) _exit(4);
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		if (connect(c, (struct sockaddr*)&to, sizeof(to))) _exit(5);
		for (i = 0; i < 3; i++)
		{
			if (send(c, q, sizeof(q), 0) < 0) _exit(6);
			if (recv(c, reply, sizeof(reply), 0) >= 12 && reply[0]==0x5A && reply[1]==0xA6) _exit(0);
		}
		_exit(1);
	}
	if (pid == -1) { DLOG_PERROR("selftest6: fork"); mac_pf_flush(); close(utun_fd); return false; }

	fcntl(utun_fd, F_SETFL, fcntl(utun_fd, F_GETFL, 0) | O_NONBLOCK);
	for (deadline = time(NULL) + 8; time(NULL) < deadline; )
	{
		uint8_t buf[16384];
		ssize_t rd = read(utun_fd, buf, sizeof(buf));
		int st;

		if (rd > 4)
		{
			bool sent;
			packets++;
			mac_fix_csum(buf + 4, (size_t)rd - 4);
			sent = mac_inject(buf + 4, (size_t)rd - 4);
			if (packets == 1)
				DLOG_CONDUP("selftest6: got packet from %s (ipv%d), injected %s\n",
					utun_if, ((buf[4] >> 4) == 6) ? 6 : 4, sent ? "OK" : "FAILED");
		}
		else
			usleep(20000);
		if (child_rc == -1 && waitpid(pid, &st, WNOHANG) == pid)
		{
			child_rc = WIFEXITED(st) ? WEXITSTATUS(st) : 99;
			if (packets) break;
		}
	}
	if (child_rc == -1)
	{
		int st;
		kill(pid, SIGKILL);
		waitpid(pid, &st, 0);
		child_rc = 98;
	}

	DLOG_CONDUP("selftest6: packets from utun: %d, dns answer through us: %s (code %d)\n",
		packets, child_rc==0 ? "OK" : "FAILED", child_rc);
	ok = packets > 0 && child_rc == 0;
	mac_pf_flush();
	close(utun_fd);
	return ok;
}

// 2) utun + pf route-to: ребёнок (не root) шлёт dns-запрос, мы должны увидеть
// его пакет в utun, отправить заново и получить ответ у ребёнка
static bool selftest_divert(const char *uplink)
{
	char utun_if[IFNAMSIZ] = "", rules[512];
	const char *ip_s = env_or("MACWS_SELFTEST_DNS", "8.8.8.8");
	int port = 53;
	int utun_fd, packets = 0, child_rc = -1, wire_q = 0, wire_a = 0;
	struct in_addr last_src = { 0 };
	uid_t uid;
	pid_t pid;
	struct in_addr dst;
	time_t deadline;
	bool ok;

	if (!inet_aton(ip_s, &dst)) { DLOG_ERR("selftest: bad MACWS_SELFTEST_DNS\n"); return false; }

	if ((utun_fd = mac_utun_open(utun_if, sizeof(utun_if))) == -1) return false;
	DLOG_CONDUP("selftest: created %s\n", utun_if);
	if (!mac_utun_config(utun_if)) { close(utun_fd); return false; }

	snprintf(rules, sizeof(rules),
		"pass out route-to (%s %s) inet proto udp from any to %s port %d user { >root } no state\n",
		utun_if, mac_utun_peer(), ip_s, port);
	if (!mac_pf_load_rules(rules)) { close(utun_fd); return false; }

	uid = (uid_t)atoi(env_or("SUDO_UID", "65534"));
	DLOG_CONDUP("selftest: sending dns query to %s:%d as uid %u (traffic must go through us)\n", ip_s, port, uid);

	pid = fork();
	if (pid == 0)
	{
		// ребёнок: не root, иначе pf-правило его не поймает
		static const uint8_t q[] = {
			0x5A, 0xA5, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
			7,'e','x','a','m','p','l','e', 3,'c','o','m', 0, 0x00, 0x01, 0x00, 0x01
		};
		uint8_t reply[512];
		struct sockaddr_in to;
		struct timeval tv = { 2, 0 };
		int c, i;

		if (setgid((gid_t)uid) || setuid(uid)) _exit(3);
		memset(&to, 0, sizeof(to));
		to.sin_family = AF_INET;
		to.sin_len = sizeof(to);
		to.sin_port = htons((uint16_t)port);
		to.sin_addr = dst;
		if ((c = socket(AF_INET, SOCK_DGRAM, 0)) == -1) _exit(4);
		setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		if (connect(c, (struct sockaddr*)&to, sizeof(to))) _exit(5);
		for (i = 0; i < 3; i++)
		{
			if (send(c, q, sizeof(q), 0) < 0) _exit(6);
			if (recv(c, reply, sizeof(reply), 0) >= 12 && reply[0]==0x5A && reply[1]==0xA5) _exit(0);
		}
		_exit(1);
	}
	if (pid == -1) { DLOG_PERROR("selftest: fork"); mac_pf_flush(); close(utun_fd); return false; }

	fcntl(utun_fd, F_SETFL, fcntl(utun_fd, F_GETFL, 0) | O_NONBLOCK);
	wire_q = wire_a = 0;
	for (deadline = time(NULL) + 8; time(NULL) < deadline; )
	{
		uint8_t buf[16384];
		ssize_t rd = read(utun_fd, buf, sizeof(buf));
		int st;

		bpf_count_dns(&dst, &wire_q, &wire_a);
		if (rd > 4 && !mac_packet_routable(buf + 4, (size_t)rd - 4))
		{
			// служебный трафик самого utun (NDP/MLD) — пропускаем
			continue;
		}
		if (rd > 4)
		{
			bool csum_was_ok, sent;
			packets++;
			csum_was_ok = mac_fix_csum(buf + 4, (size_t)rd - 4);
			sent = mac_inject(buf + 4, (size_t)rd - 4);
			last_src = ((struct ip*)(buf + 4))->ip_src;
			if (packets <= 3)
			{
				struct ip *ip = (struct ip*)(buf + 4);
				size_t hl = (size_t)ip->ip_hl << 2;
				uint16_t sp = 0, dp = 0;
				char src[INET_ADDRSTRLEN], dstr[INET_ADDRSTRLEN];
				if ((size_t)rd - 4 >= hl + 4)
				{
					sp = ntohs(*(uint16_t*)((uint8_t*)ip + hl));
					dp = ntohs(*(uint16_t*)((uint8_t*)ip + hl + 2));
				}
				inet_ntop(AF_INET, &ip->ip_src, src, sizeof(src));
				inet_ntop(AF_INET, &ip->ip_dst, dstr, sizeof(dstr));
				if (packets == 1)
				{
					DLOG_CONDUP("selftest: got packet from %s -> pf route-to works\n", utun_if);
					mac_check_source(buf + 4, (size_t)rd - 4, uplink);
				}
				DLOG_CONDUP("selftest: pkt %d: proto %u %s:%u -> %s:%u len %zu, kernel csum %s, injected %s\n",
					packets, ip->ip_p, src, sp, dstr, dp, (size_t)rd - 4,
					csum_was_ok ? "valid" : "INVALID", sent ? "OK" : "FAILED");
			}
		}
		else
			usleep(20000);
		if (child_rc == -1 && waitpid(pid, &st, WNOHANG) == pid)
		{
			child_rc = WIFEXITED(st) ? WEXITSTATUS(st) : 99;
			if (packets) break;
		}
	}
	if (child_rc == -1)
	{
		int st;
		kill(pid, SIGKILL);
		waitpid(pid, &st, 0);
		child_rc = 98;
	}

	bpf_count_dns(&dst, &wire_q, &wire_a);
	DLOG_CONDUP("selftest: packets from utun: %d, dns answer through us: %s (code %d)\n",
		packets, child_rc==0 ? "OK" : "FAILED", child_rc);
	if (bpf_fd != -1)
		DLOG_CONDUP("selftest: on the wire: %d query(ies) to the resolver, %d answer(s) back\n", wire_q, wire_a);
	if (!packets)
		DLOG_CONDUP("selftest: nothing arrived from utun -> pf route-to does not divert traffic\n");
	else if (child_rc && !mac_iface_has_addr4(uplink, last_src))
		DLOG_CONDUP("selftest: diverted traffic does not belong to %s (see the warning above):\n"
			    "          disable the VPN and run the check again\n", uplink);
	else if (child_rc)
	{
		if (wire_a > 0)
			DLOG_CONDUP("selftest: the answer DID come back on the wire but was not delivered to the app:\n"
				    "          the packet leaves fine, something drops the reply (pf state / firewall)\n");
		else if (wire_q > 0)
			DLOG_CONDUP("selftest: our packet left the interface but got no answer:\n"
				    "          %s:%d may be unreachable, or the packet is malformed on the wire\n", ip_s, port);
		else
			DLOG_CONDUP("selftest: diverted packets never reached the interface -> injection is broken\n");
	}
	ok = packets > 0 && child_rc == 0;
	mac_pf_flush();
	close(utun_fd);
	return ok;
}

int mac_selftest(void)
{
	char uplink[IFNAMSIZ] = "", uplink6[IFNAMSIZ] = "";
	bool a, b, a6 = false, b6 = false, v6 = false;

	if (geteuid()) { DLOG_CONDUP("selftest: must run as root\n"); return 2; }
	if (!mac_uplink_detect(uplink, sizeof(uplink)))
	{
		DLOG_CONDUP("selftest: cannot detect uplink interface (set MACWS_UPLINK)\n");
		return 2;
	}
	DLOG_CONDUP("selftest: uplink interface %s\n", uplink);
	if (!mac_pf_enabled())
		DLOG_CONDUP("selftest: WARNING ! pf is disabled. enable it first: pfctl -E\n");
	if (!mac_inject_init(uplink)) return 2;

	DLOG_CONDUP("--- 1/2 packet injection (ipv4) ---\n");
	a = selftest_inject(uplink);
	DLOG_CONDUP("--- 2/2 utun + pf route-to (ipv4) ---\n");
	b = selftest_divert(uplink);

	// ipv6 — отдельно и необязательно
	if (mac_ipv6_available() && mac_uplink_detect6(uplink6, sizeof(uplink6)))
	{
		v6 = true;
		DLOG_CONDUP("\n--- ipv6: uplink %s ---\n", uplink6);
		if (strcmp(uplink6, uplink))
			DLOG_CONDUP("selftest6: WARNING ! ipv6 leaves through %s, but injection is bound to %s.\n"
				    "           set MACWS_UPLINK=%s or turn ipv6 diversion off (IPV6=0)\n",
				    uplink6, uplink, uplink6);
		a6 = selftest_inject6(uplink6);
		b6 = a6 && selftest_divert6(uplink6);
	}
	else
		DLOG_CONDUP("\n--- ipv6: no route to the ipv6 internet, skipping ---\n");

	DLOG_CONDUP("\nresult: ipv4 injection %s (%s), divert %s\n", a?"OK":"FAIL", mac_inject_method(), b?"OK":"FAIL");
	if (v6) DLOG_CONDUP("result: ipv6 injection %s, divert %s\n", a6?"OK":"FAIL", b6?"OK":"FAIL");
	// строка для zapret.sh
	DLOG_CONDUP("SELFTEST_RESULT v4=%s v6=%s inject=%s\n",
		(a && b) ? "ok" : "fail",
		v6 ? ((a6 && b6) ? "ok" : "fail") : "none",
		(inject_mode_is_bpf() ? "bpf" : "raw"));
	mac_inject_cleanup();
	return (a && b) ? 0 : 1;
}

#endif // __APPLE__
