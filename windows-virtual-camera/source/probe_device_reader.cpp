// Enumerates video capture devices like a real app (through the Windows
// camera frame server) and reads samples from the "iPhone Camera" virtual
// camera. This exercises the same path Discord/Windows Camera use, unlike
// probe_source_reader.exe which instantiates the source in-process.
#include <Windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <iostream>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")

int wmain() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::wcout << L"CoInitializeEx hr=0x" << std::hex << hr << std::dec << std::endl;
    hr = MFStartup(MF_VERSION);
    std::wcout << L"MFStartup hr=0x" << std::hex << hr << std::dec << std::endl;

    IMFAttributes* attributes = nullptr;
    hr = MFCreateAttributes(&attributes, 1);
    if (SUCCEEDED(hr)) hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    hr = MFEnumDeviceSources(attributes, &devices, &count);
    std::wcout << L"MFEnumDeviceSources hr=0x" << std::hex << hr << std::dec << L" count=" << count << std::endl;

    IMFActivate* target = nullptr;
    for (UINT32 i = 0; i < count; ++i) {
        WCHAR* name = nullptr;
        UINT32 length = 0;
        if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length))) {
            std::wcout << L"Device " << i << L": " << name << std::endl;
            if (wcsstr(name, L"iPhone Camera") && !target) {
                target = devices[i];
                target->AddRef();
            }
            CoTaskMemFree(name);
        }
    }

    if (!target) {
        std::wcout << L"iPhone Camera not found in device enumeration." << std::endl;
        return 1;
    }

    IMFMediaSource* source = nullptr;
    hr = target->ActivateObject(IID_PPV_ARGS(&source));
    std::wcout << L"ActivateObject hr=0x" << std::hex << hr << std::dec << std::endl;
    if (FAILED(hr)) return 1;

    IMFSourceReader* reader = nullptr;
    hr = MFCreateSourceReaderFromMediaSource(source, nullptr, &reader);
    std::wcout << L"MFCreateSourceReaderFromMediaSource hr=0x" << std::hex << hr << std::dec << std::endl;
    if (FAILED(hr)) return 1;

    IMFMediaType* mediaType = nullptr;
    hr = reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &mediaType);
    if (SUCCEEDED(hr)) {
        GUID subtype = GUID_NULL;
        UINT32 width = 0, height = 0, num = 0, den = 0;
        mediaType->GetGUID(MF_MT_SUBTYPE, &subtype);
        MFGetAttributeSize(mediaType, MF_MT_FRAME_SIZE, &width, &height);
        MFGetAttributeRatio(mediaType, MF_MT_FRAME_RATE, &num, &den);
        WCHAR text[64] = {};
        StringFromGUID2(subtype, text, 64);
        std::wcout << L"Current media type: subtype=" << text << L" size=" << width << L"x" << height << L" fps=" << num << L"/" << den << std::endl;
        mediaType->Release();
    }

    LONGLONG previous = 0;
    for (int i = 1; i <= 20; ++i) {
        DWORD streamIndex = 0, flags = 0;
        LONGLONG timestamp = 0;
        IMFSample* sample = nullptr;
        hr = reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &streamIndex, &flags, &timestamp, &sample);
        DWORD totalLength = 0;
        if (sample) sample->GetTotalLength(&totalLength);
        // Luma statistics over the Y plane so an all-black or garbage frame is
        // obvious from the console (avg 16 = black; a real image varies).
        unsigned int lumaMin = 255, lumaMax = 0;
        unsigned long long lumaSum = 0;
        DWORD lumaCount = 0;
        if (sample) {
            IMFMediaBuffer* contiguous = nullptr;
            if (SUCCEEDED(sample->ConvertToContiguousBuffer(&contiguous))) {
                BYTE* data = nullptr;
                DWORD length = 0;
                if (SUCCEEDED(contiguous->Lock(&data, nullptr, &length))) {
                    lumaCount = length * 2 / 3; // NV12: Y plane is 2/3 of the buffer
                    if (lumaCount > length) lumaCount = length;
                    for (DWORD offset = 0; offset < lumaCount; offset += 97) {
                        const unsigned int value = data[offset];
                        if (value < lumaMin) lumaMin = value;
                        if (value > lumaMax) lumaMax = value;
                        lumaSum += value;
                    }
                    lumaCount = (lumaCount + 96) / 97;
                    contiguous->Unlock();
                }
                contiguous->Release();
            }
        }
        std::wcout << L"ReadSample #" << i << L" hr=0x" << std::hex << hr << std::dec
                   << L" flags=0x" << std::hex << flags << std::dec
                   << L" timestamp=" << timestamp
                   << L" delta=" << (previous ? timestamp - previous : 0)
                   << L" bytes=" << totalLength
                   << L" sample=" << (sample ? L"yes" : L"no");
        if (lumaCount) {
            std::wcout << L" lumaMin=" << lumaMin << L" lumaMax=" << lumaMax << L" lumaAvg=" << (lumaSum / lumaCount);
        }
        std::wcout << std::endl;
        previous = timestamp;
        if (sample) sample->Release();
        if (FAILED(hr)) break;
    }

    reader->Release();
    source->Release();
    target->Release();
    for (UINT32 i = 0; i < count; ++i) devices[i]->Release();
    CoTaskMemFree(devices);
    if (attributes) attributes->Release();
    MFShutdown();
    CoUninitialize();
    return 0;
}
