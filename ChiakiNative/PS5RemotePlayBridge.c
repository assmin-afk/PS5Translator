// ============================================================================
// PS5RemotePlayBridge.c - Bọc ChiakiSession (chiaki-ng) cho Swift
// ============================================================================
#include "PS5RemotePlayBridge.h"

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/session.h>
#include <chiaki/controller.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct PS5RPHandle {
	ChiakiSession session;
	ChiakiLog log;
	ChiakiControllerState controller;
	char host[256];
	PS5RPVideoCallback video_cb;
	PS5RPEventCallback event_cb;
	void *user;
	bool session_inited;
	bool session_started;
};

_Static_assert(PS5RP_QUIT_STOPPED == CHIAKI_QUIT_REASON_STOPPED, "quit enum");
_Static_assert(PS5RP_QUIT_REMOTE_DISCONNECTED == CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED, "quit enum");
_Static_assert(PS5RP_QUIT_REMOTE_SHUTDOWN == CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN, "quit enum");

static int g_inited = 0;

int32_t ps5rp_global_init(void)
{
	if(g_inited)
		return 0;
	ChiakiErrorCode err = chiaki_lib_init();
	if(err != CHIAKI_ERR_SUCCESS)
		return (int32_t)err;
	g_inited = 1;
	return 0;
}

static void ps5rp_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	PS5RPHandle *h = (PS5RPHandle *)user;
	if(h && h->event_cb)
		h->event_cb(PS5RP_EVENT_LOG, (int32_t)level, msg, h->user);
}

static void ps5rp_event_cb(ChiakiEvent *event, void *user)
{
	PS5RPHandle *h = (PS5RPHandle *)user;
	if(!h || !h->event_cb || !event)
		return;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			h->event_cb(PS5RP_EVENT_CONNECTED, 0, NULL, h->user);
			break;
		case CHIAKI_EVENT_QUIT:
		{
			char buf[512];
			const char *base = chiaki_quit_reason_string(event->quit.reason);
			if(event->quit.reason_str && event->quit.reason_str[0])
				snprintf(buf, sizeof(buf), "%s (%s)", base ? base : "?", event->quit.reason_str);
			else
				snprintf(buf, sizeof(buf), "%s", base ? base : "?");
			h->event_cb(PS5RP_EVENT_QUIT, (int32_t)event->quit.reason, buf, h->user);
			break;
		}
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			h->event_cb(PS5RP_EVENT_LOGIN_PIN_REQUEST, event->login_pin_request.pin_incorrect ? 1 : 0, NULL, h->user);
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
			h->event_cb(PS5RP_EVENT_NICKNAME, 0, event->server_nickname, h->user);
			break;
		default:
			break;
	}
}

static bool ps5rp_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	(void)frame_recovered;
	PS5RPHandle *h = (PS5RPHandle *)user;
	if(h && h->video_cb && buf && buf_size > 0)
		h->video_cb(buf, buf_size, frames_lost, h->user);
	return true;
}

PS5RPHandle *ps5rp_start(const char *host,
                         const uint8_t *regist_key16,
                         const uint8_t *morning16,
                         const uint8_t *account_id8,
                         uint32_t width, uint32_t height, uint32_t max_fps, uint32_t bitrate_kbps,
                         int32_t codec,
                         PS5RPVideoCallback video_cb,
                         PS5RPEventCallback event_cb,
                         void *user,
                         int32_t *err_out)
{
	if(err_out) *err_out = 0;
	if(!host || !regist_key16 || !morning16)
	{
		if(err_out) *err_out = (int32_t)CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	if(!g_inited)
	{
		int32_t r = ps5rp_global_init();
		if(r != 0)
		{
			if(err_out) *err_out = r;
			return NULL;
		}
	}

	PS5RPHandle *h = (PS5RPHandle *)calloc(1, sizeof(PS5RPHandle));
	if(!h)
	{
		if(err_out) *err_out = (int32_t)CHIAKI_ERR_MEMORY;
		return NULL;
	}
	h->video_cb = video_cb;
	h->event_cb = event_cb;
	h->user = user;
	snprintf(h->host, sizeof(h->host), "%s", host);

	chiaki_log_init(&h->log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO, ps5rp_log_cb, h);

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = h->host;
	memcpy(info.regist_key, regist_key16, CHIAKI_SESSION_AUTH_SIZE);
	memcpy(info.morning, morning16, sizeof(info.morning));
	if(account_id8)
		memcpy(info.psn_account_id, account_id8, CHIAKI_PSN_ACCOUNT_ID_SIZE);

	info.video_profile.width = width ? width : 1280;
	info.video_profile.height = height ? height : 720;
	info.video_profile.max_fps = max_fps ? max_fps : 30;
	info.video_profile.bitrate = bitrate_kbps ? bitrate_kbps : 10000;
	info.video_profile.codec = codec == 1 ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = false;
	// App chỉ cần hình để OCR: tắt âm thanh giúp tiết kiệm băng thông (không cần Opus)
	info.audio_video_disabled = CHIAKI_AUDIO_DISABLED;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	info.packet_loss_max = 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiErrorCode err = chiaki_session_init(&h->session, &info, &h->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(err_out) *err_out = (int32_t)err;
		free(h);
		return NULL;
	}
	h->session_inited = true;

	chiaki_session_set_event_cb(&h->session, ps5rp_event_cb, h);
	chiaki_session_set_video_sample_cb(&h->session, ps5rp_video_cb, h);
	chiaki_controller_state_set_idle(&h->controller);

	err = chiaki_session_start(&h->session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(err_out) *err_out = (int32_t)err;
		chiaki_session_fini(&h->session);
		free(h);
		return NULL;
	}
	h->session_started = true;
	return h;
}

void ps5rp_stop_and_free(PS5RPHandle *h)
{
	if(!h)
		return;
	if(h->session_started)
	{
		chiaki_session_stop(&h->session);
		chiaki_session_join(&h->session);
	}
	if(h->session_inited)
		chiaki_session_fini(&h->session);
	h->event_cb = NULL;
	h->video_cb = NULL;
	free(h);
}

int32_t ps5rp_request_idr(PS5RPHandle *h)
{
	if(!h || !h->session_started)
		return (int32_t)CHIAKI_ERR_INVALID_DATA;
	return (int32_t)chiaki_session_request_idr(&h->session);
}

int32_t ps5rp_set_controller(PS5RPHandle *h, uint32_t buttons, uint8_t l2, uint8_t r2,
                             int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y)
{
	if(!h || !h->session_started)
		return (int32_t)CHIAKI_ERR_INVALID_DATA;
	h->controller.buttons = buttons;
	h->controller.l2_state = l2;
	h->controller.r2_state = r2;
	h->controller.left_x = left_x;
	h->controller.left_y = left_y;
	h->controller.right_x = right_x;
	h->controller.right_y = right_y;
	return (int32_t)chiaki_session_set_controller_state(&h->session, &h->controller);
}
