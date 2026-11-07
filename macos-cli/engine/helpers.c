#define _GNU_SOURCE

#include "helpers.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <ctype.h>
#include <sys/stat.h>
#include <libgen.h>
#include <fcntl.h>

int unique_size_t(size_t *pu, int ct)
{
	size_t i, j, u;
	for (i = j = 0; j < ct; i++)
	{
		u = pu[j++];
		for (; j < ct && pu[j] == u; j++);
		pu[i] = u;
	}
	return i;
}
static int cmp_size_t(const void * a, const void * b)
{
	return *(size_t*)a < *(size_t*)b ? -1 : *(size_t*)a > *(size_t*)b;
}
void qsort_size_t(size_t *array,size_t ct)
{
	qsort(array,ct,sizeof(*array),cmp_size_t);
}


void rtrim(char *s)
{
	if (s)
		for (char *p = s + strlen(s) - 1; p >= s && (*p == '\n' || *p == '\r'); p--) *p = '\0';
}

void replace_char(char *s, char from, char to)
{
	for(;*s;s++) if (*s==from) *s=to;
}

char *strncasestr(const char *s, const char *find, size_t slen)
{
	char c, sc;
	size_t len;

	if ((c = *find++) != '\0')
	{
		len = strlen(find);
		do
		{
			do
			{
				if (slen-- < 1 || (sc = *s++) == '\0') return NULL;
			} while (toupper(c) != toupper(sc));
			if (len > slen)	return NULL;
		} while (strncasecmp(s, find, len) != 0);
		s--;
	}
	return (char *)s;
}


bool load_file(const char *filename, void *buffer, size_t *buffer_size)
{
	FILE *F;

	F = fopen(filename, "rb");
	if (!F) return false;

	*buffer_size = fread(buffer, 1, *buffer_size, F);
	if (ferror(F))
	{
		fclose(F);
		return false;
	}

	fclose(F);
	return true;
}
bool load_file_nonempty(const char *filename, void *buffer, size_t *buffer_size)
{
	bool b = load_file(filename, buffer, buffer_size);
	return b && *buffer_size;
}
bool save_file(const char *filename, const void *buffer, size_t buffer_size)
{
	FILE *F;

	F = fopen(filename, "wb");
	if (!F) return false;

	fwrite(buffer, 1, buffer_size, F);
	if (ferror(F))
	{
		fclose(F);
		return false;
	}

	fclose(F);
	return true;
}
bool append_to_list_file(const char *filename, const char *s)
{
	FILE *F = fopen(filename,"at");
	if (!F) return false;
	bool bOK = fprintf(F,"%s\n",s)>0;
	fclose(F);
	return bOK;
}

void expand_bits(void *target, const void *source, unsigned int source_bitlen, unsigned int target_bytelen)
{
	unsigned int target_bitlen = target_bytelen<<3;
	unsigned int bitlen = target_bitlen<source_bitlen ? target_bitlen : source_bitlen;
	unsigned int bytelen = bitlen>>3;

	if ((target_bytelen-bytelen)>=1) memset(target+bytelen,0,target_bytelen-bytelen);
	memcpy(target,source,bytelen);
	if ((bitlen &= 7)) ((uint8_t*)target)[bytelen] = ((uint8_t*)source)[bytelen] & (~((1 << (8-bitlen)) - 1));
}

// "       [fd00::1]" => "fd00::1"
// "[fd00::1]:8000" => "fd00::1"
// "127.0.0.1" => "127.0.0.1"
// " 127.0.0.1:8000" => "127.0.0.1"
// " vk.com:8000" => "vk.com"
// return value:  true - host is ip addr
bool strip_host_to_ip(char *host)
{
	size_t l;
	char *h,*p;
	uint8_t addr[16];

	for (h = host ; *h==' ' || *h=='\t' ; h++);
	l = strlen(h);
	if (l>=2)
	{
		if (*h=='[')
		{
			// ipv6 ?
			for (p=++h ; *p && *p!=']' ;  p++);
			if (*p==']')
			{
				l = p-h;
				memmove(host,h,l);
				host[l]=0;
				return inet_pton(AF_INET6, host, addr)>0;
			}
		}
		else
		{
			if (inet_pton(AF_INET6, h, addr)>0)
			{
				// ipv6 ?
				if (host!=h)
				{
					l = strlen(h);
					memmove(host,h,l);
					host[l]=0;
				}
				return true;
			}
			else
			{
				// ipv4 ?
				for (p=h ; *p && *p!=':' ;  p++);
				l = p-h;
				if (host!=h) memmove(host,h,l);
				host[l]=0;
				return inet_pton(AF_INET, host, addr)>0;
			}
		}
	}
	return false;
}

