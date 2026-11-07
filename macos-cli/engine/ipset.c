#include <stdio.h>
#include "ipset.h"
#include "gzip.h"
#include "helpers.h"


// inplace tolower() and add to pool
static bool addpool(ipset *ips, char **s, const char *end, int *ct)
{
	char *p, cidr[128];
	size_t l;
	struct cidr4 c4;
	struct cidr6 c6;

	// advance until eol
	for (p=*s; p<end && *p && *p!='\r' && *p != '\n'; p++);

	// comment line
	if (!(**s == '#' || **s == ';' || **s == '/' || **s == '\r' || **s == '\n' ))
	{
		l = p-*s;
		if (l>=sizeof(cidr)) l=sizeof(cidr)-1;
		memcpy(cidr,*s,l);
		cidr[l]=0;
		rtrim(cidr);

		if (parse_cidr4(cidr,&c4))
		{
			if (!ipset4AddCidr(&ips->ips4, &c4))
			{
				ipsetDestroy(ips);
				return false;
			}
			if (ct) (*ct)++;
		}
		else if (parse_cidr6(cidr,&c6))
		{
			if (!ipset6AddCidr(&ips->ips6, &c6))
			{
				ipsetDestroy(ips);
				return false;
			}
			if (ct) (*ct)++;
		}
		else
			DLOG_ERR("bad ip or subnet : %s\n",cidr);
	}

	// advance to the next line
	for (; p<end && (!*p || *p=='\r' || *p=='\n') ; p++);
	*s = p;
	return true;

}

bool AppendIpsetItem(ipset *ips, char *ip)
{
	return addpool(ips,&ip,ip+strlen(ip),NULL);
}

static bool AppendIpset(ipset *ips, const char *filename)
{
	char *p, *e, s[256], *zbuf;
	size_t zsize;
	int ct = 0;
	FILE *F;
	int r;

	DLOG_CONDUP("Loading ipset %s\n",filename);

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
				if (!addpool(ips,&p,e,&ct))
				{
					DLOG_ERR("Not enough memory to store ipset : %s\n", filename);
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

		while (fgets(s, sizeof(s)-1, F))
		{
			p = s;
			if (!addpool(ips,&p,p+strlen(p),&ct))
			{
				DLOG_ERR("Not enough memory to store ipset : %s\n", filename);
				fclose(F);
				return false;
			}
		}
		fclose(F);
	}

	DLOG_CONDUP("Loaded %d ip/subnets from %s\n", ct, filename);
	return true;
}

static bool LoadIpset(struct ipset_file *hfile)
{
	if (hfile->filename)
	{
		file_mod_sig fsig;
		if (!file_mod_signature(hfile->filename, &fsig))
		{
			// stat() error
			DLOG_PERROR("file_mod_signature");
			DLOG_ERR("cannot access ipset file '%s'. in-memory content remains unchanged.\n",hfile->filename);
			return true;
		}
		if (FILE_MOD_COMPARE(&hfile->mod_sig,&fsig)) return true; // up to date
		ipsetDestroy(&hfile->ipset);
		if (!AppendIpset(&hfile->ipset, hfile->filename))
		{
			ipsetDestroy(&hfile->ipset);
			return false;
		}
		hfile->mod_sig=fsig;
	}
	return true;
}
static bool LoadIpsets(struct ipset_files_head *list)
{
	bool bres=true;
	struct ipset_file *hfile;

	LIST_FOREACH(hfile, list, next)
	{
		if (!LoadIpset(hfile))
			// at least one failed
			bres=false;
	}
	return bres;
}

bool LoadAllIpsets()
{
	return LoadIpsets(&params.ipsets);
}

static bool SearchIpset(const ipset *ips, const struct in_addr *ipv4, const struct in6_addr *ipv6)
{
	char s_ip[40];
	bool bInSet=false;

	if (!!ipv4 != !!ipv6)
	{
		*s_ip=0;
		if (ipv4)
		{
			if (params.debug) inet_ntop(AF_INET, ipv4, s_ip, sizeof(s_ip));
			if (ips->ips4) bInSet = ipset4Check(ips->ips4, ipv4, 32);
		}
		if (ipv6)
		{
			if (params.debug) inet_ntop(AF_INET6, ipv6, s_ip, sizeof(s_ip));
			if (ips->ips6) bInSet = ipset6Check(ips->ips6, ipv6, 128);
		}
		DLOG("ipset check for %s : %s\n", s_ip, bInSet ? "positive" : "negative");
	}
	else
		// ipv4 and ipv6 are both empty or non-empty
		DLOG("ipset check error !!!!!!!! ipv4=%p ipv6=%p\n",ipv4,ipv6);
	return bInSet;
}

