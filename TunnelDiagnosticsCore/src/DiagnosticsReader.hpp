#pragma once

#include "DiskFormat.hpp"

namespace fptn::diag {

enum class ReadStatus : int {
  kOk = 0,
  kFileNotFound = 1,
  kInvalidHeader = 2,
  kEmpty = 3,
  kIoError = 4,
};

ReadStatus ReadValidEvents(const char* path, Event* output,
                           std::size_t capacity,
                           std::size_t* output_count) noexcept;

ReadStatus ReadLatestSnapshot(const char* path, Snapshot& output) noexcept;

}  // namespace fptn::diag
