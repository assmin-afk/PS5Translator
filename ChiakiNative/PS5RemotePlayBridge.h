// ============================================================================
// PS5RemotePlayBridge.h - API C gọn (không lộ kiểu dữ liệu của chiaki) để Swift
// gọi phiên Remote Play PS5 đầy đủ của chiaki-ng (sess/init, ctrl, Takion, ECDH,
// giải mã gkcrypt, FEC, ghép khung hình video).
// ============================================================================
#ifndef PS5_REMOTE_PLAY_BRIDGE_H
#define PS5_REMOTE_PLAY_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PS5RPHandle PS5RPHandle;

// Loại sự kiện gửi lên Swift
#define PS5RP_EVENT_CONNECTED          0
#define PS5RP_EVENT_QUIT               1
#define PS5RP_EVENT_LOG                2
#define PS5RP_EVENT_LOGIN_PIN_REQUEST  3
#define PS5RP_EVENT_NICKNAME           4

// Mã quit (khớp ChiakiQuitReason)
#define PS5RP_QUIT_STOPPED                   1
#define PS5RP_QUIT_REMOTE_DISCONNECTED      11
#define PS5RP_QUIT_REMOTE_SHUTDOWN          12

/// buf: 1 khung hình H.264/H.265 dạng Annex-B (có start code 00 00 00 01)
typedef void (*PS5RPVideoCallback)(const uint8_t *buf, size_t len, int32_t frames_lost, void *user);
/// kind: PS5RP_EVENT_*; code: mã quit hoặc mức log; message: chuỗi UTF-8 (có thể NULL)
typedef void (*PS5RPEventCallback)(int32_t kind, int32_t code, const char *message, void *user);

/// Gọi 1 lần khi app khởi động. Trả 0 nếu thành công.
int32_t ps5rp_global_init(void);

/// Bắt đầu phiên Remote Play. Trả NULL nếu lỗi (err_out = ChiakiErrorCode).
/// regist_key16: 16 byte rp_regist_key (đã parse hex, đệm 0x00)
/// morning16:    16 byte RP-Key
/// account_id8:  8 byte PSN account id (có thể NULL)
/// codec: 0 = H.264, 1 = H.265
PS5RPHandle *ps5rp_start(const char *host,
                         const uint8_t *regist_key16,
                         const uint8_t *morning16,
                         const uint8_t *account_id8,
                         uint32_t width, uint32_t height, uint32_t max_fps, uint32_t bitrate_kbps,
                         int32_t codec,
                         PS5RPVideoCallback video_cb,
                         PS5RPEventCallback event_cb,
                         void *user,
                         int32_t *err_out);

/// Dừng phiên, chờ luồng kết thúc và giải phóng (BLOCKING - không gọi trên main thread
/// hay bên trong callback).
void ps5rp_stop_and_free(PS5RPHandle *handle);

/// Yêu cầu PS5 gửi lại keyframe (IDR) khi bộ giải mã cần.
int32_t ps5rp_request_idr(PS5RPHandle *handle);

/// Gửi trạng thái tay cầm (buttons = bitmask CHIAKI_CONTROLLER_BUTTON_*).
int32_t ps5rp_set_controller(PS5RPHandle *handle, uint32_t buttons, uint8_t l2, uint8_t r2,
                             int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y);

#ifdef __cplusplus
}
#endif

#endif
