#pragma once

#include <stdio.h>
#include <zlib.h>
#include <stdbool.h>

int z_readfile(FILE *F,char **buf,size_t *size);
bool is_gzip(FILE* F);
