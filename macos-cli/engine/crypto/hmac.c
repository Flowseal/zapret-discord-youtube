/**************************** hmac.c ***************************/
/***************** See RFC 6234 for details. *******************/
/* Copyright (c) 2011 IETF Trust and the persons identified as */
/* authors of the code.  All rights reserved.                  */
/* See sha.h for terms of use and redistribution.              */

/*
 *  Description:
 *      This file implements the HMAC algorithm (Keyed-Hashing for
 *      Message Authentication, [RFC 2104]), expressed in terms of
 *      the various SHA algorithms.
 */

#include "sha.h"
#include <stddef.h>

 /*
  *  hmac
  *
  *  Description:
  *      This function will compute an HMAC message digest.
  *
  *  Parameters:
  *      whichSha: [in]
  *          One of SHA1, SHA224, SHA256, SHA384, SHA512
  *      message_array[ ]: [in]
  *          An array of octets representing the message.
  *          Note: in RFC 2104, this parameter is known
  *          as 'text'.
  *      length: [in]
  *          The length of the message in message_array.
  *      key[ ]: [in]
  *          The secret shared key.
  *      key_len: [in]
  *          The length of the secret shared key.
  *      digest[ ]: [out]
  *          Where the digest is to be returned.
  *          NOTE: The length of the digest is determined by
  *              the value of whichSha.
  *
  *  Returns:
  *      sha Error Code.
  *
  */

int hmac(SHAversion whichSha,
	const unsigned char *message_array, size_t length,
	const unsigned char *key, size_t key_len,
	uint8_t digest[USHAMaxHashSize])
{
	HMACContext context;
	int ret;
	if ((ret=hmacReset(&context, whichSha, key, key_len))) return ret;
	if ((ret=hmacInput(&context, message_array, length))) return ret;
	return hmacResult(&context, digest);
}

/*
 *  hmacReset
 *
 *  Description:
 *      This function will initialize the hmacContext in preparation
 *      for computing a new HMAC message digest.
 *
 *  Parameters:
 *      context: [in/out]
 *          The context to reset.
 *      whichSha: [in]
 *          One of SHA1, SHA224, SHA256, SHA384, SHA512
 *      key[ ]: [in]
 *          The secret shared key.
 *      key_len: [in]
 *          The length of the secret shared key.
 *
 *  Returns:
 *      sha Error Code.
 *
 */
int hmacReset(HMACContext *context, enum SHAversion whichSha,
	const unsigned char *key, size_t key_len)
{
	size_t i, blocksize, hashsize;
	int ret;

	/* inner padding - key XORd with ipad */
	unsigned char k_ipad[USHA_Max_Message_Block_Size];

	/* temporary buffer when keylen > blocksize */
	unsigned char tempkey[USHAMaxHashSize];

	if (!context) return shaNull;
	context->Computed = 0;
	context->Corrupted = shaSuccess;

	blocksize = context->blockSize = USHABlockSize(whichSha);
	hashsize = context->hashSize = USHAHashSize(whichSha);
	context->whichSha = whichSha;

	/*
	 * If key is longer than the hash blocksize,
	 * reset it to key = HASH(key).
	 */
	if (key_len > blocksize) {
		USHAContext tcontext;
		if ((ret=USHAReset(&tcontext, whichSha)) || (ret=USHAInput(&tcontext, key, key_len)) || (ret=USHAResult(&tcontext, tempkey)))
			return ret;

		key = tempkey;
		key_len = hashsize;
	}

	/*
	 * The HMAC transform looks like:
	 *
	 * SHA(K XOR opad, SHA(K XOR ipad, text))
	 *
	 * where K is an n byte key, 0-padded to a total of blocksize bytes,
	 * ipad is the byte 0x36 repeated blocksize times,
	 * opad is the byte 0x5c repeated blocksize times,
	 * and text is the data being protected.
	 */

	 /* store key into the pads, XOR'd with ipad and opad values */
	for (i = 0; i < key_len; i++) {
		k_ipad[i] = key[i] ^ 0x36;
		context->k_opad[i] = key[i] ^ 0x5c;
	}
	/* remaining pad bytes are '\0' XOR'd with ipad and opad values */
	for (; i < blocksize; i++) {
		k_ipad[i] = 0x36;
		context->k_opad[i] = 0x5c;
	}

	/* perform inner hash */
	/* init context for 1st pass */
	if (!(ret = USHAReset(&context->shaContext, whichSha)))
		/* and start with inner pad */
		ret = USHAInput(&context->shaContext, k_ipad, blocksize);
	return context->Corrupted = ret;
}

/*
 *  hmacInput
 *
 *  Description:
 *      This function accepts an array of octets as the next portion
 *      of the message.  It may be called multiple times.
 *
 *  Parameters:
 *      context: [in/out]
 *          The HMAC context to update.
 *      text[ ]: [in]
 *          An array of octets representing the next portion of
 *          the message.
 *      text_len: [in]
 *          The length of the message in text.
 *
 *  Returns:
 *      sha Error Code.
 *
 */
int hmacInput(HMACContext *context, const unsigned char *text,
	size_t text_len)
{
	if (!context) return shaNull;
	if (context->Corrupted) return context->Corrupted;
	if (context->Computed) return context->Corrupted = shaStateError;
	/* then text of datagram */
	return context->Corrupted =
		USHAInput(&context->shaContext, text, text_len);
}

/*
 * hmacFinalBits
 *
 * Description:
 *   This function will add in any final bits of the message.
 *
 * Parameters:
 *   context: [in/out]
 *     The HMAC context to update.
 *   message_bits: [in]
 *     The final bits of the message, in the upper portion of the
 *     byte.  (Use 0b###00000 instead of 0b00000### to input the
 *     three bits ###.)
 *   length: [in]
 *     The number of bits in message_bits, between 1 and 7.
 *
 * Returns:
 *   sha Error Code.
 */
int hmacFinalBits(HMACContext *context,
	uint8_t bits, unsigned int bit_count)
{
	if (!context) return shaNull;
	if (context->Corrupted) return context->Corrupted;
	if (context->Computed) return context->Corrupted = shaStateError;
	/* then final bits of datagram */
	return context->Corrupted = USHAFinalBits(&context->shaContext, bits, bit_count);
}

/*
 * hmacResult
 *
 * Description:
 *   This function will return the N-byte message digest into the
 *   Message_Digest array provided by the caller.
 *
 * Parameters:
 *   context: [in/out]
 *     The context to use to calculate the HMAC hash.
 *   digest[ ]: [out]
 *     Where the digest is returned.
 *     NOTE 2: The length of the hash is determined by the value of
 *      whichSha that was passed to hmacReset().
 *
 * Returns:
 *   sha Error Code.
 *
 */
int hmacResult(HMACContext *context, uint8_t *digest)
{
	int ret;
	if (!context) return shaNull;
	if (context->Corrupted) return context->Corrupted;
	if (context->Computed) return context->Corrupted = shaStateError;

	/* finish up 1st pass */
	/* (Use digest here as a temporary buffer.) */
	if (!(ret=USHAResult(&context->shaContext, digest)) &&
		/* perform outer SHA */
		/* init context for 2nd pass */
		!(ret=USHAReset(&context->shaContext, context->whichSha)) &&
		/* start with outer pad */
		!(ret=USHAInput(&context->shaContext, context->k_opad, context->blockSize)) &&
		/* then results of 1st hash */
		!(ret=USHAInput(&context->shaContext, digest, context->hashSize)))
		/* finish up 2nd pass */
		ret=USHAResult(&context->shaContext, digest);

	context->Computed = 1;
	return context->Corrupted = ret;
}
