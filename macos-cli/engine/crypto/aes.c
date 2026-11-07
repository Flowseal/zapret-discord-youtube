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

#include "aes.h"

static int aes_tables_inited = 0;   // run-once flag for performing key
									// expasion table generation (see below)
/*
 *  The following static local tables must be filled-in before the first use of
 *  the GCM or AES ciphers. They are used for the AES key expansion/scheduling
 *  and once built are read-only and thread safe. The "gcm_initialize" function
 *  must be called once during system initialization to populate these arrays
 *  for subsequent use by the AES key scheduler. If they have not been built
 *  before attempted use, an error will be returned to the caller.
 *
 *  NOTE: GCM Encryption/Decryption does NOT REQUIRE AES decryption. Since
 *  GCM uses AES in counter-mode, where the AES cipher output is XORed with
 *  the GCM input, we ONLY NEED AES encryption.  Thus, to save space AES
 *  decryption is typically disabled by setting AES_DECRYPTION to 0 in aes.h.
 */
 // We always need our forward tables
static uchar FSb[256];      // Forward substitution box (FSb)
static uint32_t FT0[256];   // Forward key schedule assembly tables
static uint32_t FT1[256];
static uint32_t FT2[256];
static uint32_t FT3[256];

#if AES_DECRYPTION          // We ONLY need reverse for decryption
static uchar RSb[256];      // Reverse substitution box (RSb)
static uint32_t RT0[256];   // Reverse key schedule assembly tables
static uint32_t RT1[256];
static uint32_t RT2[256];
static uint32_t RT3[256];
#endif                      /* AES_DECRYPTION */

static uint32_t RCON[10];   // AES round constants

/*
 * Platform Endianness Neutralizing Load and Store Macro definitions
 * AES wants platform-neutral Little Endian (LE) byte ordering
 */
#define GET_UINT32_LE(n,b,i) {                  \
    (n) = ( (uint32_t) (b)[(i)    ]       )     \
        | ( (uint32_t) (b)[(i) + 1] <<  8 )     \
        | ( (uint32_t) (b)[(i) + 2] << 16 )     \
        | ( (uint32_t) (b)[(i) + 3] << 24 ); }

#define PUT_UINT32_LE(n,b,i) {                  \
    (b)[(i)    ] = (uchar) ( (n)       );       \
    (b)[(i) + 1] = (uchar) ( (n) >>  8 );       \
    (b)[(i) + 2] = (uchar) ( (n) >> 16 );       \
    (b)[(i) + 3] = (uchar) ( (n) >> 24 ); }

 /*
  *  AES forward and reverse encryption round processing macros
  */
#define AES_FROUND(X0,X1,X2,X3,Y0,Y1,Y2,Y3)     \
{                                               \
    X0 = *RK++ ^ FT0[ ( Y0       ) & 0xFF ] ^   \
                 FT1[ ( Y1 >>  8 ) & 0xFF ] ^   \
                 FT2[ ( Y2 >> 16 ) & 0xFF ] ^   \
                 FT3[ ( Y3 >> 24 ) & 0xFF ];    \
                                                \
    X1 = *RK++ ^ FT0[ ( Y1       ) & 0xFF ] ^   \
                 FT1[ ( Y2 >>  8 ) & 0xFF ] ^   \
                 FT2[ ( Y3 >> 16 ) & 0xFF ] ^   \
                 FT3[ ( Y0 >> 24 ) & 0xFF ];    \
                                                \
    X2 = *RK++ ^ FT0[ ( Y2       ) & 0xFF ] ^   \
                 FT1[ ( Y3 >>  8 ) & 0xFF ] ^   \
                 FT2[ ( Y0 >> 16 ) & 0xFF ] ^   \
                 FT3[ ( Y1 >> 24 ) & 0xFF ];    \
                                                \
    X3 = *RK++ ^ FT0[ ( Y3       ) & 0xFF ] ^   \
                 FT1[ ( Y0 >>  8 ) & 0xFF ] ^   \
                 FT2[ ( Y1 >> 16 ) & 0xFF ] ^   \
                 FT3[ ( Y2 >> 24 ) & 0xFF ];    \
}

