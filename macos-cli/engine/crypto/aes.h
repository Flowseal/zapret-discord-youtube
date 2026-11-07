/******************************************************************************
*
* THIS SOURCE CODE IS HEREBY PLACED INTO THE PUBLIC DOMAIN FOR THE GOOD OF ALL
*
* This is a simple and straightforward implementation of the AES Rijndael
* 128-bit block cipher designed by Vincent Rijmen and Joan Daemen. The focus
* of this work was correctness & accuracy.  It is written in 'C' without any
* particular focus upon optimization or speed. It should be endian (memory
* byte order) neutral since the few places that care are handled explicitly.
*
* This implementation of Rijndael was created by Steven M. Gibson of GRC.com.
*
* It is intended for general purpose use, but was written in support of GRC's
* reference implementation of the SQRL (Secure Quick Reliable Login) client.
*
* See:    http://csrc.nist.gov/archive/aes/rijndael/wsdindex.html
*
* NO COPYRIGHT IS CLAIMED IN THIS WORK, HOWEVER, NEITHER IS ANY WARRANTY MADE
* REGARDING ITS FITNESS FOR ANY PARTICULAR PURPOSE. USE IT AT YOUR OWN RISK.
*
*******************************************************************************/

#pragma once

/******************************************************************************/
#define AES_DECRYPTION  0       // whether AES decryption is supported
/******************************************************************************/

#include <string.h>

#define AES_ENCRYPT         1       // specify whether we're encrypting
#define AES_DECRYPT         0       // or decrypting

#if defined(_MSC_VER)
#include <basetsd.h>
typedef UINT32 uint32_t;
#else
#include <inttypes.h>
#endif

typedef unsigned char uchar;    // add some convienent shorter types
typedef unsigned int uint;


/******************************************************************************
 *  AES_INIT_KEYGEN_TABLES : MUST be called once before any AES use
 ******************************************************************************/
void aes_init_keygen_tables(void);


/******************************************************************************
 *  AES_CONTEXT : cipher context / holds inter-call data
 ******************************************************************************/
typedef struct {
	int mode;           // 1 for Encryption, 0 for Decryption
	int rounds;         // keysize-based rounds count
	uint32_t *rk;       // pointer to current round key
	uint32_t buf[68];   // key expansion buffer
} aes_context;


/******************************************************************************
 *  AES_SETKEY : called to expand the key for encryption or decryption
 ******************************************************************************/
int aes_setkey(aes_context *ctx,       // pointer to context
	int mode,               // 1 or 0 for Encrypt/Decrypt
	const uchar *key,       // AES input key
	uint keysize);         // size in bytes (must be 16, 24, 32 for
					// 128, 192 or 256-bit keys respectively)
							// returns 0 for success

/******************************************************************************
 *  AES_CIPHER : called to encrypt or decrypt ONE 128-bit block of data
 ******************************************************************************/
int aes_cipher(aes_context *ctx,       // pointer to context
	const uchar input[16],  // 128-bit block to en/decipher
	uchar output[16]);     // 128-bit output result block
							// returns 0 for success
