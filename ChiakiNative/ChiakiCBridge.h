#ifndef CHIAKI_C_BRIDGE_H
#define CHIAKI_C_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int chiaki_bridge_build_ps5_regist_payload(
    const char *pin_str,
    const char *account_id_b64,
    const char *client_type_str,
    uint8_t *out_payload,
    size_t *out_len,
    uint8_t out_bright[16],
    uint8_t out_echidna[16],
    uint8_t out_hmac_key[16]
);

int chiaki_bridge_decrypt_regist_response(
    const uint8_t *cipher,
    size_t cipher_len,
    const uint8_t bright[16],
    const uint8_t echidna[16],
    const uint8_t hmac_key[16],
    uint8_t *out_plain,
    size_t max_plain_len
);

int chiaki_bridge_encrypt_session_data(
    const uint8_t nonce[16],
    const uint8_t rp_key[16],
    uint64_t counter,
    const uint8_t *data_in,
    size_t data_len,
    uint8_t *data_out
);

#ifdef __cplusplus
}
#endif

#endif
