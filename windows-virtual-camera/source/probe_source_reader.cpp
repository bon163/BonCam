#include <Windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <strsafe.h>
#include <stdio.h>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")

static const CLSID CLSID_IPhoneCameraSource = { 0x7f812b6a, 0xca0b, 0x4e6e, { 0x8e, 0x01, 0x7a, 0x2d, 0x76, 0x7c, 0x1f, 0x24 } };

void PrintHr(const wchar_t* label, HRESULT hr) {
    wprintf(L"%s hr=0x%08X\n", label, static_cast<unsigned int>(hr));
}

void PrintMediaType(IMFMediaType* type) {
    if (!type) return;
    GUID subtype = GUID_NULL;
    UINT32 width = 0, height = 0, numerator = 0, denominator = 0;
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &width, &height);
    MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &numerator, &denominator);
    wchar_t subtypeText[64] = {};
    StringFromGUID2(subtype, subtypeText, 64);
    wprintf(L"Current media type: subtype=%s size=%ux%u fps=%u/%u\n", subtypeText, width, height, numerator, denominator);
}

// Usage: probe_source_reader.exe [nativeTypeIndex] [dumpPath]
//   nativeTypeIndex selects one of the source's native media types before reading.
//   dumpPath writes the last sample's contiguous buffer to disk for inspection.
int wmain(int argc, wchar_t** argv) {
    const int typeIndex = argc > 1 ? _wtoi(argv[1]) : -1;
    const wchar_t* dumpPath = argc > 2 ? argv[2] : nullptr;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    PrintHr(L"CoInitializeEx", hr);
    if (FAILED(hr)) return 1;

    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    PrintHr(L"MFStartup", hr);
    if (FAILED(hr)) {
        CoUninitialize();
        return 1;
    }

    IMFMediaSource* source = nullptr;
    hr = CoCreateInstance(CLSID_IPhoneCameraSource, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&source));
    PrintHr(L"CoCreateInstance source", hr);
    if (FAILED(hr)) {
        MFShutdown();
        CoUninitialize();
        return 1;
    }

    IMFSourceReader* reader = nullptr;
    hr = MFCreateSourceReaderFromMediaSource(source, nullptr, &reader);
    PrintHr(L"MFCreateSourceReaderFromMediaSource", hr);
    if (SUCCEEDED(hr)) {
        if (typeIndex >= 0) {
            IMFMediaType* nativeType = nullptr;
            HRESULT setHr = reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, static_cast<DWORD>(typeIndex), &nativeType);
            PrintHr(L"GetNativeMediaType", setHr);
            if (SUCCEEDED(setHr)) setHr = reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, nativeType);
            PrintHr(L"SetCurrentMediaType", setHr);
            if (nativeType) nativeType->Release();
        }

        IMFMediaType* currentType = nullptr;
        HRESULT typeHr = reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &currentType);
        PrintHr(L"GetCurrentMediaType", typeHr);
        UINT32 width = 0, height = 0;
        if (SUCCEEDED(typeHr)) {
            PrintMediaType(currentType);
            MFGetAttributeSize(currentType, MF_MT_FRAME_SIZE, &width, &height);
        }
        if (currentType) currentType->Release();

        for (DWORD i = 0; i < 5; ++i) {
            DWORD streamIndex = 0;
            DWORD flags = 0;
            LONGLONG timestamp = 0;
            IMFSample* sample = nullptr;
            hr = reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &streamIndex, &flags, &timestamp, &sample);
            wprintf(L"ReadSample #%u hr=0x%08X stream=%u flags=0x%08X timestamp=%lld sample=%s\n", i + 1, static_cast<unsigned int>(hr), streamIndex, flags, timestamp, sample ? L"yes" : L"no");
            if (sample && i == 4) {
                IMFMediaBuffer* buffer = nullptr;
                if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
                    BYTE* data = nullptr;
                    DWORD length = 0;
                    if (SUCCEEDED(buffer->Lock(&data, &length, nullptr))) {
                        // Luma stats over the Y plane (NV12) or the whole buffer
                        // (RGB32) catch all-black output instantly.
                        const DWORD lumaBytes = (width && height && length >= width * height) ? width * height : length;
                        BYTE lumaMin = 255, lumaMax = 0;
                        unsigned long long lumaSum = 0;
                        for (DWORD b = 0; b < lumaBytes; ++b) {
                            if (data[b] < lumaMin) lumaMin = data[b];
                            if (data[b] > lumaMax) lumaMax = data[b];
                            lumaSum += data[b];
                        }
                        wprintf(L"Sample bytes=%u lumaMin=%u lumaMax=%u lumaAvg=%llu\n", length, lumaMin, lumaMax, lumaBytes ? lumaSum / lumaBytes : 0);
                        if (dumpPath) {
                            FILE* dump = nullptr;
                            if (_wfopen_s(&dump, dumpPath, L"wb") == 0 && dump) {
                                fwrite(data, 1, length, dump);
                                fclose(dump);
                                wprintf(L"Dumped sample to %s\n", dumpPath);
                            }
                        }
                        buffer->Unlock();
                    }
                    buffer->Release();
                }
            }
            if (sample) sample->Release();
            if (FAILED(hr)) break;
        }
    }

    if (reader) reader->Release();
    source->Shutdown();
    source->Release();
    MFShutdown();
    CoUninitialize();
    return FAILED(hr) ? 1 : 0;
}
