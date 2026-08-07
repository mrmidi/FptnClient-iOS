/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

#include "FPTNAppleLogSink.h"

#include <os/log.h>

#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>

#include <spdlog/sinks/base_sink.h>
#include <spdlog/spdlog.h>

namespace {

constexpr const char* kSubsystem = "org.fptn";

// One os_log_t per spdlog logger name. Apple's guidance is to keep the number
// of subsystem/category pairs small -- one subsystem and a handful of
// categories -- so these are created lazily and cached forever.
os_log_t LogForCategory(const std::string& category) {
  static std::mutex mutex;
  static std::unordered_map<std::string, os_log_t> cache;

  std::lock_guard<std::mutex> lock(mutex);
  auto found = cache.find(category);
  if (found != cache.end()) {
    return found->second;
  }
  os_log_t handle =
      os_log_create(kSubsystem, category.empty() ? "native" : category.c_str());
  cache.emplace(category, handle);
  return handle;
}

// This is a VPN: addresses and credentials must not reach the log store, which
// persists for days and ships inside a sysdiagnose. Redacting here rather than
// tagging fields %{private} means the entries stay readable without the
// Apple logging profile installed, which is what makes them useful in
// Console.app during ordinary debugging.
std::string Redact(std::string text) {
  // Constructed once: std::regex compilation is expensive and this runs per
  // log line.
  static const std::regex kSecret(
      R"((access_token|token|password|authorization)(\s*[=:]\s*)\S+)",
      std::regex::icase | std::regex::optimize);
  try {
    return std::regex_replace(text, kSecret, "$1$2<redacted>");
  } catch (...) {
    // A regex failure must never cost us the log line.
    return text;
  }
}

template <typename Mutex>
class AppleOsLogSink final : public spdlog::sinks::base_sink<Mutex> {
 protected:
  void sink_it_(const spdlog::details::log_msg& msg) override {
    const std::string category(msg.logger_name.data(), msg.logger_name.size());
    const os_log_t handle = LogForCategory(category);

    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    switch (msg.level) {
      case spdlog::level::trace:
      case spdlog::level::debug:
        type = OS_LOG_TYPE_DEBUG;
        break;
      case spdlog::level::info:
        type = OS_LOG_TYPE_INFO;
        break;
      case spdlog::level::warn:
      case spdlog::level::err:
        type = OS_LOG_TYPE_ERROR;
        break;
      case spdlog::level::critical:
        type = OS_LOG_TYPE_FAULT;
        break;
      default:
        type = OS_LOG_TYPE_DEFAULT;
        break;
    }

    // Skip the work entirely when nothing is listening for this level.
    if (!os_log_type_enabled(handle, type)) {
      return;
    }

    const std::string text =
        Redact(std::string(msg.payload.data(), msg.payload.size()));
    os_log_with_type(handle, type, "%{public}s", text.c_str());
  }

  void flush_() override {}
};

std::once_flag g_install_once;

}  // namespace

void FPTNInstallAppleLogSink(void) {
  std::call_once(g_install_once, [] {
    try {
      auto sink = std::make_shared<AppleOsLogSink<std::mutex>>();
      auto logger = std::make_shared<spdlog::logger>("fptn", sink);
      // The unified log records its own timestamps, process and category, so
      // the pattern carries only what it adds: source location and the text.
      logger->set_pattern("%s:%# %v");
      logger->set_level(spdlog::level::info);
      logger->flush_on(spdlog::level::err);
      spdlog::set_default_logger(logger);
      spdlog::set_level(spdlog::level::info);
    } catch (...) {
      // Logging must never be the reason the tunnel fails to start.
    }
  });
}

void FPTNSetAppleLogLevel(const char* level) {
  if (level == nullptr) {
    return;
  }
  const std::string value(level);
  spdlog::level::level_enum parsed = spdlog::level::info;
  if (value == "trace") {
    parsed = spdlog::level::trace;
  } else if (value == "debug") {
    parsed = spdlog::level::debug;
  } else if (value == "info") {
    parsed = spdlog::level::info;
  } else if (value == "warning" || value == "warn") {
    parsed = spdlog::level::warn;
  } else {
    return;
  }
  try {
    spdlog::set_level(parsed);
    if (auto logger = spdlog::default_logger()) {
      logger->set_level(parsed);
    }
  } catch (...) {
  }
}