void ntop46(const struct sockaddr *sa, char *str, size_t len)
{
	if (!len) return;
	*str = 0;
	switch (sa->sa_family)
	{
	case AF_INET:
		inet_ntop(sa->sa_family, &((struct sockaddr_in*)sa)->sin_addr, str, len);
		break;
	case AF_INET6:
		inet_ntop(sa->sa_family, &((struct sockaddr_in6*)sa)->sin6_addr, str, len);
		break;
	default:
		snprintf(str, len, "UNKNOWN_FAMILY_%d", sa->sa_family);
	}
}
void ntop46_port(const struct sockaddr *sa, char *str, size_t len)
{
	char ip[40];
	ntop46(sa, ip, sizeof(ip));
	switch (sa->sa_family)
	{
	case AF_INET:
		snprintf(str, len, "%s:%u", ip, ntohs(((struct sockaddr_in*)sa)->sin_port));
		break;
	case AF_INET6:
		snprintf(str, len, "[%s]:%u", ip, ntohs(((struct sockaddr_in6*)sa)->sin6_port));
		break;
	default:
		snprintf(str, len, "%s", ip);
	}
}
void print_sockaddr(const struct sockaddr *sa)
{
	char ip_port[48];

	ntop46_port(sa, ip_port, sizeof(ip_port));
	printf("%s", ip_port);
}

bool pton4_port(const char *s, struct sockaddr_in *sa)
{
	char ip[16];
	const char *p;
	size_t l;
	unsigned int u;

	p = strchr(s,':');
	if (!p) return false;
	l = p-s;
	if (l<7 || l>15) return false;
	memcpy(ip,s,l);
	ip[l]=0;
	p++;

	sa->sin_family = AF_INET;
	if (inet_pton(AF_INET,ip,&sa->sin_addr)!=1 || sscanf(p,"%u",&u)!=1 || !u || u>0xFFFF) return false;
	sa->sin_port = htons((uint16_t)u);

	return true;
}
bool pton6_port(const char *s, struct sockaddr_in6 *sa)
{
	char ip[40];
	const char *p;
	size_t l;
	unsigned int u;

	if (*s++!='[') return false;
	p = strchr(s,']');
	if (!p || p[1]!=':') return false;
	l = p-s;
	if (l<2 || l>39) return false;
	p+=2;
	memcpy(ip,s,l);
	ip[l]=0;

	sa->sin6_family = AF_INET6;
	if (inet_pton(AF_INET6,ip,&sa->sin6_addr)!=1 || sscanf(p,"%u",&u)!=1 || !u || u>0xFFFF) return false;
	sa->sin6_port = htons((uint16_t)u);
	sa->sin6_flowinfo = 0;
	sa->sin6_scope_id = 0;

	return true;
}

uint16_t saport(const struct sockaddr *sa)
{
	return htons(sa->sa_family==AF_INET ? ((struct sockaddr_in*)sa)->sin_port :
		     sa->sa_family==AF_INET6 ? ((struct sockaddr_in6*)sa)->sin6_port : 0);
}


