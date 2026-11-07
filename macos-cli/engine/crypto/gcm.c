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
*         http://csrc.nist.gov/groups/ST/toolkit/BCM/documents/proposedmodes/
*         gcm/gcm-revised-spec.pdf
*
* NO COPYRIGHT IS CLAIMED IN THIS WORK, HOWEVER, NEITHER IS ANY WARRANTY MADE
* REGARDING ITS FITNESS FOR ANY PARTICULAR PURPOSE. USE IT AT YOUR OWN RISK.
*
*******************************************************************************/

#include "gcm.h"
#include "aes.h"

/******************************************************************************
 *                      ==== IMPLEMENTATION WARNING ====
 *
 *  This code was developed for use within SQRL's fixed environmnent. Thus, it
 *  is somewhat less "general purpose" than it would be if it were designed as
 *  a general purpose AES-GCM library. Specifically, it bothers with almost NO
 *  error checking on parameter limits, buffer bounds, etc. It assumes that it
 *  is being invoked by its author or by someone who understands the values it
 *  expects to receive. Its behavior will be undefined otherwise.
 *
 *  All functions that might fail are defined to return 'ints' to indicate a
 *  problem. Most do not do so now. But this allows for error propagation out
 *  of internal functions if robust error checking should ever be desired.
 *
 ******************************************************************************/

 /* Calculating the "GHASH"
  *
  * There are many ways of calculating the so-called GHASH in software, each with
  * a traditional size vs performance tradeoff.  The GHASH (Galois field hash) is
  * an intriguing construction which takes two 128-bit strings (also the cipher's
  * block size and the fundamental operation size for the system) and hashes them
  * into a third 128-bit result.
  *
  * Many implementation solutions have been worked out that use large precomputed
  * table lookups in place of more time consuming bit fiddling, and this approach
  * can be scaled easily upward or downward as needed to change the time/space
  * tradeoff. It's been studied extensively and there's a solid body of theory and
  * practice.  For example, without using any lookup tables an implementation
  * might obtain 119 cycles per byte throughput, whereas using a simple, though
  * large, key-specific 64 kbyte 8-bit lookup table the performance jumps to 13
  * cycles per byte.
  *
  * And Intel's processors have, since 2010, included an instruction which does
  * the entire 128x128->128 bit job in just several 64x64->128 bit pieces.
  *
  * Since SQRL is interactive, and only processing a few 128-bit blocks, I've
  * settled upon a relatively slower but appealing small-table compromise which
  * folds a bunch of not only time consuming but also bit twiddling into a simple
  * 16-entry table which is attributed to Victor Shoup's 1996 work while at
  * Bellcore: "On Fast and Provably Secure MessageAuthentication Based on
  * Universal Hashing."  See: http://www.shoup.net/papers/macs.pdf
  * See, also section 4.1 of the "gcm-revised-spec" cited above.
  */

  /*
   *  This 16-entry table of pre-computed constants is used by the
   *  GHASH multiplier to improve over a strictly table-free but
   *  significantly slower 128x128 bit multiple within GF(2^128).
   */
static const uint64_t last4[16] = {
	0x0000, 0x1c20, 0x3840, 0x2460, 0x7080, 0x6ca0, 0x48c0, 0x54e0,
	0xe100, 0xfd20, 0xd940, 0xc560, 0x9180, 0x8da0, 0xa9c0, 0xb5e0 };

/*
 * Platform Endianness Neutralizing Load and Store Macro definitions
 * GCM wants platform-neutral Big Endian (BE) byte ordering
 */
#define GET_UINT32_BE(n,b,i) {                      \
    (n) = ( (uint32_t) (b)[(i)    ] << 24 )         \
        | ( (uint32_t) (b)[(i) + 1] << 16 )         \
        | ( (uint32_t) (b)[(i) + 2] <<  8 )         \
        | ( (uint32_t) (b)[(i) + 3]       ); }

#define PUT_UINT32_BE(n,b,i) {                      \
    (b)[(i)    ] = (uchar) ( (n) >> 24 );   \
    (b)[(i) + 1] = (uchar) ( (n) >> 16 );   \
    (b)[(i) + 2] = (uchar) ( (n) >>  8 );   \
    (b)[(i) + 3] = (uchar) ( (n)       ); }


 /******************************************************************************
  *
  *  GCM_INITIALIZE
  *
  *  Must be called once to initialize the GCM library.
  *
  *  At present, this only calls the AES keygen table generator, which expands
  *  the AES keying tables for use. This is NOT A THREAD-SAFE function, so it
  *  MUST be called during system initialization before a multi-threading
  *  environment is running.
  *
  ******************************************************************************/
