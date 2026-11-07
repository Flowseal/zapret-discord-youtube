#include <stdio.h>
#include "hostlist.h"
#include "gzip.h"
#include "helpers.h"

// inplace tolower() and add to pool
static bool addpool(hostlist_pool **hostlist, char **s, const char *end, int *ct)
{
	char *p=*s;

	// comment line
	if ( *p == '#' || *p == ';' || *p == '/' || *p == '\r' || *p == '\n')
	{
		// advance until eol
		for (; p<end && *p && *p!='\r' && *p != '\n'; p++);
	}
	else
	{
		// advance until eol lowering all chars
		uint32_t flags = 0;
		if (*p=='^')
		{
			p = ++(*s);
			flags |= HOSTLIST_POOL_FLAG_STRICT_MATCH;
		}
		for (; p<end && *p && *p!='\r' && *p != '\n'; p++) *p=tolower(*p);
		if (!HostlistPoolAddStrLen(hostlist, *s, p-*s, flags))
		{
			HostlistPoolDestroy(hostlist);
			*hostlist = NULL;
			return false;
		}
		if (ct) (*ct)++;
	}
	// advance to the next line
	for (; p<end && (!*p || *p=='\r' || *p=='\n') ; p++);
	*s = p;
	return true;
}

bool AppendHostlistItem(hostlist_pool **hostlist, char *s)
{
	return addpool(hostlist,&s,s+strlen(s),NULL);
}

bool AppendHostList(hostlist_pool **hostlist, const char *filename)
{
	char *p, *e, s[256], *zbuf;
	size_t zsize;
	int ct = 0;
	FILE *F;
	int r;

	DLOG_CONDUP("Loading hostlist %s\n",filename);

	if (!(F = fopen(filename, "rb")))
	{
		DLOG_ERR("Could not open %s\n", filename);
		return false;
	}

	if (is_gzip(F))
	{
		r = z_readfile(F,&zbuf,&zsize);
		fclose(F);
		if (r==Z_OK)
		{
			DLOG_CONDUP("zlib compression detected. uncompressed size : %zu\n", zsize);

			p = zbuf;
			e = zbuf + zsize;
			while(p<e)
			{
				if (!addpool(hostlist,&p,e,&ct))
				{
					DLOG_ERR("Not enough memory to store host list : %s\n", filename);
					free(zbuf);
					return false;
				}
			}
			free(zbuf);
		}
		else
		{
			DLOG_ERR("zlib decompression failed : result %d\n",r);
			return false;
		}
	}
	else
	{
		DLOG_CONDUP("loading plain text list\n");

		while (fgets(s, sizeof(s), F))
		{
			p = s;
			if (!addpool(hostlist,&p,p+strlen(p),&ct))
			{
				DLOG_ERR("Not enough memory to store host list : %s\n", filename);
				fclose(F);
				return false;
			}
		}
		fclose(F);
	}

	DLOG_CONDUP("Loaded %d hosts from %s\n", ct, filename);
	return true;
}

static bool LoadHostList(struct hostlist_file *hfile)
{
	if (hfile->filename)
	{
		file_mod_sig fsig;
		if (!file_mod_signature(hfile->filename, &fsig))
		{
			// stat() error
			DLOG_PERROR("file_mod_signature");
			DLOG_ERR("cannot access hostlist file '%s'. in-memory content remains unchanged.\n",hfile->filename);
			return true;
		}
		if (FILE_MOD_COMPARE(&hfile->mod_sig,&fsig)) return true; // up to date
		HostlistPoolDestroy(&hfile->hostlist);
		if (!AppendHostList(&hfile->hostlist, hfile->filename))
		{
			HostlistPoolDestroy(&hfile->hostlist);
			return false;
		}
		hfile->mod_sig=fsig;
	}
	return true;
}
static bool LoadHostLists(struct hostlist_files_head *list)
{
	bool bres=true;
	struct hostlist_file *hfile;

	LIST_FOREACH(hfile, list, next)
	{
		if (!LoadHostList(hfile))
			// at least one failed
			bres=false;
	}
	return bres;
}

bool NonEmptyHostlist(hostlist_pool **hostlist)
{
	// add impossible hostname if the list is empty
	return *hostlist ? true : HostlistPoolAddStrLen(hostlist, "@&()", 4, 0);
}

static void MakeAutolistsNonEmpty()
{
	struct desync_profile_list *dpl;
	LIST_FOREACH(dpl, &params.desync_profiles, next)
	{
		if (dpl->dp.hostlist_auto)
			NonEmptyHostlist(&dpl->dp.hostlist_auto->hostlist);
	}
}

bool LoadAllHostLists()
{
	if (!LoadHostLists(&params.hostlists))
		return false;
	MakeAutolistsNonEmpty();
	return true;
}



static bool SearchHostList(hostlist_pool *hostlist, const char *host, bool no_match_subdomains)
{
	if (hostlist)
	{
		const char *p = host;
		const struct hostlist_pool *hp;
		bool bHostFull=true;
		while (p)
		{
			DLOG("hostlist check for %s : ", p);
			hp = HostlistPoolGetStr(hostlist, p);
			if (hp)
			{
				if ((hp->flags & HOSTLIST_POOL_FLAG_STRICT_MATCH) && !bHostFull)
				{
					DLOG("negative : strict_mismatch : %s != %s\n", p, host);
				}
				else
				{
					DLOG("positive\n");
					return true;
				}
			}
			else
				DLOG("negative\n");
			if (no_match_subdomains) break;
			p = strchr(p, '.');
			if (p) p++;
			bHostFull = false;
		}
	}
	return false;
}