uint64_t pntoh64(const void *p)
{
	return (uint64_t)*((const uint8_t *)(p)+0) << 56 |
		(uint64_t)*((const uint8_t *)(p)+1) << 48 |
		(uint64_t)*((const uint8_t *)(p)+2) << 40 |
		(uint64_t)*((const uint8_t *)(p)+3) << 32 |
		(uint64_t)*((const uint8_t *)(p)+4) << 24 |
		(uint64_t)*((const uint8_t *)(p)+5) << 16 |
		(uint64_t)*((const uint8_t *)(p)+6) << 8 |
		(uint64_t)*((const uint8_t *)(p)+7) << 0;
}
void phton64(uint8_t *p, uint64_t v)
{
	p[0] = (uint8_t)(v >> 56);
	p[1] = (uint8_t)(v >> 48);
	p[2] = (uint8_t)(v >> 40);
	p[3] = (uint8_t)(v >> 32);
	p[4] = (uint8_t)(v >> 24);
	p[5] = (uint8_t)(v >> 16);
	p[6] = (uint8_t)(v >> 8);
	p[7] = (uint8_t)(v >> 0);
}

bool seq_within(uint32_t s, uint32_t s1, uint32_t s2)
{
	return (s2>=s1 && s>=s1 && s<=s2) || (s2<s1 && (s<=s2 || s>=s1));
}

bool ipv6_addr_is_zero(const struct in6_addr *a)
{
    return !memcmp(a,"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",16);
}


#define INVALID_HEX_DIGIT ((uint8_t)-1)
static inline uint8_t parse_hex_digit(char c)
{
	return (c>='0' && c<='9') ? c-'0' : (c>='a' && c<='f') ? c-'a'+0xA : (c>='A' && c<='F') ? c-'A'+0xA : INVALID_HEX_DIGIT;
}
static inline bool parse_hex_byte(const char *s, uint8_t *pbyte)
{
	uint8_t u,l;
	u = parse_hex_digit(s[0]);
	l = parse_hex_digit(s[1]);
	if (u==INVALID_HEX_DIGIT || l==INVALID_HEX_DIGIT)
	{
		*pbyte=0;
		return false;
	}
	else
	{
		*pbyte=(u<<4) | l;
		return true;
	}
}
bool parse_hex_str(const char *s, uint8_t *pbuf, size_t *size)
{
	uint8_t *pe = pbuf+*size;
	*size=0;
	while(pbuf<pe && *s)
	{
		if (!parse_hex_byte(s,pbuf))
			return false;
		pbuf++; s+=2; (*size)++;
	}
	return true;
}

void fill_pattern(uint8_t *buf,size_t bufsize,const void *pattern,size_t patsize,size_t offset)
{
	size_t size;

	if (offset%=patsize)
	{
		size = patsize-offset;
		size = bufsize>size ? size : bufsize;
		memcpy(buf,pattern+offset,size);
		buf += size;
		bufsize -= size;
	}
	while (bufsize)
	{
		size = bufsize>patsize ? patsize : bufsize;
		memcpy(buf,pattern,size);
		buf += size;
		bufsize -= size;
	}
}

int fprint_localtime(FILE *F)
{
	struct tm t;
	time_t now;

	time(&now);
	localtime_r(&now,&t);
	return fprintf(F, "%02d.%02d.%04d %02d:%02d:%02d", t.tm_mday, t.tm_mon + 1, t.tm_year + 1900, t.tm_hour, t.tm_min, t.tm_sec);
}

time_t file_mod_time(const char *filename)
{
	struct stat st;
	return stat(filename,&st)==-1 ? 0 : st.st_mtime;
}
bool file_mod_signature(const char *filename, file_mod_sig *ms)
{
	struct stat st;
	if (stat(filename,&st)==-1)
	{
		FILE_MOD_RESET(ms);
		return false;
	}
	ms->mod_time=st.st_mtime;
	ms->size=st.st_size;
	return true;
}

bool file_open_test(const char *filename, int flags)
{
	int fd = open(filename,flags);
	if (fd>=0)
	{
		close(fd);
		return true;
	}
	return false;
}