#define AES_RROUND(X0,X1,X2,X3,Y0,Y1,Y2,Y3)     \
{                                               \
    X0 = *RK++ ^ RT0[ ( Y0       ) & 0xFF ] ^   \
                 RT1[ ( Y3 >>  8 ) & 0xFF ] ^   \
                 RT2[ ( Y2 >> 16 ) & 0xFF ] ^   \
                 RT3[ ( Y1 >> 24 ) & 0xFF ];    \
                                                \
    X1 = *RK++ ^ RT0[ ( Y1       ) & 0xFF ] ^   \
                 RT1[ ( Y0 >>  8 ) & 0xFF ] ^   \
                 RT2[ ( Y3 >> 16 ) & 0xFF ] ^   \
                 RT3[ ( Y2 >> 24 ) & 0xFF ];    \
                                                \
    X2 = *RK++ ^ RT0[ ( Y2       ) & 0xFF ] ^   \
                 RT1[ ( Y1 >>  8 ) & 0xFF ] ^   \
                 RT2[ ( Y0 >> 16 ) & 0xFF ] ^   \
                 RT3[ ( Y3 >> 24 ) & 0xFF ];    \
                                                \
    X3 = *RK++ ^ RT0[ ( Y3       ) & 0xFF ] ^   \
                 RT1[ ( Y2 >>  8 ) & 0xFF ] ^   \
                 RT2[ ( Y1 >> 16 ) & 0xFF ] ^   \
                 RT3[ ( Y0 >> 24 ) & 0xFF ];    \
}

  /*
   *  These macros improve the readability of the key
   *  generation initialization code by collapsing
   *  repetitive common operations into logical pieces.
   */
#define ROTL8(x) ( ( x << 8 ) & 0xFFFFFFFF ) | ( x >> 24 )
#define XTIME(x) ( ( x << 1 ) ^ ( ( x & 0x80 ) ? 0x1B : 0x00 ) )
#define MUL(x,y) ( ( x && y ) ? pow[(log[x]+log[y]) % 255] : 0 )
#define MIX(x,y) { y = ( (y << 1) | (y >> 7) ) & 0xFF; x ^= y; }
#define CPY128   { *RK++ = *SK++; *RK++ = *SK++; \
                   *RK++ = *SK++; *RK++ = *SK++; }

   /******************************************************************************
	*
	*  AES_INIT_KEYGEN_TABLES
	*
	*  Fills the AES key expansion tables allocated above with their static
	*  data. This is not "per key" data, but static system-wide read-only
	*  table data. THIS FUNCTION IS NOT THREAD SAFE. It must be called once
	*  at system initialization to setup the tables for all subsequent use.
	*
	******************************************************************************/
void aes_init_keygen_tables(void)
{
	int i, x, y, z;     // general purpose iteration and computation locals
	int pow[256];
	int log[256];

	if (aes_tables_inited) return;

	// fill the 'pow' and 'log' tables over GF(2^8)
	for (i = 0, x = 1; i < 256; i++) {
		pow[i] = x;
		log[x] = i;
		x = (x ^ XTIME(x)) & 0xFF;
	}
	// compute the round constants
	for (i = 0, x = 1; i < 10; i++) {
		RCON[i] = (uint32_t)x;
		x = XTIME(x) & 0xFF;
	}
	// fill the forward and reverse substitution boxes
	FSb[0x00] = 0x63;
#if AES_DECRYPTION  // whether AES decryption is supported
	RSb[0x63] = 0x00;
#endif /* AES_DECRYPTION */

	for (i = 1; i < 256; i++) {
		x = y = pow[255 - log[i]];
		MIX(x, y);
		MIX(x, y);
		MIX(x, y);
		MIX(x, y);
		FSb[i] = (uchar)(x ^= 0x63);
#if AES_DECRYPTION  // whether AES decryption is supported
		RSb[x] = (uchar)i;
#endif /* AES_DECRYPTION */

	}
	// generate the forward and reverse key expansion tables
	for (i = 0; i < 256; i++) {
		x = FSb[i];
		y = XTIME(x) & 0xFF;
		z = (y ^ x) & 0xFF;

		FT0[i] = ((uint32_t)y) ^ ((uint32_t)x << 8) ^
			((uint32_t)x << 16) ^ ((uint32_t)z << 24);

		FT1[i] = ROTL8(FT0[i]);
		FT2[i] = ROTL8(FT1[i]);
		FT3[i] = ROTL8(FT2[i]);

#if AES_DECRYPTION  // whether AES decryption is supported
		x = RSb[i];

		RT0[i] = ((uint32_t)MUL(0x0E, x)) ^
			((uint32_t)MUL(0x09, x) << 8) ^
			((uint32_t)MUL(0x0D, x) << 16) ^
			((uint32_t)MUL(0x0B, x) << 24);

		RT1[i] = ROTL8(RT0[i]);
		RT2[i] = ROTL8(RT1[i]);
		RT3[i] = ROTL8(RT2[i]);
#endif /* AES_DECRYPTION */
	}
	aes_tables_inited = 1;  // flag that the tables have been generated
}                           // to permit subsequent use of the AES cipher

