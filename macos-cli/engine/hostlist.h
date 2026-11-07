#pragma once

#include <stdbool.h>
#include "pools.h"
#include "params.h"

bool AppendHostlistItem(hostlist_pool **hostlist, char *s);
bool AppendHostList(hostlist_pool **hostlist, const char *filename);
bool LoadAllHostLists();
bool NonEmptyHostlist(hostlist_pool **hostlist);
// return : true = apply fooling, false = do not apply
bool HostlistCheck(const struct desync_profile *dp,const char *host, bool no_match_subdomains, bool *excluded, bool bSkipReloadCheck);
struct hostlist_file *RegisterHostlist(struct desync_profile *dp, bool bExclude, const char *filename);
bool HostlistsReloadCheckForProfile(const struct desync_profile *dp);
void HostlistsDebug();

#define ResetAllHostlistsModTime() hostlist_files_reset_modtime(&params.hostlists)
