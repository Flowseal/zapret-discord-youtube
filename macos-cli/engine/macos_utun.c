#ifdef __APPLE__

#include "macos_utun.h"

#include <errno.h>
#include <net/if_utun.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <unistd.h>

int macos_utun_open(char *ifname, unsigned long ifname_size)
{
	const char *unit_text = getenv("ZAPRET_UTUN_UNIT");
	unsigned long unit = unit_text && *unit_text ? strtoul(unit_text, NULL, 10) : 51;
	if (unit < 1 || unit > 1024)
	{
		errno = EINVAL;
		return -1;
	}

	int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
	if (fd < 0) return -1;
	struct ctl_info info;
	memset(&info, 0, sizeof(info));
	strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
	if (ioctl(fd, CTLIOCGINFO, &info) < 0)
	{
		close(fd);
		return -1;
	}

	struct sockaddr_ctl addr;
	memset(&addr, 0, sizeof(addr));
	addr.sc_len = sizeof(addr);
	addr.sc_family = AF_SYSTEM;
	addr.ss_sysaddr = AF_SYS_CONTROL;
	addr.sc_id = info.ctl_id;
	addr.sc_unit = (uint32_t)unit;
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
	{
		close(fd);
		return -1;
	}

	socklen_t len = (socklen_t)ifname_size;
	if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ifname, &len) < 0)
	{
		close(fd);
		return -1;
	}
	return fd;
}

#endif
