#pragma once

#include "gcm.h"

// mode : AES_ENCRYPT, AES_DECRYPT
int aes_gcm_crypt(int mode, uint8_t *output, const uint8_t *input, size_t input_length, const uint8_t *key, const size_t key_len, const uint8_t *iv, const size_t iv_len, const uint8_t *adata, size_t adata_len, uint8_t *atag, size_t atag_len);
