#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hcr_session hcr_session;

typedef enum {
  HCR_EVENT_NONE = 0,
  HCR_EVENT_SIGNALING_OPEN = 1,
  HCR_EVENT_SIGNALING_CLOSED = 2,
  HCR_EVENT_JOINED = 3,
  HCR_EVENT_READY = 4,
  HCR_EVENT_PEER_LEFT = 5,
  HCR_EVENT_LOCAL_DESCRIPTION = 6,
  HCR_EVENT_LOCAL_CANDIDATE = 7,
  HCR_EVENT_REMOTE_DESCRIPTION = 8,
  HCR_EVENT_REMOTE_CANDIDATE = 9,
  HCR_EVENT_PEER_STATE = 10,
  HCR_EVENT_CHANNEL_OPEN = 11,
  HCR_EVENT_CHANNEL_CLOSED = 12,
  HCR_EVENT_MESSAGE = 13,
  HCR_EVENT_BINARY_MESSAGE = 14,
  HCR_EVENT_ERROR = 15,
  HCR_EVENT_QUEUE_OVERFLOW = 16,
  HCR_EVENT_FRAME_MESSAGE = 17,
  HCR_EVENT_FILE_OFFER = 18,
  HCR_EVENT_FILE_PROGRESS = 19,
  HCR_EVENT_FILE_COMPLETE = 20,
  HCR_EVENT_FILE_ERROR = 21,
} hcr_event_type;

typedef struct {
  hcr_event_type type;
  const char *room;
  const char *peer;
  const char *role;
  const char *state;
  const char *description;
  const char *candidate;
  const char *mid;
  const char *channel;
  const char *text;
  const char *code;
  bool initiator;
  const uint8_t *binary;
  size_t binary_size;
  uint32_t frame_id;
  uint32_t timestamp_ms;
  bool keyframe;
  uint64_t file_size;
} hcr_event;

const char *hcr_event_type_name(hcr_event_type type);

/*
 * Returns a human-readable message for the most recent failing call on the
 * calling thread. Valid until the next failing call on the same thread.
 */
const char *hcr_last_error(void);

/*
 * Session-level API. The offerer/answerer orchestration (SDP and ICE
 * forwarding) runs inside the session, so poll_event never reports
 * LocalDescription/LocalCandidate/RemoteDescription/RemoteCandidate.
 *
 * All calls must happen on a single thread per handle (poll_event and the
 * send functions may be called from that one thread only).
 *
 * create returns NULL on failure (see hcr_last_error).
 * poll_event string and binary pointers stay valid until the next poll or
 * destroy on the same handle.
 * destroy performs close exactly once and frees the handle.
 */
hcr_session *hcr_session_create(const char *server, const char *room,
                                  const char *peer, const char *token,
                                  const char *stun);
void hcr_session_connect(hcr_session *session);
bool hcr_session_send_text(hcr_session *session, const char *channel,
                            const char *text);
bool hcr_session_send_binary(hcr_session *session, const char *channel,
                              const uint8_t *data, size_t size);
/*
 * Chunk an encoded media frame over the game channel. Reassembly is native;
 * completed frames arrive as HCR_EVENT_FRAME_MESSAGE events.
 */
bool hcr_session_send_frame(hcr_session *session, uint32_t frame_id,
                             bool keyframe, uint32_t timestamp_ms,
                             const uint8_t *data, size_t size);
/*
 * File transfer over the reliable control channel. The file is streamed in
 * the native layer; progress/completion arrive as FILE_* events.
 */
bool hcr_session_send_file(hcr_session *session, const char *path,
                           const char *name);
void hcr_session_set_download_dir(hcr_session *session, const char *path);
bool hcr_session_poll_event(hcr_session *session, hcr_event *out);
void hcr_session_close(hcr_session *session);
void hcr_session_destroy(hcr_session *session);

/*
 * Presence probe: returns how many peers are currently in the room (0..2),
 * or -1 on error/timeout. Does not join or occupy the room.
 */
int hcr_signal_probe(const char *url, const char *room, const char *token,
                      int timeout_ms);

#ifdef __cplusplus
}
#endif
