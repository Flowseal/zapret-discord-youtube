/************************ sha-private.h ************************/
/***************** See RFC 6234 for details. *******************/
#pragma once
/*
 * These definitions are defined in FIPS 180-3, section 4.1.
 * Ch() and Maj() are defined identically in sections 4.1.1,
 * 4.1.2, and 4.1.3.
 *
 * The definitions used in FIPS 180-3 are as follows:
 */

#ifndef USE_MODIFIED_MACROS
#define SHA_Ch(x,y,z)        (((x) & (y)) ^ ((~(x)) & (z)))
#define SHA_Maj(x,y,z)       (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#else /* USE_MODIFIED_MACROS */
/*
 * The following definitions are equivalent and potentially faster.
 */

#define SHA_Ch(x, y, z)      (((x) & ((y) ^ (z))) ^ (z))
#define SHA_Maj(x, y, z)     (((x) & ((y) | (z))) | ((y) & (z)))

#endif /* USE_MODIFIED_MACROS */

#define SHA_Parity(x, y, z)  ((x) ^ (y) ^ (z))
