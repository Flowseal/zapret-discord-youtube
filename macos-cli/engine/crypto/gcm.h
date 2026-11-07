/******************************************************************************
*
* THIS SOURCE CODE IS HEREBY PLACED INTO THE PUBLIC DOMAIN FOR THE GOOD OF ALL
*
* This is a simple and straightforward implementation of AES-GCM authenticated
* encryption. The focus of this work was correctness & accuracy. It is written
* in straight 'C' without any particular focus upon optimization or speed. It
* should be endian (memory byte order) neutral since the few places that care
* are handled explicitly.
*
* This implementation of AES-GCM was created by Steven M. Gibson of GRC.com.
*
* It is intended for general purpose use, but was written in support of GRC's
* reference implementation of the SQRL (Secure Quick Reliable Login) client.
*
* See:    http://csrc.nist.gov/publications/nistpubs/800-38D/SP-800-38D.pdf
*         http://csrc.nist.gov/groups/ST/toolkit/BCM/documents/proposedmodes/ \
*         gcm/gcm-revised-spec.pdf
*
* NO COPYRIGHT IS CLAIMED IN THIS WORK, HOWEVER, NEITHER IS ANY WARRANTY MADE
* REGARDING ITS FITNESS FOR ANY PARTICULAR PURPOSE. USE IT AT YOUR OWN RISK.
*
*******************************************************************************/
#pragma once

#define GCM_AUTH_FAILURE    0x55555555  // authentication failure

#include "aes.h"                        // gcm_context includes aes_context

#if defined(_MSC_VER)
#include <basetsd.h>
typedef UINT32 uint32_t;
typedef UINT64 uint64_t;
#else
#include <stdint.h>
#endif


/******************************************************************************
 *  GCM_CONTEXT : GCM context / holds keytables, instance data, and AES ctx
 ******************************************************************************/
typedef struct {
	int mode;               // cipher direction: encrypt/decrypt
	uint64_t len;           // cipher data length processed so far
	uint64_t add_len;       // total add data length
	uint64_t HL[16];        // precalculated lo-half HTable
	uint64_t HH[16];        // precalculated hi-half HTable
	uchar base_ectr[16];    // first counter-mode cipher output for tag
	uchar y[16];            // the current cipher-input IV|Counter value
	uchar buf[16];          // buf working value
	aes_context aes_ctx;    // cipher context used
} gcm_context;


/******************************************************************************
 *  GCM_CONTEXT : MUST be called once before ANY use of this library
 ******************************************************************************/
int gcm_initialize(void);


/******************************************************************************
 *  GCM_SETKEY : sets the GCM (and AES) keying material for use
 ******************************************************************************/
int gcm_setkey(gcm_context *ctx,   // caller-provided context ptr
	const uchar *key,   // pointer to cipher key
	const uint keysize  // size in bytes (must be 16, 24, 32 for
				// 128, 192 or 256-bit keys respectively)
); // returns 0 for success


/******************************************************************************
 *
 *  GCM_CRYPT_AND_TAG
 *
 *  This either encrypts or decrypts the user-provided data and, either
 *  way, generates an authentication tag of the requested length. It must be
 *  called with a GCM context whose key has already been set with GCM_SETKEY.
 *
 *  The user would typically call this explicitly to ENCRYPT a buffer of data
 *  and optional associated data, and produce its an authentication tag.
 *
 *  To reverse the process the user would typically call the companion
 *  GCM_AUTH_DECRYPT function to decrypt data and verify a user-provided
 *  authentication tag.  The GCM_AUTH_DECRYPT function calls this function
 *  to perform its decryption and tag generation, which it then compares.
 *
 ******************************************************************************/
int gcm_crypt_and_tag(
	gcm_context *ctx,       // gcm context with key already setup
	int mode,               // cipher direction: ENCRYPT (1) or DECRYPT (0)
	const uchar *iv,        // pointer to the 12-byte initialization vector
	size_t iv_len,          // byte length if the IV. should always be 12
	const uchar *add,       // pointer to the non-ciphered additional data
	size_t add_len,         // byte length of the additional AEAD data
	const uchar *input,     // pointer to the cipher data source
	uchar *output,          // pointer to the cipher data destination
	size_t length,          // byte length of the cipher data
	uchar *tag,             // pointer to the tag to be generated
	size_t tag_len);       // byte length of the tag to be generated


/******************************************************************************
 *
 *  GCM_AUTH_DECRYPT
 *
 *  This DECRYPTS a user-provided data buffer with optional associated data.
 *  It then verifies a user-supplied authentication tag against the tag just
 *  re-created during decryption to verify that the data has not been altered.
 *
 *  This function calls GCM_CRYPT_AND_TAG (above) to perform the decryption
 *  and authentication tag generation.
 *
 ******************************************************************************/
int gcm_auth_decrypt(
	gcm_context *ctx,       // gcm context with key already setup
	const uchar *iv,        // pointer to the 12-byte initialization vector
	size_t iv_len,          // byte length if the IV. should always be 12
	const uchar *add,       // pointer to the non-ciphered additional data
	size_t add_len,         // byte length of the additional AEAD data
	const uchar *input,     // pointer to the cipher data source
	uchar *output,          // pointer to the cipher data destination
	size_t length,          // byte length of the cipher data
	const uchar *tag,       // pointer to the tag to be authenticated
	size_t tag_len);       // byte length of the tag <= 16


/******************************************************************************
 *
 *  GCM_START
 *
 *  Given a user-provided GCM context, this initializes it, sets the encryption
 *  mode, and preprocesses the initialization vector and additional AEAD data.
 *
 ******************************************************************************/
int gcm_start(gcm_context *ctx,    // pointer to user-provided GCM context
	int mode,            // ENCRYPT (1) or DECRYPT (0)
	const uchar *iv,     // pointer to initialization vector
	size_t iv_len,       // IV length in bytes (should == 12)
	const uchar *add,    // pointer to additional AEAD data (NULL if none)
	size_t add_len);    // length of additional AEAD data (bytes)


/******************************************************************************
 *
 *  GCM_UPDATE
 *
 *  This is called once or more to process bulk plaintext or ciphertext data.
 *  We give this some number of bytes of input and it returns the same number
 *  of output bytes. If called multiple times (which is fine) all but the final
 *  invocation MUST be called with length mod 16 == 0. (Only the final call can
 *  have a partial block length of < 128 bits.)
 *
 ******************************************************************************/
int gcm_update(gcm_context *ctx,       // pointer to user-provided GCM context
	size_t length,          // length, in bytes, of data to process
	const uchar *input,     // pointer to source data
	uchar *output);        // pointer to destination data


/******************************************************************************
 *
 *  GCM_FINISH
 *
 *  This is called once after all calls to GCM_UPDATE to finalize the GCM.
 *  It performs the final GHASH to produce the resulting authentication TAG.
 *
 ******************************************************************************/
int gcm_finish(gcm_context *ctx,   // pointer to user-provided GCM context
	uchar *tag,         // ptr to tag buffer - NULL if tag_len = 0
	size_t tag_len);   // length, in bytes, of the tag-receiving buf


/******************************************************************************
 *
 *  GCM_ZERO_CTX
 *
 *  The GCM context contains both the GCM context and the AES context.
 *  This includes keying and key-related material which is security-
 *  sensitive, so it MUST be zeroed after use. This function does that.
 *
 ******************************************************************************/
void gcm_zero_ctx(gcm_context *ctx);
