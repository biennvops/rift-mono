#include "windows_image_utils.h"

#include <objidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <limits>

namespace {

bool ReadStream(IStream* stream,
                size_t max_output_bytes,
                std::vector<uint8_t>* output) {
  if (stream == nullptr || output == nullptr) {
    return false;
  }

  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME)) ||
      stat.cbSize.QuadPart < 0 ||
      static_cast<ULONGLONG>(stat.cbSize.QuadPart) > max_output_bytes ||
      static_cast<ULONGLONG>(stat.cbSize.QuadPart) >
          std::numeric_limits<size_t>::max() ||
      stat.cbSize.QuadPart > std::numeric_limits<ULONG>::max()) {
    return false;
  }

  LARGE_INTEGER origin = {};
  if (FAILED(stream->Seek(origin, STREAM_SEEK_SET, nullptr))) {
    return false;
  }

  output->resize(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG bytes_read = 0;
  if (FAILED(stream->Read(output->data(),
                          static_cast<ULONG>(output->size()), &bytes_read)) ||
      bytes_read != output->size()) {
    output->clear();
    return false;
  }
  return true;
}

}  // namespace

bool NormalizeImageToPng(const std::vector<uint8_t>& input,
                         uint32_t max_dimension,
                         size_t max_output_bytes,
                         std::vector<uint8_t>* output) {
  if (input.empty() || output == nullptr ||
      input.size() > std::numeric_limits<DWORD>::max()) {
    return false;
  }
  output->clear();

  Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return false;
  }

  Microsoft::WRL::ComPtr<IWICStream> input_stream;
  if (FAILED(factory->CreateStream(&input_stream)) ||
      FAILED(input_stream->InitializeFromMemory(
          const_cast<BYTE*>(input.data()),
          static_cast<DWORD>(input.size())))) {
    return false;
  }

  Microsoft::WRL::ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          input_stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad,
          &decoder))) {
    return false;
  }

  Microsoft::WRL::ComPtr<IWICBitmapFrameDecode> frame;
  Microsoft::WRL::ComPtr<IWICFormatConverter> converter;
  if (FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(
          frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
          nullptr, 0.0, WICBitmapPaletteTypeCustom))) {
    return false;
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 ||
      height == 0 || width > max_dimension || height > max_dimension) {
    return false;
  }

  Microsoft::WRL::ComPtr<IStream> output_stream;
  Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &output_stream)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    &encoder)) ||
      FAILED(encoder->Initialize(output_stream.Get(),
                                 WICBitmapEncoderNoCache))) {
    return false;
  }

  Microsoft::WRL::ComPtr<IWICBitmapFrameEncode> output_frame;
  Microsoft::WRL::ComPtr<IPropertyBag2> properties;
  if (FAILED(encoder->CreateNewFrame(&output_frame, &properties)) ||
      FAILED(output_frame->Initialize(properties.Get())) ||
      FAILED(output_frame->SetSize(width, height))) {
    return false;
  }

  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(output_frame->SetPixelFormat(&pixel_format)) ||
      pixel_format != GUID_WICPixelFormat32bppBGRA ||
      FAILED(output_frame->WriteSource(converter.Get(), nullptr)) ||
      FAILED(output_frame->Commit()) ||
      FAILED(encoder->Commit())) {
    return false;
  }

  return ReadStream(output_stream.Get(), max_output_bytes, output);
}