/******************************************************************************
 *
 *  AES_SET_ENCRYPTION_KEY
 *
 *  This is called by 'aes_setkey' when we're establishing a key for
 *  subsequent encryption.  We give it a pointer to the encryption
 *  context, a pointer to the key, and the key's length in bytes.
 *  Valid lengths are: 16, 24 or 32 bytes (128, 192, 256 bits).
 *
 ******************************************************************************/
int aes_set_encryption_key(aes_context *ctx,
	const uchar *key,
	uint keysize)
{
	uint i;                 // general purpose iteration local
	uint32_t *RK = ctx->rk; // initialize our RoundKey buffer pointer

	for (i = 0; i < (keysize >> 2); i++) {
		GET_UINT32_LE(RK[i], key, i << 2);
	}

	switch (ctx->rounds)
	{
	case 10:
		for (i = 0; i < 10; i++, RK += 4) {
			RK[4] = RK[0] ^ RCON[i] ^
				((uint32_t)FSb[(RK[3] >> 8) & 0xFF]) ^
				((uint32_t)FSb[(RK[3] >> 16) & 0xFF] << 8) ^
				((uint32_t)FSb[(RK[3] >> 24) & 0xFF] << 16) ^
				((uint32_t)FSb[(RK[3]) & 0xFF] << 24);

			RK[5] = RK[1] ^ RK[4];
			RK[6] = RK[2] ^ RK[5];
			RK[7] = RK[3] ^ RK[6];
		}
		break;

	case 12:
		for (i = 0; i < 8; i++, RK += 6) {
			RK[6] = RK[0] ^ RCON[i] ^
				((uint32_t)FSb[(RK[5] >> 8) & 0xFF]) ^
				((uint32_t)FSb[(RK[5] >> 16) & 0xFF] << 8) ^
				((uint32_t)FSb[(RK[5] >> 24) & 0xFF] << 16) ^
				((uint32_t)FSb[(RK[5]) & 0xFF] << 24);

			RK[7] = RK[1] ^ RK[6];
			RK[8] = RK[2] ^ RK[7];
			RK[9] = RK[3] ^ RK[8];
			RK[10] = RK[4] ^ RK[9];
			RK[11] = RK[5] ^ RK[10];
		}
		break;

	case 14:
		for (i = 0; i < 7; i++, RK += 8) {
			RK[8] = RK[0] ^ RCON[i] ^
				((uint32_t)FSb[(RK[7] >> 8) & 0xFF]) ^
				((uint32_t)FSb[(RK[7] >> 16) & 0xFF] << 8) ^
				((uint32_t)FSb[(RK[7] >> 24) & 0xFF] << 16) ^
				((uint32_t)FSb[(RK[7]) & 0xFF] << 24);

			RK[9] = RK[1] ^ RK[8];
			RK[10] = RK[2] ^ RK[9];
			RK[11] = RK[3] ^ RK[10];

			RK[12] = RK[4] ^
				((uint32_t)FSb[(RK[11]) & 0xFF]) ^
				((uint32_t)FSb[(RK[11] >> 8) & 0xFF] << 8) ^
				((uint32_t)FSb[(RK[11] >> 16) & 0xFF] << 16) ^
				((uint32_t)FSb[(RK[11] >> 24) & 0xFF] << 24);

			RK[13] = RK[5] ^ RK[12];
			RK[14] = RK[6] ^ RK[13];
			RK[15] = RK[7] ^ RK[14];
		}
		break;

	default:
		return -1;
	}
	return(0);
}

