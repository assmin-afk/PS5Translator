// ChiakiCBridge.c - Hàm hỗ trợ ghép đôi PIN (regist) dùng rpcrypt của chiaki-ng (bản mbedTLS)
#include "ChiakiCBridge.h"
#include <chiaki/regist.h>
#include <chiaki/rpcrypt.h>
#include <chiaki/base64.h>
#include <chiaki/log.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <chiaki/random.h>

static ChiakiRPCrypt g_last_rpcrypt;
static int g_has_last_rpcrypt = 0;

static int decode_b64_account_id_8bytes(const char *b64_str, uint8_t out_bytes[8]) {
    if (!b64_str) return -1;
    static const int8_t b64_table[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
        52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-2,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
        15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
        41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
    };
    uint32_t val = 0;
    int valb = -8;
    size_t out_idx = 0;
    for (const unsigned char *p = (const unsigned char *)b64_str; *p; p++) {
        int8_t d = b64_table[*p];
        if (d == -1) continue;
        if (d == -2) break;
        val = (val << 6) + (uint32_t)d;
        valb += 6;
        if (valb >= 0) {
            if (out_idx < 8) {
                out_bytes[out_idx++] = (uint8_t)((val >> valb) & 0xFF);
            }
            valb -= 8;
        }
    }
    return (out_idx == 8) ? 0 : -1;
}

int chiaki_bridge_build_ps5_regist_payload(
    const char *pin_str,
    const char *account_id_b64,
    const char *client_type_str,
    uint8_t *out_payload,
    size_t *out_len,
    uint8_t out_bright[16],
    uint8_t out_echidna[16],
    uint8_t out_hmac_key[16]
) {
    (void)client_type_str;
    if (!pin_str || !account_id_b64 || !out_payload || !out_len) {
        return -1;
    }

    uint32_t pin = (uint32_t)strtoul(pin_str, NULL, 10);
    uint8_t ambassador[16];
    chiaki_random_bytes_crypt(ambassador, 16);

    uint8_t decoded_aid[8] = {0};
    if (decode_b64_account_id_8bytes(account_id_b64, decoded_aid) != 0) {
        return -2;
    }

    memset(&g_last_rpcrypt, 0, sizeof(g_last_rpcrypt));
    size_t buf_size = 1024;

    // QUAN TRONG: Tham so thu 6 (psn_online_id) BAT BUOC phai la NULL tren PS5
    // de chiaki_regist_request_payload_format dung Np-AccountId (decoded_aid) thay vi Np-OnlineId (gay loi 80108bff / 80108b02)
    ChiakiErrorCode err = chiaki_regist_request_payload_format(
        CHIAKI_TARGET_PS5_1,
        ambassador,
        out_payload,
        &buf_size,
        &g_last_rpcrypt,
        NULL,
        decoded_aid,
        pin,
        NULL
    );
    if (err != CHIAKI_ERR_SUCCESS) {
        return -3;
    }

    g_has_last_rpcrypt = 1;
    memcpy(out_bright, g_last_rpcrypt.bright, 16);
    memcpy(out_echidna, g_last_rpcrypt.ambassador, 16);
    memcpy(out_hmac_key, g_last_rpcrypt.bright, 16);

    *out_len = buf_size;
    return 0;
}

int chiaki_bridge_decrypt_regist_response(
    const uint8_t *cipher,
    size_t cipher_len,
    const uint8_t bright[16],
    const uint8_t echidna[16],
    const uint8_t hmac_key[16],
    uint8_t *out_plain,
    size_t max_plain_len
) {
    (void)bright; (void)echidna; (void)hmac_key;
    if (!cipher || cipher_len < 16 || !out_plain || !g_has_last_rpcrypt) return -1;

    // chiaki-ng regist.c giai ma toan bo body tu offset 0 -> thu 0x00 TRUOC
    const size_t offsets[3] = { 0x00, 0x20, 0x10 };
    for (int k = 0; k < 3; k++) {
        size_t off = offsets[k];
        if (cipher_len <= off) continue;
        ChiakiRPCrypt rpcrypt = g_last_rpcrypt;
        size_t enc_len = cipher_len - off;
        if (enc_len >= max_plain_len) enc_len = max_plain_len - 1;
        memset(out_plain, 0, max_plain_len);
        if (chiaki_rpcrypt_decrypt(&rpcrypt, 0, cipher + off, out_plain, enc_len) == CHIAKI_ERR_SUCCESS) {
            for (size_t i = 0; i < enc_len; i++) {
                if (out_plain[i] == 0) out_plain[i] = '\n';
            }
            out_plain[enc_len] = 0;
            if (strstr((const char *)out_plain, "RegistKey") != NULL ||
                strstr((const char *)out_plain, "RP-Key") != NULL) {
                return (int)enc_len;
            }
        }
    }
    return -2;
}

int chiaki_bridge_encrypt_session_data(
    const uint8_t nonce[16],
    const uint8_t rp_key[16],
    uint64_t counter,
    const uint8_t *data_in,
    size_t data_len,
    uint8_t *data_out
) {
    if (!nonce || !rp_key || !data_in || !data_out) return -1;

    ChiakiRPCrypt rpcrypt;
    memset(&rpcrypt, 0, sizeof(rpcrypt));
    chiaki_rpcrypt_init_auth(&rpcrypt, CHIAKI_TARGET_PS5_1, nonce, rp_key);
    if (chiaki_rpcrypt_encrypt(&rpcrypt, counter, data_in, data_out, data_len) != CHIAKI_ERR_SUCCESS) {
        return -3;
    }
    return 0;
}
