#pragma once

#include "DiskFormat.hpp"

namespace fptn::diag {

// PR3: read and validate flight records from a ring file.
// Returns the number of valid events written to output.
// Events are ordered by sequence (ascending).
std::size_t ReadValidEvents(const char* path, Event* output,
                            std::size_t capacity) noexcept;

// PR3: read the latest valid snapshot from a double-buffered file.
// Picks the valid slot with the highest write_sequence.
bool ReadLatestSnapshot(const char* path, Snapshot& output) noexcept;

}  // namespace fptn::diag