#if AES_DECRYPTION  // whether AES decryption is supported

/******************************************************************************
 *
 *  AES_SET_DECRYPTION_KEY
 *
 *  This is called by 'aes_setkey' when we're establishing a
 *  key for subsequent decryption.  We give it a pointer to
 *  the encryption context, a pointer to the key, and the key's
 *  length in bits. Valid lengths are: 128, 192, or 256 bits.
 *
 ******************************************************************************/
int aes_set_decryption_key(aes_context *ctx,
	const uchar *key,
	uint keysize)
{
	int i, j;
	aes_context cty;            // a calling aes context for set_encryption_key
	uint32_t *RK = ctx->rk;     // initialize our RoundKey buffer pointer
	uint32_t *SK;
	int ret;

	cty.rounds = ctx->rounds;   // initialize our local aes context
	cty.rk = cty.buf;           // round count and key buf pointer

	if ((ret = aes_set_encryption_key(&cty, key, keysize)) != 0)
		return(ret);

	SK = cty.rk + cty.rounds * 4;

	CPY128  // copy a 128-bit block from *SK to *RK

		for (i = ctx->rounds - 1, SK -= 8; i > 0; i--, SK -= 8) {
			for (j = 0; j < 4; j++, SK++) {
				*RK++ = RT0[FSb[(*SK) & 0xFF]] ^
					RT1[FSb[(*SK >> 8) & 0xFF]] ^
					RT2[FSb[(*SK >> 16) & 0xFF]] ^
					RT3[FSb[(*SK >> 24) & 0xFF]];
			}
		}
	CPY128  // copy a 128-bit block from *SK to *RK
		memset(&cty, 0, sizeof(aes_context));   // clear local aes context
	return(0);
}

#endif /* AES_DECRYPTION */

/******************************************************************************
 *
 *  AES_SETKEY
 *
 *  Invoked to establish the key schedule for subsequent encryption/decryption
 *
 ******************************************************************************/
int aes_setkey(aes_context *ctx,   // AES context provided by our caller
	int mode,           // ENCRYPT or DECRYPT flag
	const uchar *key,   // pointer to the key
	uint keysize)      // key length in bytes
{
	// since table initialization is not thread safe, we could either add
	// system-specific mutexes and init the AES key generation tables on
	// demand, or ask the developer to simply call "gcm_initialize" once during
	// application startup before threading begins. That's what we choose.
	if (!aes_tables_inited) return (-1);  // fail the call when not inited.

	ctx->mode = mode;       // capture the key type we're creating
	ctx->rk = ctx->buf;     // initialize our round key pointer

	switch (keysize)       // set the rounds count based upon the keysize
	{
	case 16: ctx->rounds = 10; break;   // 16-byte, 128-bit key
	case 24: ctx->rounds = 12; break;   // 24-byte, 192-bit key
	case 32: ctx->rounds = 14; break;   // 32-byte, 256-bit key
	default: return(-1);
	}

#if AES_DECRYPTION
	if (mode == AES_DECRYPT)   // expand our key for encryption or decryption
		return(aes_set_decryption_key(ctx, key, keysize));
	else     /* ENCRYPT */
#endif /* AES_DECRYPTION */
		return(aes_set_encryption_key(ctx, key, keysize));
}

/******************************************************************************
 *
 *  AES_CIPHER
 *
 *  Perform AES encryption and decryption.
 *  The AES context will have been setup with the encryption mode
 *  and all keying information appropriate for the task.
 *
 ******************************************************************************/
