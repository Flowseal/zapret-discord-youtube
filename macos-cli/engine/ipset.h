#pragma once

#include <stdbool.h>
#include <arpa/inet.h>
#include "params.h"
#include "pools.h"

bool LoadAllIpsets();
bool IpsetCheck(const struct desync_profile *dp, const struct in_addr *ipv4, const struct in6_addr *ipv6);
struct ipset_file *RegisterIpset(struct desync_profile *dp, bool bExclude, const char *filename);
void IpsetsDebug();
bool AppendIpsetItem(ipset *ips, char *ip);

#define ResetAllIpsetModTime() ipset_files_reset_modtime(&params.ipsets)
