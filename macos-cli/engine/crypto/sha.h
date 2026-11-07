/**************************** sha.h ****************************/
/***************** See RFC 6234 for details. *******************/
/*
   Copyright (c) 2011 IETF Trust and the persons identified as
   authors of the code.  All rights reserved.
   Redistribution and use in source and binary forms, with or
   without modification, are permitted provided that the following
   conditions are met:
   - Redistributions of source code must retain the above
     copyright notice, this list of conditions and
     the following disclaimer.
   - Redistributions in binary form must reproduce the above
     copyright notice, this list of conditions and the following
     disclaimer in the documentation and/or other materials provided
     with the distribution.
   - Neither the name of Internet Society, IETF or IETF Trust, nor
     the names of specific contributors, may be used to endorse or
     promote products derived from this software without specific
     prior written permission.
   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
   CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
   INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
   DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
   NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
   LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
   HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
   CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
   OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
   EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#pragma once

/*
 *  Description:
 *      This file implements the Secure Hash Algorithms
 *      as defined in the U.S. National Institute of Standards
 *      and Technology Federal Information Processing Standards
 *      Publication (FIPS PUB) 180-3 published in October 2008
 *      and formerly defined in its predecessors, FIPS PUB 180-1
 *      and FIP PUB 180-2.
 *
 *      A combined document showing all algorithms is available at
 *              http://csrc.nist.gov/publications/fips/
 *                     fips180-3/fips180-3_final.pdf
 *
 *      The five hashes are defined in these sizes:
 *              SHA-1           20 byte / 160 bit
 *              SHA-224         28 byte / 224 bit
 *              SHA-256         32 byte / 256 bit
 *              SHA-384         48 byte / 384 bit
 *              SHA-512         64 byte / 512 bit
 *
 *  Compilation Note:
 *    These files may be compiled with two options:
 *        USE_32BIT_ONLY - use 32-bit arithmetic only, for systems
 *                         without 64-bit integers
 *
 *        USE_MODIFIED_MACROS - use alternate form of the SHA_Ch()
 *                         and SHA_Maj() macros that are equivalent
 *                         and potentially faster on many systems
 *
 */

#include <stdint.h>
#include <stddef.h>

/*
 * If you do not have the ISO standard stdint.h header file, then you
 * must typedef the following:
 *    name              meaning
 *  uint64_t         unsigned 64-bit integer
 *  uint32_t         unsigned 32-bit integer
 *  uint8_t          unsigned 8-bit integer (i.e., unsigned char)
 *  int_least16_t    integer of >= 16 bits
 *
 * See stdint-example.h
 */

#ifndef _SHA_enum_
#define _SHA_enum_
/*
 *  All SHA functions return one of these values.
 */
enum {
    shaSuccess = 0,
    shaNull,            /* Null pointer parameter */
    shaInputTooLong,    /* input data too long */
    shaStateError,      /* called Input after FinalBits or Result */
    shaBadParam         /* passed a bad parameter */
};
#endif /* _SHA_enum_ */

/*
 *  These constants hold size information for each of the SHA
 *  hashing operations
 */
enum {
    SHA1_Message_Block_Size = 64, SHA224_Message_Block_Size = 64,
    SHA256_Message_Block_Size = 64,
    USHA_Max_Message_Block_Size = SHA256_Message_Block_Size,

    SHA1HashSize = 20, SHA224HashSize = 28, SHA256HashSize = 32,
    USHAMaxHashSize = SHA256HashSize,

    SHA1HashSizeBits = 160, SHA224HashSizeBits = 224,
    SHA256HashSizeBits = 256, USHAMaxHashSizeBits = SHA256HashSizeBits
};

/*
 *  These constants are used in the USHA (Unified SHA) functions.
 */
typedef enum SHAversion {
    SHA224, SHA256
} SHAversion;

/*
 *  This structure will hold context information for the SHA-256
 *  hashing operation.
 */
typedef struct SHA256Context {
    uint32_t Intermediate_Hash[SHA256HashSize/4]; /* Message Digest */

    uint32_t Length_High;               /* Message length in bits */
    uint32_t Length_Low;                /* Message length in bits */

    int_least16_t Message_Block_Index;  /* Message_Block array index */
                                        /* 512-bit message blocks */
    uint8_t Message_Block[SHA256_Message_Block_Size];

    int Computed;                   /* Is the hash computed? */
    int Corrupted;                  /* Cumulative corruption code */
} SHA256Context;

/*
 *  This structure will hold context information for the SHA-224
 *  hashing operation.  It uses the SHA-256 structure for computation.
 */
typedef struct SHA256Context SHA224Context;

/*
 *  This structure holds context information for all SHA
 *  hashing operations.
 */
typedef struct USHAContext {
    int whichSha;               /* which SHA is being used */
    union {
      SHA224Context sha224Context; SHA256Context sha256Context;
    } ctx;

} USHAContext;

/*
 *  This structure will hold context information for the HMAC
 *  keyed-hashing operation.
 */