int gcm_initialize(void)
{
	aes_init_keygen_tables();
	return(0);
}


/******************************************************************************
 *
 *  GCM_MULT
 *
 *  Performs a GHASH operation on the 128-bit input vector 'x', setting
 *  the 128-bit output vector to 'x' times H using our precomputed tables.
 *  'x' and 'output' are seen as elements of GCM's GF(2^128) Galois field.
 *
 ******************************************************************************/
static void gcm_mult(gcm_context *ctx,     // pointer to established context
	const uchar x[16],    // pointer to 128-bit input vector
	uchar output[16])    // pointer to 128-bit output vector
{
	int i;
	uchar lo, hi, rem;
	uint64_t zh, zl;

	lo = (uchar)(x[15] & 0x0f);
	hi = (uchar)(x[15] >> 4);
	zh = ctx->HH[lo];
	zl = ctx->HL[lo];

	for (i = 15; i >= 0; i--) {
		lo = (uchar)(x[i] & 0x0f);
		hi = (uchar)(x[i] >> 4);

		if (i != 15) {
			rem = (uchar)(zl & 0x0f);
			zl = (zh << 60) | (zl >> 4);
			zh = (zh >> 4);
			zh ^= (uint64_t)last4[rem] << 48;
			zh ^= ctx->HH[lo];
			zl ^= ctx->HL[lo];
		}
		rem = (uchar)(zl & 0x0f);
		zl = (zh << 60) | (zl >> 4);
		zh = (zh >> 4);
		zh ^= (uint64_t)last4[rem] << 48;
		zh ^= ctx->HH[hi];
		zl ^= ctx->HL[hi];
	}
	PUT_UINT32_BE(zh >> 32, output, 0);
	PUT_UINT32_BE(zh, output, 4);
	PUT_UINT32_BE(zl >> 32, output, 8);
	PUT_UINT32_BE(zl, output, 12);
}


/******************************************************************************
 *
 *  GCM_SETKEY
 *
 *  This is called to set the AES-GCM key. It initializes the AES key
 *  and populates the gcm context's pre-calculated HTables.
 *
 ******************************************************************************/
int gcm_setkey(gcm_context *ctx,   // pointer to caller-provided gcm context
	const uchar *key,   // pointer to the AES encryption key
	const uint keysize) // size in bytes (must be 16, 24, 32 for
				// 128, 192 or 256-bit keys respectively)
{
	int ret, i, j;
	uint64_t hi, lo;
	uint64_t vl, vh;
	unsigned char h[16];

	memset(ctx, 0, sizeof(gcm_context));  // zero caller-provided GCM context
	memset(h, 0, 16);                     // initialize the block to encrypt

	// encrypt the null 128-bit block to generate a key-based value
	// which is then used to initialize our GHASH lookup tables
	if ((ret = aes_setkey(&ctx->aes_ctx, AES_ENCRYPT, key, keysize)) != 0)
		return(ret);
	if ((ret = aes_cipher(&ctx->aes_ctx, h, h)) != 0)
		return(ret);

	GET_UINT32_BE(hi, h, 0);    // pack h as two 64-bit ints, big-endian
	GET_UINT32_BE(lo, h, 4);
	vh = (uint64_t)hi << 32 | lo;

	GET_UINT32_BE(hi, h, 8);
	GET_UINT32_BE(lo, h, 12);
	vl = (uint64_t)hi << 32 | lo;

	ctx->HL[8] = vl;                // 8 = 1000 corresponds to 1 in GF(2^128)
	ctx->HH[8] = vh;
	ctx->HH[0] = 0;                 // 0 corresponds to 0 in GF(2^128)
	ctx->HL[0] = 0;

	for (i = 4; i > 0; i >>= 1) {
		uint32_t T = (uint32_t)(vl & 1) * 0xe1000000U;
		vl = (vh << 63) | (vl >> 1);
		vh = (vh >> 1) ^ ((uint64_t)T << 32);
		ctx->HL[i] = vl;
		ctx->HH[i] = vh;
	}
	for (i = 2; i < 16; i <<= 1) {
		uint64_t *HiL = ctx->HL + i, *HiH = ctx->HH + i;
		vh = *HiH;
		vl = *HiL;
		for (j = 1; j < i; j++) {
			HiH[j] = vh ^ ctx->HH[j];
			HiL[j] = vl ^ ctx->HL[j];
		}
	}
	return(0);
}


