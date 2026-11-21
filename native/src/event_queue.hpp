#pragma once

#include "hcr/hcr.hpp"

#include <deque>
#include <mutex>

namespace hcr {

constexpr std::size_t maxQueuedEvents = 4096;
constexpr std::size_t maxPayloadBytes = 256 * 1024;

class EventQueue {
public:
  void push(Event event) {
    std::lock_guard lock(mutex_);
    if (events_.size() >= maxQueuedEvents) {
      events_.pop_front();
      Event overflow;
      overflow.type = EventType::QueueOverflow;
      overflow.code = "event_queue_overflow";
      events_.push_back(std::move(overflow));
      return;
    }
    events_.push_back(std::move(event));
  }

  Event poll() {
    std::lock_guard lock(mutex_);
    if (events_.empty()) {
      return {};
    }
    auto event = std::move(events_.front());
    events_.pop_front();
    return event;
  }

private:
  std::mutex mutex_;
  std::deque<Event> events_;
};

Event errorEvent(std::string code, std::string message);

} // namespace hcr
