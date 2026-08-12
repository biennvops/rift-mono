#ifndef RUNNER_WINDOWS_IMAGE_UTILS_H_
#define RUNNER_WINDOWS_IMAGE_UTILS_H_

#include <cstddef>
#include <cstdint>
#include <vector>

// Decodes an image with WIC and writes a canonical PNG. The decoded image must
// fit within max_dimension in both directions and the encoded output must not
// exceed max_output_bytes.
bool NormalizeImageToPng(const std::vector<uint8_t>& input,
                         uint32_t max_dimension,
                         size_t max_output_bytes,
                         std::vector<uint8_t>* output);

#endif  // RUNNER_WINDOWS_IMAGE_UTILS_H_