/******************************************************************************
 *
 *    GCM processing occurs four phases: SETKEY, START, UPDATE and FINISH.
 *
 *  SETKEY:
 *
 *   START: Sets the Encryption/Decryption mode.
 *          Accepts the initialization vector and additional data.
 *
 *  UPDATE: Encrypts or decrypts the plaintext or ciphertext.
 *
 *  FINISH: Performs a final GHASH to generate the authentication tag.
 *
 ******************************************************************************
 *
 *  GCM_START
 *
 *  Given a user-provided GCM context, this initializes it, sets the encryption
 *  mode, and preprocesses the initialization vector and additional AEAD data.
 *
 ******************************************************************************/
int gcm_start(gcm_context *ctx,    // pointer to user-provided GCM context
	int mode,            // AES_ENCRYPT or AES_DECRYPT
	const uchar *iv,     // pointer to initialization vector
	size_t iv_len,       // IV length in bytes (should == 12)
	const uchar *add,    // ptr to additional AEAD data (NULL if none)
	size_t add_len)     // length of additional AEAD data (bytes)
{
	int ret;            // our error return if the AES encrypt fails
	uchar work_buf[16]; // XOR source built from provided IV if len != 16
	const uchar *p;     // general purpose array pointer
	size_t use_len;     // byte count to process, up to 16 bytes
	size_t i;           // local loop iterator

	// since the context might be reused under the same key
	// we zero the working buffers for this next new process
	memset(ctx->y, 0x00, sizeof(ctx->y));
	memset(ctx->buf, 0x00, sizeof(ctx->buf));
	ctx->len = 0;
	ctx->add_len = 0;

	ctx->mode = mode;               // set the GCM encryption/decryption mode
	ctx->aes_ctx.mode = AES_ENCRYPT;    // GCM *always* runs AES in ENCRYPTION mode

	if (iv_len == 12) {                // GCM natively uses a 12-byte, 96-bit IV
		memcpy(ctx->y, iv, iv_len);   // copy the IV to the top of the 'y' buff
		ctx->y[15] = 1;                 // start "counting" from 1 (not 0)
	}
	else    // if we don't have a 12-byte IV, we GHASH whatever we've been given
	{
		memset(work_buf, 0x00, 16);               // clear the working buffer
		PUT_UINT32_BE(iv_len * 8, work_buf, 12);  // place the IV into buffer

		p = iv;
		while (iv_len > 0) {
			use_len = (iv_len < 16) ? iv_len : 16;
			for (i = 0; i < use_len; i++) ctx->y[i] ^= p[i];
			gcm_mult(ctx, ctx->y, ctx->y);
			iv_len -= use_len;
			p += use_len;
		}
		for (i = 0; i < 16; i++) ctx->y[i] ^= work_buf[i];
		gcm_mult(ctx, ctx->y, ctx->y);
	}

	if ((ret = aes_cipher(&ctx->aes_ctx, ctx->y, ctx->base_ectr)) != 0)
		return(ret);

	ctx->add_len = add_len;
	p = add;
	while (add_len > 0) {
		use_len = (add_len < 16) ? add_len : 16;
		for (i = 0; i < use_len; i++) ctx->buf[i] ^= p[i];
		gcm_mult(ctx, ctx->buf, ctx->buf);
		add_len -= use_len;
		p += use_len;
	}
	return(0);
}

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
	uchar *output)         // pointer to destination data
{
	int ret;            // our error return if the AES encrypt fails
	uchar ectr[16];     // counter-mode cipher output for XORing
	size_t use_len;     // byte count to process, up to 16 bytes
	size_t i;           // local loop iterator

	ctx->len += length; // bump the GCM context's running length count

	while (length > 0) {
		// clamp the length to process at 16 bytes
		use_len = (length < 16) ? length : 16;

		// increment the context's 128-bit IV||Counter 'y' vector
		for (i = 16; i > 12; i--) if (++ctx->y[i - 1] != 0) break;

		// encrypt the context's 'y' vector under the established key
		if ((ret = aes_cipher(&ctx->aes_ctx, ctx->y, ectr)) != 0)
			return(ret);

		// encrypt or decrypt the input to the output
		if (ctx->mode == AES_ENCRYPT)
		{
			for (i = 0; i < use_len; i++) {
				// XOR the cipher's ouptut vector (ectr) with our input
				output[i] = (uchar)(ectr[i] ^ input[i]);
				// now we mix in our data into the authentication hash.
				// if we're ENcrypting we XOR in the post-XOR (output)
				// results, but if we're DEcrypting we XOR in the input
				// data
				ctx->buf[i] ^= output[i];
			}
		}
		else
		{
			for (i = 0; i < use_len; i++) {
				// but if we're DEcrypting we XOR in the input data first,
				// i.e. before saving to ouput data, otherwise if the input
				// and output buffer are the same (inplace decryption) we
				// would not get the correct auth tag

				ctx->buf[i] ^= input[i];

				// XOR the cipher's ouptut vector (ectr) with our input
				output[i] = (uchar)(ectr[i] ^ input[i]);
			}
		}
		gcm_mult(ctx, ctx->buf, ctx->buf);    // perform a GHASH operation

		length -= use_len;  // drop the remaining byte count to process
		input += use_len;  // bump our input pointer forward
		output += use_len;  // bump our output pointer forward
	}
	return(0);
}

