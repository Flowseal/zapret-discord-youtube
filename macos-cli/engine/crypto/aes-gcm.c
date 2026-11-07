#include "aes-gcm.h"

int aes_gcm_crypt(int mode, uint8_t *output, const uint8_t *input, size_t input_length, const uint8_t *key, const size_t key_len, const uint8_t *iv, const size_t iv_len, const uint8_t *adata, size_t adata_len, uint8_t *atag, size_t atag_len)
{
	int ret = 0;
	gcm_context ctx;

	gcm_initialize();

	if (!(ret = gcm_setkey(&ctx, key, (const uint)key_len)))
	{
		ret = gcm_crypt_and_tag(&ctx, mode, iv, iv_len, adata, adata_len, input, output, input_length, atag, atag_len);
		gcm_zero_ctx(&ctx);
	}

	return ret;
}
