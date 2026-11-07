#pragma once

#include <stdbool.h>

#ifdef __linux__
#define HAS_FILTER_SSID 1
#endif

#ifdef __CYGWIN__
extern bool bQuit;
#endif
int main(int argc, char *argv[]);
