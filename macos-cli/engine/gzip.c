#include "gzip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ZCHUNK 16384
#define BUFMIN 128
#define BUFCHUNK (1024*128)

int z_readfile(FILE *F, char **buf, size_t *size)
{
	z_stream zs;
	int r;
	unsigned char in[ZCHUNK];
	size_t bufsize;
	void *newbuf;

	memset(&zs, 0, sizeof(zs));

	*buf = NULL;
	bufsize = *size = 0;

	r = inflateInit2(&zs, 47);
	if (r != Z_OK)  return r;

	do
	{
		zs.avail_in = fread(in, 1, sizeof(in), F);
		if (ferror(F))
		{
			r = Z_ERRNO;
			goto zerr;
		}
		if (!zs.avail_in) break;
		zs.next_in = in;
		do
		{
			if ((bufsize - *size) < BUFMIN)
			{
				bufsize += BUFCHUNK;
				newbuf = *buf ? realloc(*buf, bufsize) : malloc(bufsize);
				if (!newbuf)
				{
					r = Z_MEM_ERROR;
					goto zerr;
				}
				*buf = newbuf;
			}
			zs.avail_out = bufsize - *size;
			zs.next_out = (unsigned char*)(*buf + *size);
			r = inflate(&zs, Z_NO_FLUSH);
			if (r != Z_OK && r != Z_STREAM_END) goto zerr;
			*size = bufsize - zs.avail_out;
		} while (r == Z_OK && zs.avail_in);
	} while (r == Z_OK);

	if (*size < bufsize)
	{
		// free extra space
		if ((newbuf = realloc(*buf, *size))) *buf = newbuf;
	}

	inflateEnd(&zs);
	return Z_OK;

zerr:
	inflateEnd(&zs);
	free(*buf);
	*buf = NULL;
	return r;
}

bool is_gzip(FILE* F)
{
	unsigned char magic[2];
	bool b = !fseek(F, 0, SEEK_SET) && fread(magic, 1, 2, F) == 2 && magic[0] == 0x1F && magic[1] == 0x8B;
	fseek(F, 0, SEEK_SET);
	return b;
}