static bool HostlistsReloadCheck(const struct hostlist_collection_head *hostlists)
{
	struct hostlist_item *item;
	LIST_FOREACH(item, hostlists, next)
	{
		if (!LoadHostList(item->hfile))
			return false;
	}
	MakeAutolistsNonEmpty();
	return true;
}
bool HostlistsReloadCheckForProfile(const struct desync_profile *dp)
{
	return HostlistsReloadCheck(&dp->hl_collection) && HostlistsReloadCheck(&dp->hl_collection_exclude);
}
// return : true = apply fooling, false = do not apply
static bool HostlistCheck_(const struct hostlist_collection_head *hostlists, const struct hostlist_collection_head *hostlists_exclude, const char *host, bool no_match_subdomains, bool *excluded, bool bSkipReloadCheck)
{
	struct hostlist_item *item;

	if (excluded) *excluded = false;

	if (!bSkipReloadCheck)
		if (!HostlistsReloadCheck(hostlists) || !HostlistsReloadCheck(hostlists_exclude))
			return false;

	LIST_FOREACH(item, hostlists_exclude, next)
	{
		DLOG("[%s] exclude ", item->hfile->filename ? item->hfile->filename : "fixed");
		if (SearchHostList(item->hfile->hostlist, host, no_match_subdomains))
		{
			if (excluded) *excluded = true;
			return false;
		}
	}
	// old behavior compat: all include lists are empty means check passes
	if (!hostlist_collection_is_empty(hostlists))
	{
		LIST_FOREACH(item, hostlists, next)
		{
			DLOG("[%s] include ", item->hfile->filename ? item->hfile->filename : "fixed");
			if (SearchHostList(item->hfile->hostlist, host, no_match_subdomains))
				return true;
		}
		return false;
	}
	return true;
}


// return : true = apply fooling, false = do not apply
bool HostlistCheck(const struct desync_profile *dp, const char *host, bool no_match_subdomains, bool *excluded, bool bSkipReloadCheck)
{
	DLOG("* hostlist check for profile %d\n",dp->n);
	return HostlistCheck_(&dp->hl_collection, &dp->hl_collection_exclude, host, no_match_subdomains, excluded, bSkipReloadCheck);
}


static struct hostlist_file *RegisterHostlist_(struct hostlist_files_head *hostlists, struct hostlist_collection_head *hl_collection, const char *filename)
{
	struct hostlist_file *hfile;

	if (filename)
	{
		if (!(hfile=hostlist_files_search(hostlists, filename)))
			if (!(hfile=hostlist_files_add(hostlists, filename)))
				return NULL;
		if (!hostlist_collection_search(hl_collection, filename))
			if (!hostlist_collection_add(hl_collection, hfile))
				return NULL;
	}
	else
	{
		if (!(hfile=hostlist_files_add(hostlists, NULL)))
			return NULL;
		if (!hostlist_collection_add(hl_collection, hfile))
			return NULL;
	}

	return hfile;
}
struct hostlist_file *RegisterHostlist(struct desync_profile *dp, bool bExclude, const char *filename)
{
/*
	if (filename && !file_mod_time(filename))
	{
		DLOG_ERR("cannot access hostlist file '%s'\n",filename);
		return NULL;
	}
*/
	return RegisterHostlist_(
		&params.hostlists,
		bExclude ? &dp->hl_collection_exclude : &dp->hl_collection,
		filename);
}

void HostlistsDebug()
{
	if (!params.debug) return;

	struct hostlist_file *hfile;
	struct desync_profile_list *dpl;
	struct hostlist_item *hl_item;

	LIST_FOREACH(hfile, &params.hostlists, next)
	{
		if (hfile->filename)
			DLOG("hostlist file %s%s\n",hfile->filename,hfile->hostlist ? "" : " (empty)");
		else
			DLOG("hostlist fixed%s\n",hfile->hostlist ? "" : " (empty)");
	}

	LIST_FOREACH(dpl, &params.desync_profiles, next)
	{
		LIST_FOREACH(hl_item, &dpl->dp.hl_collection, next)
			if (hl_item->hfile!=dpl->dp.hostlist_auto)
			{
				if (hl_item->hfile->filename)
					DLOG("profile %d include hostlist %s%s\n",dpl->dp.n, hl_item->hfile->filename,hl_item->hfile->hostlist ? "" : " (empty)");
				else
					DLOG("profile %d include fixed hostlist%s\n",dpl->dp.n, hl_item->hfile->hostlist ? "" : " (empty)");
			}
		LIST_FOREACH(hl_item, &dpl->dp.hl_collection_exclude, next)
		{
			if (hl_item->hfile->filename)
				DLOG("profile %d exclude hostlist %s%s\n",dpl->dp.n,hl_item->hfile->filename,hl_item->hfile->hostlist ? "" : " (empty)");
			else
				DLOG("profile %d exclude fixed hostlist%s\n",dpl->dp.n,hl_item->hfile->hostlist ? "" : " (empty)");
		}
		if (dpl->dp.hostlist_auto)
			DLOG("profile %d auto hostlist %s%s\n",dpl->dp.n,dpl->dp.hostlist_auto->filename,dpl->dp.hostlist_auto->hostlist ? "" : " (empty)");
	}
}