int aes_cipher(aes_context *ctx,
	const uchar input[16],
	uchar output[16])
{
	int i;
	uint32_t *RK, X0, X1, X2, X3, Y0, Y1, Y2, Y3;   // general purpose locals

	RK = ctx->rk;

	GET_UINT32_LE(X0, input, 0); X0 ^= *RK++;    // load our 128-bit
	GET_UINT32_LE(X1, input, 4); X1 ^= *RK++;    // input buffer in a storage
	GET_UINT32_LE(X2, input, 8); X2 ^= *RK++;    // memory endian-neutral way
	GET_UINT32_LE(X3, input, 12); X3 ^= *RK++;

#if AES_DECRYPTION  // whether AES decryption is supported

	if (ctx->mode == AES_DECRYPT)
	{
		for (i = (ctx->rounds >> 1) - 1; i > 0; i--)
		{
			AES_RROUND(Y0, Y1, Y2, Y3, X0, X1, X2, X3);
			AES_RROUND(X0, X1, X2, X3, Y0, Y1, Y2, Y3);
		}

		AES_RROUND(Y0, Y1, Y2, Y3, X0, X1, X2, X3);

		X0 = *RK++ ^ \
			((uint32_t)RSb[(Y0) & 0xFF]) ^
			((uint32_t)RSb[(Y3 >> 8) & 0xFF] << 8) ^
			((uint32_t)RSb[(Y2 >> 16) & 0xFF] << 16) ^
			((uint32_t)RSb[(Y1 >> 24) & 0xFF] << 24);

		X1 = *RK++ ^ \
			((uint32_t)RSb[(Y1) & 0xFF]) ^
			((uint32_t)RSb[(Y0 >> 8) & 0xFF] << 8) ^
			((uint32_t)RSb[(Y3 >> 16) & 0xFF] << 16) ^
			((uint32_t)RSb[(Y2 >> 24) & 0xFF] << 24);

		X2 = *RK++ ^ \
			((uint32_t)RSb[(Y2) & 0xFF]) ^
			((uint32_t)RSb[(Y1 >> 8) & 0xFF] << 8) ^
			((uint32_t)RSb[(Y0 >> 16) & 0xFF] << 16) ^
			((uint32_t)RSb[(Y3 >> 24) & 0xFF] << 24);

		X3 = *RK++ ^ \
			((uint32_t)RSb[(Y3) & 0xFF]) ^
			((uint32_t)RSb[(Y2 >> 8) & 0xFF] << 8) ^
			((uint32_t)RSb[(Y1 >> 16) & 0xFF] << 16) ^
			((uint32_t)RSb[(Y0 >> 24) & 0xFF] << 24);
	}
	else /* ENCRYPT */
	{
#endif /* AES_DECRYPTION */

		for (i = (ctx->rounds >> 1) - 1; i > 0; i--)
		{
			AES_FROUND(Y0, Y1, Y2, Y3, X0, X1, X2, X3);
			AES_FROUND(X0, X1, X2, X3, Y0, Y1, Y2, Y3);
		}

		AES_FROUND(Y0, Y1, Y2, Y3, X0, X1, X2, X3);

		X0 = *RK++ ^ \
			((uint32_t)FSb[(Y0) & 0xFF]) ^
			((uint32_t)FSb[(Y1 >> 8) & 0xFF] << 8) ^
			((uint32_t)FSb[(Y2 >> 16) & 0xFF] << 16) ^
			((uint32_t)FSb[(Y3 >> 24) & 0xFF] << 24);

		X1 = *RK++ ^ \
			((uint32_t)FSb[(Y1) & 0xFF]) ^
			((uint32_t)FSb[(Y2 >> 8) & 0xFF] << 8) ^
			((uint32_t)FSb[(Y3 >> 16) & 0xFF] << 16) ^
			((uint32_t)FSb[(Y0 >> 24) & 0xFF] << 24);

		X2 = *RK++ ^ \
			((uint32_t)FSb[(Y2) & 0xFF]) ^
			((uint32_t)FSb[(Y3 >> 8) & 0xFF] << 8) ^
			((uint32_t)FSb[(Y0 >> 16) & 0xFF] << 16) ^
			((uint32_t)FSb[(Y1 >> 24) & 0xFF] << 24);

		X3 = *RK++ ^ \
			((uint32_t)FSb[(Y3) & 0xFF]) ^
			((uint32_t)FSb[(Y0 >> 8) & 0xFF] << 8) ^
			((uint32_t)FSb[(Y1 >> 16) & 0xFF] << 16) ^
			((uint32_t)FSb[(Y2 >> 24) & 0xFF] << 24);

#if AES_DECRYPTION  // whether AES decryption is supported
	}
#endif /* AES_DECRYPTION */

	PUT_UINT32_LE(X0, output, 0);
	PUT_UINT32_LE(X1, output, 4);
	PUT_UINT32_LE(X2, output, 8);
	PUT_UINT32_LE(X3, output, 12);

	return(0);
}
/* end of aes.c */
