#pragma once

#ifdef __APPLE__
int macos_utun_open(char *ifname, unsigned long ifname_size);
#endif