typedef struct HMACContext {
    int whichSha;               /* which SHA is being used */
    int hashSize;               /* hash size of SHA being used */
    int blockSize;              /* block size of SHA being used */
    USHAContext shaContext;     /* SHA context */
    unsigned char k_opad[USHA_Max_Message_Block_Size];
                        /* outer padding - key XORd with opad */
    int Computed;               /* Is the MAC computed? */
    int Corrupted;              /* Cumulative corruption code */

} HMACContext;

/*
 *  This structure will hold context information for the HKDF
 *  extract-and-expand Key Derivation Functions.
 */
typedef struct HKDFContext {
    int whichSha;               /* which SHA is being used */
    HMACContext hmacContext;
    int hashSize;               /* hash size of SHA being used */
    unsigned char prk[USHAMaxHashSize];
                        /* pseudo-random key - output of hkdfInput */
    int Computed;               /* Is the key material computed? */
    int Corrupted;              /* Cumulative corruption code */
} HKDFContext;

/*
 *  Function Prototypes
 */


/* SHA-224 */
int SHA224Reset(SHA224Context *);
int SHA224Input(SHA224Context *, const uint8_t *bytes,
                       unsigned int bytecount);
int SHA224FinalBits(SHA224Context *, uint8_t bits,
                           unsigned int bit_count);
int SHA224Result(SHA224Context *,
                        uint8_t Message_Digest[SHA224HashSize]);

/* SHA-256 */
int SHA256Reset(SHA256Context *);
int SHA256Input(SHA256Context *, const uint8_t *bytes,
                       unsigned int bytecount);
int SHA256FinalBits(SHA256Context *, uint8_t bits,
                           unsigned int bit_count);
int SHA256Result(SHA256Context *,
                        uint8_t Message_Digest[SHA256HashSize]);

/* Unified SHA functions, chosen by whichSha */
int USHAReset(USHAContext *context, SHAversion whichSha);
int USHAInput(USHAContext *context,
                     const uint8_t *bytes, unsigned int bytecount);
int USHAFinalBits(USHAContext *context,
                         uint8_t bits, unsigned int bit_count);
int USHAResult(USHAContext *context,
                      uint8_t Message_Digest[USHAMaxHashSize]);
int USHABlockSize(enum SHAversion whichSha);
int USHAHashSize(enum SHAversion whichSha);

/*
 * HMAC Keyed-Hashing for Message Authentication, RFC 2104,
 * for all SHAs.
 * This interface allows a fixed-length text input to be used.
 */
int hmac(SHAversion whichSha, /* which SHA algorithm to use */
    const unsigned char *text,     /* pointer to data stream */
    size_t text_len,                  /* length of data stream */
    const unsigned char *key,      /* pointer to authentication key */
    size_t key_len,                   /* length of authentication key */
    uint8_t digest[USHAMaxHashSize]); /* caller digest to fill in */

/*
 * HMAC Keyed-Hashing for Message Authentication, RFC 2104,
 * for all SHAs.
 * This interface allows any length of text input to be used.
 */
int hmacReset(HMACContext *context, enum SHAversion whichSha,
                     const unsigned char *key, size_t key_len);
int hmacInput(HMACContext *context, const unsigned char *text,
                     size_t text_len);
int hmacFinalBits(HMACContext *context, uint8_t bits,
                         unsigned int bit_count);
int hmacResult(HMACContext *context,
                      uint8_t digest[USHAMaxHashSize]);


/*
 * HKDF HMAC-based Extract-and-Expand Key Derivation Function,
 * RFC 5869, for all SHAs.
 */
int hkdf(SHAversion whichSha,
    const unsigned char *salt, size_t salt_len,
    const unsigned char *ikm, size_t ikm_len,
    const unsigned char *info, size_t info_len,
    uint8_t okm[ ], size_t okm_len);

int hkdfExtract(SHAversion whichSha, const unsigned char *salt,
                       size_t salt_len, const unsigned char *ikm,
                       size_t ikm_len, uint8_t prk[USHAMaxHashSize]);
int hkdfExpand(SHAversion whichSha, const uint8_t prk[ ],
                      size_t prk_len, const unsigned char *info,
                      size_t info_len, uint8_t okm[ ], size_t okm_len);

/*
 * HKDF HMAC-based Extract-and-Expand Key Derivation Function,
 * RFC 5869, for all SHAs.
 * This interface allows any length of text input to be used.
 */
int hkdfReset(HKDFContext *context, enum SHAversion whichSha,
                     const unsigned char *salt, size_t salt_len);
int hkdfInput(HKDFContext *context, const unsigned char *ikm,
                     size_t ikm_len);
int hkdfFinalBits(HKDFContext *context, uint8_t ikm_bits,
                         unsigned int ikm_bit_count);
int hkdfResult(HKDFContext *context,
                      uint8_t prk[USHAMaxHashSize],
                      const unsigned char *info, size_t info_len,
                      uint8_t okm[USHAMaxHashSize], size_t okm_len);
