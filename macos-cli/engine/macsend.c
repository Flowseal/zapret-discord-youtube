#ifdef __APPLE__

#include "macsend.h"
#include "checksum.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/bpf.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/ip.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int bpf_fd = -1;
static uint8_t source_mac[ETHER_ADDR_LEN];
static uint8_t gateway4_mac[ETHER_ADDR_LEN];
static uint8_t gateway6_mac[ETHER_ADDR_LEN];

static bool parse_mac(const char *text, uint8_t mac[ETHER_ADDR_LEN])
{
	unsigned int value[ETHER_ADDR_LEN];
	if (!text || sscanf(text, "%x:%x:%x:%x:%x:%x", &value[0], &value[1], &value[2],
		&value[3], &value[4], &value[5]) != ETHER_ADDR_LEN)
		return false;
	for (size_t i = 0; i < ETHER_ADDR_LEN; i++)
	{
		if (value[i] > 255) return false;
		mac[i] = (uint8_t)value[i];
	}
	return true;
}

static bool get_interface_mac(const char *ifname, uint8_t mac[ETHER_ADDR_LEN])
{
	struct ifaddrs *all = NULL;
	bool found = false;
	if (getifaddrs(&all) < 0) return false;
	for (struct ifaddrs *item = all; item; item = item->ifa_next)
	{
		if (!item->ifa_addr || item->ifa_addr->sa_family != AF_LINK || strcmp(item->ifa_name, ifname))
			continue;
		struct sockaddr_dl *link = (struct sockaddr_dl *)item->ifa_addr;
		if (link->sdl_alen != ETHER_ADDR_LEN) continue;
		memcpy(mac, LLADDR(link), ETHER_ADDR_LEN);
		found = true;
		break;
	}
	freeifaddrs(all);
	return found;
}

bool macsend_preinit(void)
{
	const char *ifname = getenv("ZAPRET_IFACE");
	const char *gateway = getenv("ZAPRET_GATEWAY_MAC");
	const char *gateway6 = getenv("ZAPRET_GATEWAY6_MAC");
	char path[32];
	struct ifreq request;
	int datalink = 0;
	unsigned int complete_header = 1;

	if (!ifname || !*ifname)
	{
		errno = EINVAL;
		return false;
	}
	if (!parse_mac(gateway, gateway4_mac))
	{
		errno = EINVAL;
		return false;
	}
	if (!parse_mac(gateway6, gateway6_mac))
		memcpy(gateway6_mac, gateway4_mac, ETHER_ADDR_LEN);
	if (!get_interface_mac(ifname, source_mac))
	{
		errno = ENODEV;
		return false;
	}

	for (unsigned int i = 0; i < 256; i++)
	{
		snprintf(path, sizeof(path), "/dev/bpf%u", i);
		bpf_fd = open(path, O_RDWR);
		if (bpf_fd >= 0) break;
		if (errno != EBUSY) return false;
	}
	if (bpf_fd < 0) return false;

	memset(&request, 0, sizeof(request));
	strlcpy(request.ifr_name, ifname, sizeof(request.ifr_name));
	if (ioctl(bpf_fd, BIOCSETIF, &request) < 0 ||
		ioctl(bpf_fd, BIOCGDLT, &datalink) < 0 || datalink != DLT_EN10MB ||
		ioctl(bpf_fd, BIOCSHDRCMPLT, &complete_header) < 0)
	{
		macsend_cleanup();
		if (datalink != 0 && datalink != DLT_EN10MB) errno = EPROTONOSUPPORT;
		return false;
	}
	return true;
}

void macsend_cleanup(void)
{
	if (bpf_fd >= 0) close(bpf_fd);
	bpf_fd = -1;
}

bool macsend_packet(sa_family_t family, const void *packet, size_t length)
{
	if (bpf_fd < 0 || !packet || !length || length > 65535)
	{
		errno = EINVAL;
		return false;
	}
	uint8_t frame[ETHER_HDR_LEN + 65535];
	struct ether_header *ethernet = (struct ether_header *)frame;
	memcpy(ethernet->ether_dhost, family == AF_INET6 ? gateway6_mac : gateway4_mac, ETHER_ADDR_LEN);
	memcpy(ethernet->ether_shost, source_mac, ETHER_ADDR_LEN);
	if (family == AF_INET)
		ethernet->ether_type = htons(ETHERTYPE_IP);
	else if (family == AF_INET6)
		ethernet->ether_type = htons(ETHERTYPE_IPV6);
	else
	{
		errno = EAFNOSUPPORT;
		return false;
	}
	memcpy(frame + ETHER_HDR_LEN, packet, length);
	if (family == AF_INET)
	{
		struct ip *ip = (struct ip *)(frame + ETHER_HDR_LEN);
		ip4_fix_checksum(ip);
	}
	size_t frame_length = ETHER_HDR_LEN + length;
	return write(bpf_fd, frame, frame_length) == (ssize_t)frame_length;
}

#endif