bool pf_in_range(uint16_t port, const port_filter *pf)
{
	return port && (((!pf->from && !pf->to) || (port>=pf->from && port<=pf->to)) ^ pf->neg);
}
bool pf_parse(const char *s, port_filter *pf)
{
	unsigned int v1,v2;
	char c;

	if (!s) return false;
	if (*s=='*' && s[1]==0)
	{
		pf->from=1; pf->to=0xFFFF;
		return true;
	}
	if (*s=='~')
	{
		pf->neg=true;
		s++;
	}
	else
		pf->neg=false;
	if (sscanf(s,"%u-%u%c",&v1,&v2,&c)==2)
	{
		if (v1>65535 || v2>65535 || v1>v2) return false;
		pf->from=(uint16_t)v1;
		pf->to=(uint16_t)v2;
	}
	else if (sscanf(s,"%u%c",&v1,&c)==1)
	{
		if (v1>65535) return false;
		pf->to=pf->from=(uint16_t)v1;
	}
	else
		return false;
	// deny all case
	if (!pf->from && !pf->to) pf->neg=true;
	return true;
}
bool pf_is_empty(const port_filter *pf)
{
	return !pf->neg && !pf->from && !pf->to;
}

void fill_random_bytes(uint8_t *p,size_t sz)
{
	size_t k,sz16 = sz>>1;
	for(k=0;k<sz16;k++) ((uint16_t*)p)[k]=(uint16_t)random();
	if (sz & 1) p[sz-1]=(uint8_t)random();
}
void fill_random_az(uint8_t *p,size_t sz)
{
	size_t k;
	for(k=0;k<sz;k++) p[k] = 'a'+(random() % ('z'-'a'));
}
void fill_random_az09(uint8_t *p,size_t sz)
{
	size_t k;
	uint8_t rnd;
	for(k=0;k<sz;k++)
	{
		rnd = random() % (10 + 'z'-'a'+1);
		p[k] = rnd<10 ? rnd+'0' : 'a'+rnd-10;
	}
}

void set_console_io_buffering(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	setvbuf(stderr, NULL, _IOLBF, 0);
}

bool set_env_exedir(const char *argv0)
{
	char *s,*d;
	bool bOK=false;
	if ((s = strdup(argv0)))
	{
		if ((d = dirname(s)))
			bOK = !setenv("EXEDIR",d,1);
		free(s);
	}
	return bOK;
}


void str_cidr4(char *s, size_t s_len, const struct cidr4 *cidr)
{
	char s_ip[16];
	*s_ip=0;
	inet_ntop(AF_INET, &cidr->addr, s_ip, sizeof(s_ip));
	snprintf(s,s_len,cidr->preflen<32 ? "%s/%u" : "%s", s_ip, cidr->preflen);
}
void print_cidr4(const struct cidr4 *cidr)
{
	char s[19];
	str_cidr4(s,sizeof(s),cidr);
	printf("%s",s);
}
void str_cidr6(char *s, size_t s_len, const struct cidr6 *cidr)
{
	char s_ip[40];
	*s_ip=0;
	inet_ntop(AF_INET6, &cidr->addr, s_ip, sizeof(s_ip));
	snprintf(s,s_len,cidr->preflen<128 ? "%s/%u" : "%s", s_ip, cidr->preflen);
}
void print_cidr6(const struct cidr6 *cidr)
{
	char s[44];
	str_cidr6(s,sizeof(s),cidr);
	printf("%s",s);
}
bool parse_cidr4(char *s, struct cidr4 *cidr)
{
	char *p,d;
	bool b;
	unsigned int plen;

	if ((p = strchr(s, '/')))
	{
		if (sscanf(p + 1, "%u", &plen)!=1 || plen>32)
			return false;
		cidr->preflen = (uint8_t)plen;
		d=*p; *p=0; // backup char
	}
	else
		cidr->preflen = 32;
	b = (inet_pton(AF_INET, s, &cidr->addr)==1);
	if (p) *p=d; // restore char
	return b;
}
bool parse_cidr6(char *s, struct cidr6 *cidr)
{
	char *p,d;
	bool b;
	unsigned int plen;

	if ((p = strchr(s, '/')))
	{
		if (sscanf(p + 1, "%u", &plen)!=1 || plen>128)
			return false;
		cidr->preflen = (uint8_t)plen;
		d=*p; *p=0; // backup char
	}
	else
		cidr->preflen = 128;
	b = (inet_pton(AF_INET6, s, &cidr->addr)==1);
	if (p) *p=d; // restore char
	return b;
}