static bool IpsetsReloadCheck(const struct ipset_collection_head *ipsets)
{
	struct ipset_item *item;
	LIST_FOREACH(item, ipsets, next)
	{
		if (!LoadIpset(item->hfile))
			return false;
	}
	return true;
}
bool IpsetsReloadCheckForProfile(const struct desync_profile *dp)
{
	return IpsetsReloadCheck(&dp->ips_collection) && IpsetsReloadCheck(&dp->ips_collection_exclude);
}

static bool IpsetCheck_(const struct ipset_collection_head *ips, const struct ipset_collection_head *ips_exclude, const struct in_addr *ipv4, const struct in6_addr *ipv6)
{
	struct ipset_item *item;

	if (!IpsetsReloadCheck(ips) || !IpsetsReloadCheck(ips_exclude))
		return false;

	LIST_FOREACH(item, ips_exclude, next)
	{
		DLOG("[%s] exclude ",item->hfile->filename ? item->hfile->filename : "fixed");
		if (SearchIpset(&item->hfile->ipset, ipv4, ipv6))
			return false;
	}
	// old behavior compat: all include lists are empty means check passes
	if (!ipset_collection_is_empty(ips))
	{
		LIST_FOREACH(item, ips, next)
		{
			DLOG("[%s] include ",item->hfile->filename ? item->hfile->filename : "fixed");
			if (SearchIpset(&item->hfile->ipset, ipv4, ipv6))
				return true;
		}
		return false;
	}
	return true;
}

bool IpsetCheck(const struct desync_profile *dp, const struct in_addr *ipv4, const struct in6_addr *ipv6)
{
	if (PROFILE_IPSETS_ABSENT(dp)) return true;
	DLOG("* ipset check for profile %d\n",dp->n);
	return IpsetCheck_(&dp->ips_collection,&dp->ips_collection_exclude,ipv4,ipv6);
}


static struct ipset_file *RegisterIpset_(struct ipset_files_head *ipsets, struct ipset_collection_head *ips_collection, const char *filename)
{
	struct ipset_file *hfile;
	if (filename)
	{
		if (!(hfile=ipset_files_search(ipsets, filename)))
			if (!(hfile=ipset_files_add(ipsets, filename)))
				return NULL;
		if (!ipset_collection_search(ips_collection, filename))
			if (!ipset_collection_add(ips_collection, hfile))
				return NULL;
	}
	else
	{
		if (!(hfile=ipset_files_add(ipsets, NULL)))
			return NULL;
		if (!ipset_collection_add(ips_collection, hfile))
			return NULL;
	}
	return hfile;
}
struct ipset_file *RegisterIpset(struct desync_profile *dp, bool bExclude, const char *filename)
{
	if (filename && !file_mod_time(filename))
	{
		DLOG_ERR("cannot access ipset file '%s'\n",filename);
		return NULL;
	}
	return RegisterIpset_(
		&params.ipsets,
		bExclude ? &dp->ips_collection_exclude : &dp->ips_collection,
		filename);
}

static const char *dbg_ipset_fill(const ipset *ips)
{
	if (ips->ips4)
		if (ips->ips6)
			return "ipv4+ipv6";
		else
			return "ipv4";
	else
		if (ips->ips6)
			return "ipv6";
		else
			return "empty";
}
void IpsetsDebug()
{
	if (!params.debug) return;

	struct ipset_file *hfile;
	struct desync_profile_list *dpl;
	struct ipset_item *ips_item;

	LIST_FOREACH(hfile, &params.ipsets, next)
	{
		if (hfile->filename)
			DLOG("ipset file %s (%s)\n",hfile->filename,dbg_ipset_fill(&hfile->ipset));
		else
			DLOG("ipset fixed (%s)\n",dbg_ipset_fill(&hfile->ipset));
	}

	LIST_FOREACH(dpl, &params.desync_profiles, next)
	{
		LIST_FOREACH(ips_item, &dpl->dp.ips_collection, next)
			if (ips_item->hfile->filename)
				DLOG("profile %d include ipset %s (%s)\n",dpl->dp.n,ips_item->hfile->filename,dbg_ipset_fill(&ips_item->hfile->ipset));
			else
				DLOG("profile %d include fixed ipset (%s)\n",dpl->dp.n,dbg_ipset_fill(&ips_item->hfile->ipset));
		LIST_FOREACH(ips_item, &dpl->dp.ips_collection_exclude, next)
			if (ips_item->hfile->filename)
				DLOG("profile %d exclude ipset %s (%s)\n",dpl->dp.n,ips_item->hfile->filename,dbg_ipset_fill(&ips_item->hfile->ipset));
			else
				DLOG("profile %d exclude fixed ipset (%s)\n",dpl->dp.n,dbg_ipset_fill(&ips_item->hfile->ipset));
	}
}
