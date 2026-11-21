#include "hcr/hcr_c.h"

#include "hcr/hcr.hpp"

#include <exception>
#include <string>
#include <vector>

namespace {

thread_local std::string lastError;

void setError(const std::exception &error) { lastError = error.what(); }

hcr_event toCEvent(const hcr::Event &event) {
  hcr_event out{};
  out.type = static_cast<hcr_event_type>(event.type);
  out.room = event.room.c_str();
  out.peer = event.peer.c_str();
  out.role = event.role.c_str();
  out.state = event.state.c_str();
  out.description = event.description.c_str();
  out.candidate = event.candidate.c_str();
  out.mid = event.mid.c_str();
  out.channel = event.channel.c_str();
  out.text = event.text.c_str();
  out.code = event.code.c_str();
  out.initiator = event.initiator;
  out.binary = reinterpret_cast<const uint8_t *>(event.binary.data());
  out.binary_size = event.binary.size();
  out.frame_id = event.frameId;
  out.timestamp_ms = event.timestampMs;
  out.keyframe = event.keyframe;
  return out;
}

} // namespace

struct hcr_session {
  explicit hcr_session(hcr::SessionConfig config)
      : session(std::move(config)) {}
  hcr::Session session;
  hcr::Event last;
  bool closed = false;
};

extern "C" {

const char *hcr_event_type_name(hcr_event_type type) {
  return hcr::eventName(static_cast<hcr::EventType>(type));
}

const char *hcr_last_error(void) { return lastError.c_str(); }

hcr_session *hcr_session_create(const char *server, const char *room,
                                  const char *peer, const char *token,
                                  const char *stun) {
  if (!server || !room || !peer) {
    lastError = "server, room and peer are required";
    return nullptr;
  }
  try {
    hcr::SessionConfig config;
    config.server = server;
    config.room = room;
    config.peer = peer;
    config.token = token ? token : "";
    config.stun = stun ? stun : "";
    return new hcr_session(std::move(config));
  } catch (const std::exception &error) {
    setError(error);
    return nullptr;
  }
}

void hcr_session_connect(hcr_session *session) {
  if (session) {
    try {
      session->session.connect();
    } catch (const std::exception &error) {
      setError(error);
    }
  }
}

bool hcr_session_send_text(hcr_session *session, const char *channel,
                            const char *text) {
  if (!session || !channel || !text) {
    return false;
  }
  try {
    return session->session.sendText(channel, text);
  } catch (const std::exception &error) {
    setError(error);
    return false;
  }
}

bool hcr_session_send_binary(hcr_session *session, const char *channel,
                              const uint8_t *data, size_t size) {
  if (!session || !channel || (!data && size > 0)) {
    return false;
  }
  std::vector<std::byte> bytes(size);
  for (size_t i = 0; i < size; ++i) {
    bytes[i] = static_cast<std::byte>(data[i]);
  }
  try {
    return session->session.sendBinary(channel, bytes);
  } catch (const std::exception &error) {
    setError(error);
    return false;
  }
}

bool hcr_session_send_frame(hcr_session *session, uint32_t frame_id,
                             bool keyframe, uint32_t timestamp_ms,
                             const uint8_t *data, size_t size) {
  if (!session || (!data && size > 0)) {
    return false;
  }
  std::vector<std::byte> bytes(size);
  for (size_t i = 0; i < size; ++i) {
    bytes[i] = static_cast<std::byte>(data[i]);
  }
  try {
    return session->session.sendFrame(frame_id, keyframe, timestamp_ms, bytes);
  } catch (const std::exception &error) {
    setError(error);
    return false;
  }
}

bool hcr_session_poll_event(hcr_session *session, hcr_event *out) {
  if (!session || !out) {
    return false;
  }
  try {
    session->last = session->session.pollEvent();
  } catch (const std::exception &error) {
    setError(error);
    return false;
  }
  if (session->last.type == hcr::EventType::None) {
    return false;
  }
  *out = toCEvent(session->last);
  return true;
}

void hcr_session_close(hcr_session *session) {
  if (session && !session->closed) {
    session->closed = true;
    try {
      session->session.close();
    } catch (const std::exception &error) {
      setError(error);
    }
  }
}

void hcr_session_destroy(hcr_session *session) {
  if (!session) {
    return;
  }
  hcr_session_close(session);
  delete session;
}

int hcr_signal_probe(const char *url, const char *room, const char *token,
                      int timeout_ms) {
  if (!url || !room) {
    lastError = "url and room are required";
    return -1;
  }
  try {
    return hcr::probeRoom(url, room, token ? token : "",
                           timeout_ms > 0 ? timeout_ms : 3000);
  } catch (const std::exception &error) {
    setError(error);
    return -1;
  }
}

} // extern "C"