/******************************************************************************
 *
 *  GCM_FINISH
 *
 *  This is called once after all calls to GCM_UPDATE to finalize the GCM.
 *  It performs the final GHASH to produce the resulting authentication TAG.
 *
 ******************************************************************************/
int gcm_finish(gcm_context *ctx,   // pointer to user-provided GCM context
	uchar *tag,         // pointer to buffer which receives the tag
	size_t tag_len)    // length, in bytes, of the tag-receiving buf
{
	uchar work_buf[16];
	uint64_t orig_len = ctx->len * 8;
	uint64_t orig_add_len = ctx->add_len * 8;
	size_t i;

	if (tag_len>16) return -1;

	if (tag_len) memcpy(tag, ctx->base_ectr, tag_len);

	if (orig_len || orig_add_len) {
		memset(work_buf, 0x00, 16);

		PUT_UINT32_BE((orig_add_len >> 32), work_buf, 0);
		PUT_UINT32_BE((orig_add_len), work_buf, 4);
		PUT_UINT32_BE((orig_len >> 32), work_buf, 8);
		PUT_UINT32_BE((orig_len), work_buf, 12);

		for (i = 0; i < 16; i++) ctx->buf[i] ^= work_buf[i];
		gcm_mult(ctx, ctx->buf, ctx->buf);
		for (i = 0; i < tag_len; i++) tag[i] ^= ctx->buf[i];
	}
	return(0);
}


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
	int mode,               // cipher direction: AES_ENCRYPT or AES_DECRYPT
	const uchar *iv,        // pointer to the 12-byte initialization vector
	size_t iv_len,          // byte length if the IV. should always be 12
	const uchar *add,       // pointer to the non-ciphered additional data
	size_t add_len,         // byte length of the additional AEAD data
	const uchar *input,     // pointer to the cipher data source
	uchar *output,          // pointer to the cipher data destination
	size_t length,          // byte length of the cipher data
	uchar *tag,             // pointer to the tag to be generated
	size_t tag_len)        // byte length of the tag to be generated
{   /*
	   assuming that the caller has already invoked gcm_setkey to
	   prepare the gcm context with the keying material, we simply
	   invoke each of the three GCM sub-functions in turn...
	*/
	if (tag_len>16) return -1;

	int ret;
	if ((ret=gcm_start(ctx, mode, iv, iv_len, add, add_len))) return ret;
	if ((ret=gcm_update(ctx, length, input, output))) return ret;
	return gcm_finish(ctx, tag, tag_len);
}


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
	size_t tag_len)        // byte length of the tag <= 16
{
	uchar check_tag[16];        // the tag generated and returned by decryption
	int diff;                   // an ORed flag to detect authentication errors
	size_t i;                   // our local iterator
	int ret;

	if (tag_len>16) return -1;

	/*
	   we use GCM_DECRYPT_AND_TAG (above) to perform our decryption
	   (which is an identical XORing to reverse the previous one)
	   and also to re-generate the matching authentication tag
	*/
	if ((ret = gcm_crypt_and_tag(ctx, AES_DECRYPT, iv, iv_len, add, add_len, input, output, length, check_tag, tag_len))) return ret;

	// now we verify the authentication tag in 'constant time'
	for (diff = 0, i = 0; i < tag_len; i++)
		diff |= tag[i] ^ check_tag[i];

	if (diff)
	{
		// see whether any bits differed?
		memset(output, 0, length);    // if so... wipe the output data
		return(GCM_AUTH_FAILURE);     // return GCM_AUTH_FAILURE
	}
	return 0;
}

/******************************************************************************
 *
 *  GCM_ZERO_CTX
 *
 *  The GCM context contains both the GCM context and the AES context.
 *  This includes keying and key-related material which is security-
 *  sensitive, so it MUST be zeroed after use. This function does that.
 *
 ******************************************************************************/
void gcm_zero_ctx(gcm_context *ctx)
{
	// zero the context originally provided to us
	memset(ctx, 0, sizeof(gcm_context));
}
