#include <Windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksmedia.h>
#include <ksproxy.h>
#include <strsafe.h>
#include <propvarutil.h>
#include <atomic>
#include <new>
#include <stdio.h>
#include <stdarg.h>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "propsys.lib")
#pragma comment(lib, "advapi32.lib")

static const CLSID CLSID_IPhoneCameraSource = { 0x7f812b6a, 0xca0b, 0x4e6e, { 0x8e, 0x01, 0x7a, 0x2d, 0x76, 0x7c, 0x1f, 0x24 } };
// The camera exposes portrait 720x1280 and landscape 1280x720. Portrait NV12 stays
// media type 0: Discord is verified working against that default.
static constexpr UINT32 PORTRAIT_WIDTH = 720;
static constexpr UINT32 PORTRAIT_HEIGHT = 1280;
static constexpr UINT32 LANDSCAPE_WIDTH = 1280;
static constexpr UINT32 LANDSCAPE_HEIGHT = 720;
// Both orientations pack to the same RGBA byte count.
static constexpr UINT32 MAX_RGBA_BYTES = PORTRAIT_WIDTH * PORTRAIT_HEIGHT * 4;
static constexpr UINT32 LEGACY_RGBA_BYTES = MAX_RGBA_BYTES;
static constexpr UINT32 FRAME_RATE = 30;
static constexpr LONGLONG FRAME_DURATION = 10000000 / FRAME_RATE;
static constexpr wchar_t SHARED_FRAME_PATH[] = L"C:\\ProgramData\\IPhoneCameraStreaming\\latest.rgba";
// latest.rgba: 16-byte header (magic "IPCF", width, height, stride as LE u32) then
// tightly packed RGBA. Headerless files are the legacy fixed portrait layout.
static constexpr UINT32 SHARED_HEADER_BYTES = 16;
static constexpr BYTE SHARED_FRAME_MAGIC[4] = { 'I', 'P', 'C', 'F' };
// If latest.rgba has not been rewritten for this long, the phone/host stream has
// dropped and we are about to serve a frozen image forever. Past this age the
// last good frame is shown darkened with a "signal lost" overlay instead, so the
// stall is visible in-camera (Discord, Windows Camera, ...) and self-heals when
// fresh frames resume. Matches the host's own 3s raw-frame stall threshold.
static constexpr ULONGLONG STALE_FRAME_THRESHOLD_MS = 3000;
static std::atomic<long> g_objectCount = 0;
static std::atomic<long> g_lockCount = 0;
static HMODULE g_module = nullptr;

void LogLine(const wchar_t* message) {
    wchar_t modulePath[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_module, modulePath, MAX_PATH)) return;
    wchar_t* slash = wcsrchr(modulePath, L'\\');
    if (slash) *(slash + 1) = L'\0';
    wchar_t logPath[MAX_PATH] = {};
    StringCchCopyW(logPath, MAX_PATH, modulePath);
    StringCchCatW(logPath, MAX_PATH, L"iphone_camera_source.log");
    static wchar_t processName[64] = {};
    if (!processName[0]) {
        wchar_t exePath[MAX_PATH] = {};
        GetModuleFileNameW(nullptr, exePath, MAX_PATH);
        const wchar_t* exeName = wcsrchr(exePath, L'\\');
        StringCchCopyW(processName, 64, exeName ? exeName + 1 : exePath);
    }
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    FILE* file = nullptr;
    if (_wfopen_s(&file, logPath, L"a, ccs=UTF-8") != 0 || !file) return;
    fwprintf(file, L"%02u-%02u %02u:%02u:%02u.%03u [%lu %s] %s\n",
        st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
        GetCurrentProcessId(), processName, message);
    fclose(file);
}

void LogFormat(const wchar_t* format, ...) {
    wchar_t line[512] = {};
    va_list args;
    va_start(args, format);
    StringCchVPrintfW(line, 512, format, args);
    va_end(args);
    LogLine(line);
}

const wchar_t* KnownGuidName(REFGUID guid) {
    if (guid == IID_IUnknown) return L"IID_IUnknown";
    if (guid == IID_IClassFactory) return L"IID_IClassFactory";
    if (guid == __uuidof(IMFActivate)) return L"IID_IMFActivate";
    if (guid == __uuidof(IMFAttributes)) return L"IID_IMFAttributes";
    if (guid == __uuidof(IMFMediaEventGenerator)) return L"IID_IMFMediaEventGenerator";
    if (guid == __uuidof(IMFMediaSource)) return L"IID_IMFMediaSource";
    if (guid == __uuidof(IMFMediaSourceEx)) return L"IID_IMFMediaSourceEx";
    if (guid == __uuidof(IMFMediaSource2)) return L"IID_IMFMediaSource2";
    if (guid == __uuidof(IMFMediaStream)) return L"IID_IMFMediaStream";
    if (guid == __uuidof(IMFMediaStream2)) return L"IID_IMFMediaStream2";
    if (guid == __uuidof(IMFSampleAllocatorControl)) return L"IID_IMFSampleAllocatorControl";
    if (guid == __uuidof(IMFGetService)) return L"IID_IMFGetService";
    if (guid == __uuidof(IMFRealTimeClient)) return L"IID_IMFRealTimeClient";
    if (guid == __uuidof(IMFRealTimeClientEx)) return L"IID_IMFRealTimeClientEx";
    if (guid == __uuidof(IMFCollection)) return L"IID_IMFCollection";
    if (guid == __uuidof(IMFExtendedCameraController)) return L"IID_IMFExtendedCameraController";
    if (guid == __uuidof(IMFExtendedCameraControl)) return L"IID_IMFExtendedCameraControl";
    if (guid == __uuidof(IKsControl)) return L"IID_IKsControl";
    if (guid == MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES) return L"MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES";
    if (guid == MF_VIRTUALCAMERA_ASSOCIATED_CAMERA_SOURCES) return L"MF_VIRTUALCAMERA_ASSOCIATED_CAMERA_SOURCES";
    if (guid == MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME) return L"MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME";
    if (guid == MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE) return L"MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE";
    if (guid == MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID) return L"MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID";
    if (guid == MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY) return L"MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY";
    if (guid == MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_PROVIDER_DEVICE_ID) return L"MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_PROVIDER_DEVICE_ID";
    if (guid == MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_MAX_BUFFERS) return L"MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_MAX_BUFFERS";
    if (guid == MF_LOW_LATENCY) return L"MF_LOW_LATENCY";
    if (guid == MF_DEVICESTREAM_STREAM_CATEGORY) return L"MF_DEVICESTREAM_STREAM_CATEGORY";
    if (guid == MF_DEVICESTREAM_STREAM_ID) return L"MF_DEVICESTREAM_STREAM_ID";
    if (guid == MF_DEVICESTREAM_FRAMESERVER_SHARED) return L"MF_DEVICESTREAM_FRAMESERVER_SHARED";
    if (guid == MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES) return L"MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES";
    if (guid == MF_SD_STREAM_NAME) return L"MF_SD_STREAM_NAME";
    if (guid == MF_MT_MAJOR_TYPE) return L"MF_MT_MAJOR_TYPE";
    if (guid == MF_MT_SUBTYPE) return L"MF_MT_SUBTYPE";
    if (guid == MF_MT_FRAME_SIZE) return L"MF_MT_FRAME_SIZE";
    if (guid == MF_MT_FRAME_RATE) return L"MF_MT_FRAME_RATE";
    if (guid == MF_MT_PIXEL_ASPECT_RATIO) return L"MF_MT_PIXEL_ASPECT_RATIO";
    if (guid == MF_MT_INTERLACE_MODE) return L"MF_MT_INTERLACE_MODE";
    if (guid == MF_MT_ALL_SAMPLES_INDEPENDENT) return L"MF_MT_ALL_SAMPLES_INDEPENDENT";
    if (guid == MF_MT_FIXED_SIZE_SAMPLES) return L"MF_MT_FIXED_SIZE_SAMPLES";
    if (guid == MF_MT_SAMPLE_SIZE) return L"MF_MT_SAMPLE_SIZE";
    if (guid == MF_MT_DEFAULT_STRIDE) return L"MF_MT_DEFAULT_STRIDE";
    if (guid == PINNAME_VIDEO_CAPTURE) return L"PINNAME_VIDEO_CAPTURE";
    if (guid == PROPSETID_VIDCAP_CAMERACONTROL) return L"PROPSETID_VIDCAP_CAMERACONTROL";
    return L"";
}

void LogGuid(const wchar_t* prefix, REFGUID guid) {
    wchar_t guidText[64] = {};
    StringFromGUID2(guid, guidText, 64);
    const wchar_t* name = KnownGuidName(guid);
    if (name && name[0]) {
        LogFormat(L"%s %s %s", prefix, name, guidText);
    } else {
        LogFormat(L"%s %s", prefix, guidText);
    }
}

void LogHResult(const wchar_t* prefix, HRESULT hr) {
    LogFormat(L"%s hr=0x%08X", prefix, static_cast<unsigned int>(hr));
}

void LogPropVariant(const wchar_t* prefix, const PROPVARIANT& value) {
    switch (value.vt) {
    case VT_UI4:
        LogFormat(L"%s vt=VT_UI4 value=%u", prefix, value.ulVal);
        break;
    case VT_UI8:
        LogFormat(L"%s vt=VT_UI8 value=%llu", prefix, value.uhVal.QuadPart);
        break;
    case VT_LPWSTR:
        LogFormat(L"%s vt=VT_LPWSTR value=\"%s\"", prefix, value.pwszVal ? value.pwszVal : L"");
        break;
    case VT_CLSID:
        if (value.puuid) {
            LogGuid(prefix, *value.puuid);
        } else {
            LogFormat(L"%s vt=VT_CLSID value=null", prefix);
        }
        break;
    default:
        LogFormat(L"%s vt=%u", prefix, value.vt);
        break;
    }
}

void LogAttributes(const wchar_t* label, IMFAttributes* attributes) {
    if (!attributes) {
        LogFormat(L"%s attributes=null", label);
        return;
    }

    UINT32 count = 0;
    HRESULT hr = attributes->GetCount(&count);
    if (FAILED(hr)) {
        LogHResult(label, hr);
        return;
    }

    LogFormat(L"%s count=%u", label, count);
    for (UINT32 index = 0; index < count; ++index) {
        GUID key = GUID_NULL;
        PROPVARIANT value;
        PropVariantInit(&value);
        hr = attributes->GetItemByIndex(index, &key, &value);
        if (SUCCEEDED(hr)) {
            LogGuid(L"  key", key);
            LogPropVariant(L"  value", value);
        } else {
            LogHResult(L"  GetItemByIndex", hr);
        }
        PropVariantClear(&value);
    }
}

HRESULT CreateVideoMediaType(REFGUID subtype, UINT32 width, UINT32 height, IMFMediaType** mediaType) {
    if (!mediaType) return E_POINTER;
    *mediaType = nullptr;
    const bool rgb32 = subtype == MFVideoFormat_RGB32;
    const UINT32 sampleSize = rgb32 ? width * height * 4 : width * height * 3 / 2;
    const UINT32 stride = rgb32 ? width * 4 : width;
    IMFMediaType* created = nullptr;
    HRESULT hr = MFCreateMediaType(&created);
    if (SUCCEEDED(hr)) hr = created->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = created->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = MFSetAttributeSize(created, MF_MT_FRAME_SIZE, width, height);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(created, MF_MT_FRAME_RATE, FRAME_RATE, 1);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(created, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
    if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_MT_SAMPLE_SIZE, sampleSize);
    if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_MT_DEFAULT_STRIDE, stride);
    if (SUCCEEDED(hr)) {
        *mediaType = created;
        created = nullptr;
    }
    if (created) created->Release();
    LogHResult(L"CreateVideoMediaType", hr);
    if (SUCCEEDED(hr) && *mediaType) LogAttributes(L"CreateVideoMediaType attributes", *mediaType);
    return hr;
}


class IPhoneCameraStream final : public IMFMediaStream2 {
public:
    explicit IPhoneCameraStream(IMFMediaSource* source) : refCount_(1), source_(source) {
        g_objectCount.fetch_add(1);
        if (source_) source_->AddRef();
        MFCreateEventQueue(&eventQueue_);
        CreateDescriptor();
    }

    ~IPhoneCameraStream() {
        if (allocator_) allocator_->Release();
        if (descriptor_) descriptor_->Release();
        if (eventQueue_) eventQueue_->Release();
        if (source_) source_->Release();
        g_objectCount.fetch_sub(1);
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (riid != __uuidof(IMFMediaStream) && riid != __uuidof(IMFMediaEventGenerator)) LogGuid(L"IPhoneCameraStream::QueryInterface", riid);
        if (!object) return E_POINTER;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == __uuidof(IMFMediaEventGenerator) || riid == __uuidof(IMFMediaStream) || riid == __uuidof(IMFMediaStream2)) {
            *object = static_cast<IMFMediaStream2*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(refCount_.fetch_add(1) + 1); }
    STDMETHODIMP_(ULONG) Release() override {
        const ULONG count = static_cast<ULONG>(refCount_.fetch_sub(1) - 1);
        if (count == 0) delete this;
        return count;
    }

    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override { return eventQueue_ ? eventQueue_->GetEvent(flags, event) : MF_E_SHUTDOWN; }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override { return eventQueue_ ? eventQueue_->BeginGetEvent(callback, state) : MF_E_SHUTDOWN; }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override { return eventQueue_ ? eventQueue_->EndGetEvent(result, event) : MF_E_SHUTDOWN; }
    STDMETHODIMP QueueEvent(MediaEventType type, REFGUID extendedType, HRESULT status, const PROPVARIANT* value) override {
        return eventQueue_ ? eventQueue_->QueueEventParamVar(type, extendedType, status, value) : MF_E_SHUTDOWN;
    }

    STDMETHODIMP GetMediaSource(IMFMediaSource** source) override {
        if (!source) return E_POINTER;
        *source = source_;
        if (source_) source_->AddRef();
        return source_ ? S_OK : MF_E_SHUTDOWN;
    }

    STDMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** descriptor) override {
        if (!descriptor) return E_POINTER;
        *descriptor = descriptor_;
        if (descriptor_) descriptor_->AddRef();
        return descriptor_ ? S_OK : E_FAIL;
    }

    STDMETHODIMP RequestSample(IUnknown* token) override {
        requestedSamples_ += 1;
        if (requestedSamples_ <= 10 || requestedSamples_ % 60 == 0) {
            wchar_t line[128] = {};
            StringCchPrintfW(line, 128, L"IPhoneCameraStream::RequestSample #%llu", requestedSamples_);
            LogLine(line);
        }
        const bool rgb32 = currentSubtype_ == MFVideoFormat_RGB32;
        const UINT32 outWidth = outputWidth_;
        const UINT32 outHeight = outputHeight_;
        const DWORD frameBytes = rgb32 ? outWidth * outHeight * 4 : outWidth * outHeight * 3 / 2;

        BYTE* fileBuffer = new (std::nothrow) BYTE[SHARED_HEADER_BYTES + MAX_RGBA_BYTES];
        BYTE* fitBuffer = nullptr;
        const BYTE* sharedPixels = nullptr;
        UINT32 sharedWidth = 0;
        UINT32 sharedHeight = 0;
        ULONGLONG fileAgeMs = 0;
        // liveRgba points into one of our own writable heap buffers (fileBuffer or
        // fitBuffer), so the stale overlay below can composite over it in place.
        BYTE* liveRgba = nullptr;
        if (fileBuffer && LoadSharedRgba(fileBuffer, &sharedPixels, &sharedWidth, &sharedHeight, &fileAgeMs)) {
            if (sharedWidth == outWidth && sharedHeight == outHeight) {
                liveRgba = const_cast<BYTE*>(sharedPixels);
            } else {
                // Shared frame orientation differs from the negotiated output
                // (e.g. the phone rotated mid-stream): aspect-fit with black bars.
                fitBuffer = new (std::nothrow) BYTE[outWidth * outHeight * 4];
                if (fitBuffer) {
                    FitRgba(sharedPixels, sharedWidth, sharedHeight, fitBuffer, outWidth, outHeight);
                    liveRgba = fitBuffer;
                }
            }
        }
        // The stream has dropped if the last good frame has gone stale. Rather
        // than serve that frozen image forever, dim it and draw a "signal lost"
        // overlay so the stall is obvious in-camera; it clears itself the moment
        // the host writes a fresh frame again.
        const bool stale = liveRgba && fileAgeMs >= STALE_FRAME_THRESHOLD_MS;
        if (stale) {
            ApplyStaleOverlay(liveRgba, outWidth, outHeight, GetTickCount64());
            if (!stale_) LogFormat(L"IPhoneCameraStream::FillFrame stream STALE age=%llums, showing signal-lost overlay", fileAgeMs);
            stale_ = true;
        } else if (liveRgba) {
            if (stale_) LogLine(L"IPhoneCameraStream::FillFrame stream RECOVERED, live frames resumed");
            stale_ = false;
        }
        if (!liveRgba && !loggedFallback_) {
            LogLine(L"IPhoneCameraStream::FillFrame using fallback pattern");
            loggedFallback_ = true;
        }

        IMFSample* sample = nullptr;
        HRESULT hr = E_FAIL;
        if (allocator_) {
            hr = allocator_->AllocateSample(&sample);
            if (SUCCEEDED(hr)) {
                hr = WriteFrameToSample(sample, rgb32, liveRgba, frameBytes, outWidth, outHeight);
                if (FAILED(hr)) {
                    sample->Release();
                    sample = nullptr;
                }
            }
            if (FAILED(hr) && !loggedAllocatorFallback_) {
                LogHResult(L"IPhoneCameraStream::RequestSample allocator path failed, using memory buffers", hr);
                loggedAllocatorFallback_ = true;
            }
        }
        if (!sample) {
            IMFMediaBuffer* buffer = nullptr;
            hr = MFCreateSample(&sample);
            if (SUCCEEDED(hr)) hr = MFCreateMemoryBuffer(frameBytes, &buffer);
            BYTE* dest = nullptr;
            DWORD maxLength = 0;
            if (SUCCEEDED(hr)) hr = buffer->Lock(&dest, &maxLength, nullptr);
            if (SUCCEEDED(hr)) {
                if (maxLength >= frameBytes) {
                    WritePixels(rgb32, liveRgba, dest, rgb32 ? static_cast<LONG>(outWidth * 4) : static_cast<LONG>(outWidth), outWidth, outHeight);
                } else {
                    hr = E_FAIL;
                }
                buffer->Unlock();
                if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(frameBytes);
            }
            if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer);
            if (buffer) buffer->Release();
        }
        delete[] fitBuffer;
        delete[] fileBuffer;
        if (SUCCEEDED(hr)) hr = sample->SetSampleTime(MFGetSystemTime());
        if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(FRAME_DURATION);
        if (SUCCEEDED(hr) && token) hr = sample->SetUnknown(MFSampleExtension_Token, token);
        if (SUCCEEDED(hr)) hr = eventQueue_->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample);
        if (sample) sample->Release();
        return hr;
    }

    HRESULT SetAllocator(IUnknown* allocator) {
        if (allocator_) {
            allocator_->Release();
            allocator_ = nullptr;
        }
        HRESULT hr = allocator ? allocator->QueryInterface(IID_PPV_ARGS(&allocator_)) : S_OK;
        LogHResult(L"IPhoneCameraStream::SetAllocator", hr);
        return hr;
    }

    static bool IsSupportedFrameSize(UINT32 width, UINT32 height) {
        return (width == PORTRAIT_WIDTH && height == PORTRAIT_HEIGHT) || (width == LANDSCAPE_WIDTH && height == LANDSCAPE_HEIGHT);
    }

    HRESULT SetMediaTypeInternal(IMFMediaType* mediaType) {
        if (!mediaType) return E_INVALIDARG;
        GUID subtype = GUID_NULL;
        HRESULT hr = mediaType->GetGUID(MF_MT_SUBTYPE, &subtype);
        if (SUCCEEDED(hr) && subtype != MFVideoFormat_NV12 && subtype != MFVideoFormat_RGB32) hr = MF_E_INVALIDMEDIATYPE;
        UINT32 width = 0;
        UINT32 height = 0;
        if (SUCCEEDED(hr)) hr = MFGetAttributeSize(mediaType, MF_MT_FRAME_SIZE, &width, &height);
        if (SUCCEEDED(hr) && !IsSupportedFrameSize(width, height)) hr = MF_E_INVALIDMEDIATYPE;
        IMFMediaTypeHandler* handler = nullptr;
        if (SUCCEEDED(hr)) hr = descriptor_ ? descriptor_->GetMediaTypeHandler(&handler) : E_FAIL;
        if (SUCCEEDED(hr)) hr = handler->SetCurrentMediaType(mediaType);
        if (SUCCEEDED(hr)) {
            currentSubtype_ = subtype;
            outputWidth_ = width;
            outputHeight_ = height;
        }
        if (handler) handler->Release();
        LogGuid(L"IPhoneCameraStream::SetMediaTypeInternal subtype", subtype);
        LogFormat(L"IPhoneCameraStream::SetMediaTypeInternal size=%ux%u", width, height);
        LogHResult(L"IPhoneCameraStream::SetMediaTypeInternal", hr);
        return hr;
    }

    STDMETHODIMP SetStreamState(MF_STREAM_STATE state) override {
        LogFormat(L"IPhoneCameraStream::SetStreamState state=%u", static_cast<unsigned int>(state));
        switch (state) {
        case MF_STREAM_STATE_RUNNING:
            return Start(nullptr);
        case MF_STREAM_STATE_STOPPED:
            return Stop();
        case MF_STREAM_STATE_PAUSED: {
            if (streamState_ != MF_STREAM_STATE_RUNNING) return MF_E_INVALID_STATE_TRANSITION;
            streamState_ = MF_STREAM_STATE_PAUSED;
            PROPVARIANT empty;
            PropVariantInit(&empty);
            if (eventQueue_) eventQueue_->QueueEventParamVar(MEStreamPaused, GUID_NULL, S_OK, &empty);
            return S_OK;
        }
        default:
            return MF_E_INVALID_STATE_TRANSITION;
        }
    }

    STDMETHODIMP GetStreamState(MF_STREAM_STATE* state) override {
        if (!state) return E_POINTER;
        *state = streamState_;
        LogFormat(L"IPhoneCameraStream::GetStreamState state=%u", static_cast<unsigned int>(streamState_));
        return S_OK;
    }

    HRESULT Start(const PROPVARIANT* startPosition) {
        LogLine(L"IPhoneCameraStream::Start");
        SyncCurrentSubtype();
        if (allocator_) {
            IMFMediaType* currentType = nullptr;
            IMFMediaTypeHandler* handler = nullptr;
            HRESULT allocHr = descriptor_ ? descriptor_->GetMediaTypeHandler(&handler) : E_FAIL;
            if (SUCCEEDED(allocHr)) allocHr = handler->GetCurrentMediaType(&currentType);
            if (SUCCEEDED(allocHr)) allocHr = allocator_->InitializeSampleAllocator(10, currentType);
            LogHResult(L"IPhoneCameraStream::Start InitializeSampleAllocator", allocHr);
            if (FAILED(allocHr)) {
                allocator_->Release();
                allocator_ = nullptr;
            }
            if (currentType) currentType->Release();
            if (handler) handler->Release();
        }
        PROPVARIANT empty;
        PropVariantInit(&empty);
        const PROPVARIANT* value = startPosition ? startPosition : &empty;
        streamState_ = MF_STREAM_STATE_RUNNING;
        if (eventQueue_) eventQueue_->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, value);
        return S_OK;
    }

    HRESULT Stop() {
        LogLine(L"IPhoneCameraStream::Stop");
        if (allocator_) allocator_->UninitializeSampleAllocator();
        PROPVARIANT empty;
        PropVariantInit(&empty);
        streamState_ = MF_STREAM_STATE_STOPPED;
        if (eventQueue_) eventQueue_->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, &empty);
        return S_OK;
    }

    HRESULT Shutdown() {
        if (eventQueue_) eventQueue_->Shutdown();
        return S_OK;
    }

private:
    HRESULT SyncCurrentSubtype() {
        IMFMediaTypeHandler* handler = nullptr;
        IMFMediaType* currentType = nullptr;
        HRESULT hr = descriptor_ ? descriptor_->GetMediaTypeHandler(&handler) : E_FAIL;
        if (SUCCEEDED(hr)) hr = handler->GetCurrentMediaType(&currentType);
        GUID subtype = GUID_NULL;
        if (SUCCEEDED(hr)) hr = currentType->GetGUID(MF_MT_SUBTYPE, &subtype);
        if (SUCCEEDED(hr) && (subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_RGB32)) currentSubtype_ = subtype;
        UINT32 width = 0;
        UINT32 height = 0;
        if (SUCCEEDED(hr) && SUCCEEDED(MFGetAttributeSize(currentType, MF_MT_FRAME_SIZE, &width, &height)) && IsSupportedFrameSize(width, height)) {
            outputWidth_ = width;
            outputHeight_ = height;
        }
        if (currentType) currentType->Release();
        if (handler) handler->Release();
        return hr;
    }

    HRESULT CreateDescriptor() {
        IMFMediaType* mediaTypes[4] = {};
        IMFMediaTypeHandler* handler = nullptr;
        HRESULT hr = CreateVideoMediaType(MFVideoFormat_NV12, PORTRAIT_WIDTH, PORTRAIT_HEIGHT, &mediaTypes[0]);
        if (SUCCEEDED(hr)) hr = CreateVideoMediaType(MFVideoFormat_NV12, LANDSCAPE_WIDTH, LANDSCAPE_HEIGHT, &mediaTypes[1]);
        if (SUCCEEDED(hr)) hr = CreateVideoMediaType(MFVideoFormat_RGB32, PORTRAIT_WIDTH, PORTRAIT_HEIGHT, &mediaTypes[2]);
        if (SUCCEEDED(hr)) hr = CreateVideoMediaType(MFVideoFormat_RGB32, LANDSCAPE_WIDTH, LANDSCAPE_HEIGHT, &mediaTypes[3]);
        if (SUCCEEDED(hr)) hr = MFCreateStreamDescriptor(1, 4, mediaTypes, &descriptor_);
        if (SUCCEEDED(hr)) hr = descriptor_->SetUINT32(MF_SD_STREAM_NAME, 1);
        if (SUCCEEDED(hr)) hr = descriptor_->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 1);
        if (SUCCEEDED(hr)) hr = descriptor_->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, PINNAME_VIDEO_CAPTURE);
        if (SUCCEEDED(hr)) hr = descriptor_->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
        if (SUCCEEDED(hr)) hr = descriptor_->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color);
        if (SUCCEEDED(hr)) hr = descriptor_->GetMediaTypeHandler(&handler);
        if (SUCCEEDED(hr)) hr = handler->SetCurrentMediaType(mediaTypes[0]);
        if (SUCCEEDED(hr) && descriptor_) LogAttributes(L"Stream descriptor attributes", descriptor_);
        if (handler) handler->Release();
        for (IMFMediaType* mediaType : mediaTypes) {
            if (mediaType) mediaType->Release();
        }
        LogHResult(L"IPhoneCameraStream::CreateDescriptor", hr);
        return hr;
    }

    static BYTE ClampByte(int value) {
        if (value < 0) return 0;
        if (value > 255) return 255;
        return static_cast<BYTE>(value);
    }

    static BYTE RgbToY(BYTE r, BYTE g, BYTE b) {
        return ClampByte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }

    static BYTE RgbToU(BYTE r, BYTE g, BYTE b) {
        return ClampByte(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
    }

    static BYTE RgbToV(BYTE r, BYTE g, BYTE b) {
        return ClampByte(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }

    // fileBuffer must hold SHARED_HEADER_BYTES + MAX_RGBA_BYTES. On success *pixels
    // points into fileBuffer at tightly packed RGBA of *width x *height.
    bool LoadSharedRgba(BYTE* fileBuffer, const BYTE** pixels, UINT32* width, UINT32* height, ULONGLONG* fileAgeMs) {
        *fileAgeMs = 0;
        HANDLE file = CreateFileW(
            SHARED_FRAME_PATH,
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
            nullptr);
        if (file == INVALID_HANDLE_VALUE) {
            if (!loggedFallback_) LogFormat(L"IPhoneCameraStream::FillFrame open shared frame failed gle=%lu", GetLastError());
            return false;
        }
        // How long since the host last rewrote the frame. GetFileTime and
        // GetSystemTimeAsFileTime share the UTC system clock, so the delta is a
        // valid elapsed time (guards against a future timestamp underflowing).
        FILETIME lastWriteFt = {};
        if (GetFileTime(file, nullptr, nullptr, &lastWriteFt)) {
            FILETIME nowFt = {};
            GetSystemTimeAsFileTime(&nowFt);
            ULARGE_INTEGER lastWrite = { lastWriteFt.dwLowDateTime, lastWriteFt.dwHighDateTime };
            ULARGE_INTEGER now = { nowFt.dwLowDateTime, nowFt.dwHighDateTime };
            if (now.QuadPart > lastWrite.QuadPart) {
                *fileAgeMs = (now.QuadPart - lastWrite.QuadPart) / 10000ULL;
            }
        }
        DWORD read = 0;
        const BOOL ok = ReadFile(file, fileBuffer, SHARED_HEADER_BYTES + MAX_RGBA_BYTES, &read, nullptr);
        CloseHandle(file);
        if (read >= SHARED_HEADER_BYTES && memcmp(fileBuffer, SHARED_FRAME_MAGIC, sizeof(SHARED_FRAME_MAGIC)) == 0) {
            UINT32 sharedWidth = 0;
            UINT32 sharedHeight = 0;
            UINT32 sharedStride = 0;
            memcpy(&sharedWidth, fileBuffer + 4, sizeof(UINT32));
            memcpy(&sharedHeight, fileBuffer + 8, sizeof(UINT32));
            memcpy(&sharedStride, fileBuffer + 12, sizeof(UINT32));
            const UINT64 pixelBytes = static_cast<UINT64>(sharedStride) * sharedHeight;
            if (sharedWidth == 0 || sharedHeight == 0 || sharedStride != sharedWidth * 4 ||
                pixelBytes > MAX_RGBA_BYTES || read < SHARED_HEADER_BYTES + pixelBytes) {
                if (!loggedFallback_) LogFormat(L"IPhoneCameraStream::FillFrame bad shared frame header %ux%u stride=%u bytes=%lu", sharedWidth, sharedHeight, sharedStride, read);
                return false;
            }
            *pixels = fileBuffer + SHARED_HEADER_BYTES;
            *width = sharedWidth;
            *height = sharedHeight;
            if (!loggedLiveFrame_) {
                LogFormat(L"IPhoneCameraStream::FillFrame using shared frame %ux%u bytes=%lu", sharedWidth, sharedHeight, read);
                loggedLiveFrame_ = true;
            }
            return true;
        }
        // Headerless legacy layout: fixed portrait RGBA written by an older host.
        if (read == LEGACY_RGBA_BYTES) {
            *pixels = fileBuffer;
            *width = PORTRAIT_WIDTH;
            *height = PORTRAIT_HEIGHT;
            if (!loggedLiveFrame_) {
                LogFormat(L"IPhoneCameraStream::FillFrame using legacy shared frame bytes=%lu", read);
                loggedLiveFrame_ = true;
            }
            return true;
        }
        if (!loggedFallback_) LogFormat(L"IPhoneCameraStream::FillFrame shared frame read failed ok=%u bytes=%lu gle=%lu", ok ? 1U : 0U, read, GetLastError());
        return false;
    }

    // Nearest-neighbour aspect-fit of src into dst (tightly packed RGBA) with
    // opaque black bars. Handles the shared frame orientation differing from the
    // negotiated output type.
    static void FitRgba(const BYTE* src, UINT32 srcWidth, UINT32 srcHeight, BYTE* dst, UINT32 dstWidth, UINT32 dstHeight) {
        const UINT32 dstStride = dstWidth * 4;
        memset(dst, 0, static_cast<size_t>(dstStride) * dstHeight);
        for (UINT32 i = 3; i < dstStride * dstHeight; i += 4) dst[i] = 0xFF;

        UINT32 fitWidth;
        UINT32 fitHeight;
        if (static_cast<UINT64>(srcWidth) * dstHeight >= static_cast<UINT64>(srcHeight) * dstWidth) {
            fitWidth = dstWidth;
            fitHeight = static_cast<UINT32>(static_cast<UINT64>(srcHeight) * dstWidth / srcWidth);
            if (fitHeight == 0) fitHeight = 1;
        } else {
            fitHeight = dstHeight;
            fitWidth = static_cast<UINT32>(static_cast<UINT64>(srcWidth) * dstHeight / srcHeight);
            if (fitWidth == 0) fitWidth = 1;
        }
        const UINT32 xOffset = (dstWidth - fitWidth) / 2;
        const UINT32 yOffset = (dstHeight - fitHeight) / 2;

        for (UINT32 y = 0; y < fitHeight; ++y) {
            const UINT32 srcY = static_cast<UINT32>(static_cast<UINT64>(y) * srcHeight / fitHeight);
            const BYTE* srcRow = src + (static_cast<size_t>(srcY) * srcWidth * 4);
            BYTE* dstRow = dst + (static_cast<size_t>(y + yOffset) * dstStride) + (static_cast<size_t>(xOffset) * 4);
            for (UINT32 x = 0; x < fitWidth; ++x) {
                const UINT32 srcX = static_cast<UINT32>(static_cast<UINT64>(x) * srcWidth / fitWidth);
                memcpy(dstRow + (static_cast<size_t>(x) * 4), srcRow + (static_cast<size_t>(srcX) * 4), 4);
            }
        }
    }

    // Composite an unmistakable "signal lost" treatment onto a live RGBA frame
    // (tightly packed, width x height) in place: darken the frozen image, draw a
    // pulsing red border, and stamp a red no-signal glyph (ring + diagonal slash)
    // in the centre. tickMs drives the pulse so the state reads as live-but-stalled
    // rather than a frozen picture.
    static void ApplyStaleOverlay(BYTE* rgba, UINT32 width, UINT32 height, ULONGLONG tickMs) {
        const UINT32 stride = width * 4;
        // Darken to ~30% so the last frame reads as inactive (alpha untouched).
        for (UINT32 i = 0; i < stride * height; i += 4) {
            rgba[i] = static_cast<BYTE>(rgba[i] * 3 / 10);
            rgba[i + 1] = static_cast<BYTE>(rgba[i + 1] * 3 / 10);
            rgba[i + 2] = static_cast<BYTE>(rgba[i + 2] * 3 / 10);
        }
        // Triangle-wave pulse in [64,255] over a ~1.6s period.
        const UINT32 phase = static_cast<UINT32>(tickMs % 1600);
        const UINT32 tri = phase < 800 ? phase : 1600 - phase;   // 0..800
        const BYTE pulse = static_cast<BYTE>(64 + tri * 191 / 800);

        // Pulsing red border framing the whole image.
        const UINT32 border = (width < height ? width : height) / 40 + 2;
        for (UINT32 y = 0; y < height; ++y) {
            BYTE* row = rgba + static_cast<size_t>(y) * stride;
            const bool edgeRow = y < border || y >= height - border;
            for (UINT32 x = 0; x < width; ++x) {
                if (edgeRow || x < border || x >= width - border) {
                    BYTE* px = row + static_cast<size_t>(x) * 4;
                    px[0] = pulse; px[1] = 0; px[2] = 0; px[3] = 0xFF;
                }
            }
        }

        // Centred no-signal glyph: a red ring with a diagonal slash through it.
        const int cx = static_cast<int>(width / 2);
        const int cy = static_cast<int>(height / 2);
        const int radius = static_cast<int>((width < height ? width : height) / 6);
        if (radius < 6) return;
        const int ringInner = radius - radius / 6;   // ring thickness ~ radius/6
        const int slashHalf = radius / 8 + 1;        // slash half-thickness
        for (int y = cy - radius; y <= cy + radius; ++y) {
            if (y < 0 || y >= static_cast<int>(height)) continue;
            BYTE* row = rgba + static_cast<size_t>(y) * stride;
            for (int x = cx - radius; x <= cx + radius; ++x) {
                if (x < 0 || x >= static_cast<int>(width)) continue;
                const int dx = x - cx;
                const int dy = y - cy;
                const int dist2 = dx * dx + dy * dy;
                int diag = dx - dy;
                if (diag < 0) diag = -diag;
                const bool onRing = dist2 <= radius * radius && dist2 >= ringInner * ringInner;
                const bool onSlash = dist2 <= ringInner * ringInner && diag <= slashHalf;
                if (onRing || onSlash) {
                    BYTE* px = row + static_cast<size_t>(x) * 4;
                    px[0] = pulse; px[1] = 0; px[2] = 0; px[3] = 0xFF;
                }
            }
        }
    }

    // rgba may be null, which selects the fallback test pattern. rgba is tightly
    // packed at width x height (already fitted to the negotiated output type).
    // scanline0/pitch address the destination the way IMF2DBuffer2::Lock2DSize
    // reports it.
    void WritePixels(bool rgb32, const BYTE* rgba, BYTE* scanline0, LONG pitch, UINT32 width, UINT32 height) {
        if (rgb32) {
            if (rgba) WriteRgb32FromRgba(rgba, scanline0, pitch, width, height);
            else WriteRgb32Fallback(scanline0, pitch, width, height);
        } else {
            if (rgba) WriteNv12FromRgba(rgba, scanline0, pitch, width, height);
            else WriteNv12Fallback(scanline0, pitch, width, height);
        }
    }

    HRESULT WriteFrameToSample(IMFSample* sample, bool rgb32, const BYTE* rgba, DWORD frameBytes, UINT32 width, UINT32 height) {
        IMFMediaBuffer* buffer = nullptr;
        HRESULT hr = sample->GetBufferByIndex(0, &buffer);
        if (FAILED(hr)) return hr;
        IMF2DBuffer2* buffer2d = nullptr;
        if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d)))) {
            BYTE* scanline0 = nullptr;
            LONG pitch = 0;
            BYTE* bufferStart = nullptr;
            DWORD bufferLength = 0;
            hr = buffer2d->Lock2DSize(MF2DBuffer_LockFlags_Write, &scanline0, &pitch, &bufferStart, &bufferLength);
            if (SUCCEEDED(hr)) {
                const LONG minPitch = rgb32 ? static_cast<LONG>(width * 4) : static_cast<LONG>(width);
                // NV12 needs a top-down layout so the UV plane can be addressed
                // at scanline0 + pitch * height; RGB32 tolerates negative pitch.
                const bool pitchUsable = rgb32 ? (pitch >= minPitch || pitch <= -minPitch) : pitch >= minPitch;
                if (pitchUsable) {
                    WritePixels(rgb32, rgba, scanline0, pitch, width, height);
                } else {
                    hr = E_FAIL;
                }
                buffer2d->Unlock2D();
            }
            buffer2d->Release();
        } else {
            BYTE* dest = nullptr;
            DWORD maxLength = 0;
            hr = buffer->Lock(&dest, &maxLength, nullptr);
            if (SUCCEEDED(hr)) {
                if (maxLength >= frameBytes) {
                    WritePixels(rgb32, rgba, dest, rgb32 ? static_cast<LONG>(width * 4) : static_cast<LONG>(width), width, height);
                } else {
                    hr = E_FAIL;
                }
                buffer->Unlock();
                if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(frameBytes);
            }
        }
        buffer->Release();
        return hr;
    }

    void WriteNv12FromRgba(const BYTE* rgba, BYTE* scanline0, LONG pitch, UINT32 width, UINT32 height) {
        const UINT32 rgbaStride = width * 4;
        BYTE* uvPlane = scanline0 + (static_cast<LONG_PTR>(pitch) * height);

        for (UINT32 y = 0; y < height; ++y) {
            const BYTE* srcRow = rgba + (static_cast<size_t>(y) * rgbaStride);
            BYTE* dstRow = scanline0 + (static_cast<LONG_PTR>(pitch) * y);
            for (UINT32 x = 0; x < width; ++x) {
                const BYTE* pixel = srcRow + (x * 4);
                dstRow[x] = RgbToY(pixel[0], pixel[1], pixel[2]);
            }
        }

        for (UINT32 y = 0; y < height; y += 2) {
            BYTE* uvRow = uvPlane + (static_cast<LONG_PTR>(pitch) * (y / 2));
            for (UINT32 x = 0; x < width; x += 2) {
                int u = 0;
                int v = 0;
                for (UINT32 dy = 0; dy < 2; ++dy) {
                    const BYTE* srcRow = rgba + (static_cast<size_t>(y + dy) * rgbaStride);
                    for (UINT32 dx = 0; dx < 2; ++dx) {
                        const BYTE* pixel = srcRow + ((x + dx) * 4);
                        u += RgbToU(pixel[0], pixel[1], pixel[2]);
                        v += RgbToV(pixel[0], pixel[1], pixel[2]);
                    }
                }
                uvRow[x] = static_cast<BYTE>(u / 4);
                uvRow[x + 1] = static_cast<BYTE>(v / 4);
            }
        }
    }

    void WriteNv12Fallback(BYTE* scanline0, LONG pitch, UINT32 width, UINT32 height) {
        BYTE* uvPlane = scanline0 + (static_cast<LONG_PTR>(pitch) * height);
        for (UINT32 y = 0; y < height; ++y) {
            BYTE* row = scanline0 + (static_cast<LONG_PTR>(pitch) * y);
            for (UINT32 x = 0; x < width; ++x) {
                const bool stripe = ((x / 80) + (y / 80)) % 2 == 0;
                row[x] = stripe ? 200 : 64;
            }
        }
        for (UINT32 y = 0; y < height / 2; ++y) {
            BYTE* row = uvPlane + (static_cast<LONG_PTR>(pitch) * y);
            for (UINT32 x = 0; x < width; x += 2) {
                row[x] = 128;
                row[x + 1] = 128;
            }
        }
    }

    void WriteRgb32FromRgba(const BYTE* rgba, BYTE* scanline0, LONG pitch, UINT32 width, UINT32 height) {
        const UINT32 rgbaStride = width * 4;
        for (UINT32 y = 0; y < height; ++y) {
            const BYTE* srcRow = rgba + (static_cast<size_t>(y) * rgbaStride);
            BYTE* dstRow = scanline0 + (static_cast<LONG_PTR>(pitch) * y);
            for (UINT32 x = 0; x < width; ++x) {
                const BYTE* pixel = srcRow + (x * 4);
                BYTE* out = dstRow + (x * 4);
                out[0] = pixel[2];
                out[1] = pixel[1];
                out[2] = pixel[0];
                out[3] = 0xFF;
            }
        }
    }

    void WriteRgb32Fallback(BYTE* scanline0, LONG pitch, UINT32 width, UINT32 height) {
        for (UINT32 y = 0; y < height; ++y) {
            BYTE* row = scanline0 + (static_cast<LONG_PTR>(pitch) * y);
            for (UINT32 x = 0; x < width; ++x) {
                const bool stripe = ((x / 80) + (y / 80)) % 2 == 0;
                const BYTE value = stripe ? 200 : 64;
                BYTE* out = row + (x * 4);
                out[0] = value;
                out[1] = value;
                out[2] = value;
                out[3] = 0xFF;
            }
        }
    }

    std::atomic<long> refCount_;
    IMFMediaSource* source_ = nullptr;
    IMFMediaEventQueue* eventQueue_ = nullptr;
    IMFStreamDescriptor* descriptor_ = nullptr;
    IMFVideoSampleAllocator* allocator_ = nullptr;
    GUID currentSubtype_ = MFVideoFormat_NV12;
    UINT32 outputWidth_ = PORTRAIT_WIDTH;
    UINT32 outputHeight_ = PORTRAIT_HEIGHT;
    MF_STREAM_STATE streamState_ = MF_STREAM_STATE_STOPPED;
    unsigned long long requestedSamples_ = 0;
    bool loggedLiveFrame_ = false;
    bool loggedFallback_ = false;
    bool loggedAllocatorFallback_ = false;
    bool stale_ = false;
};

class IPhoneExtendedCameraControl final : public IMFExtendedCameraControl {
public:
    explicit IPhoneExtendedCameraControl(ULONG propertyId) : refCount_(1), propertyId_(propertyId) {
        g_objectCount.fetch_add(1);
        ZeroMemory(&roiConfigCaps_, sizeof(roiConfigCaps_));
        roiConfigCaps_.Size = sizeof(roiConfigCaps_);
        roiConfigCaps_.ConfigCapCount = 0;
        LogFormat(L"IPhoneExtendedCameraControl created property=%u", propertyId_);
    }

    ~IPhoneExtendedCameraControl() {
        LogFormat(L"IPhoneExtendedCameraControl destroyed property=%u", propertyId_);
        g_objectCount.fetch_sub(1);
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        LogGuid(L"IPhoneExtendedCameraControl::QueryInterface", riid);
        if (!object) return E_POINTER;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == __uuidof(IMFExtendedCameraControl)) {
            *object = static_cast<IMFExtendedCameraControl*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(refCount_.fetch_add(1) + 1); }
    STDMETHODIMP_(ULONG) Release() override {
        const ULONG count = static_cast<ULONG>(refCount_.fetch_sub(1) - 1);
        if (count == 0) delete this;
        return count;
    }

    STDMETHODIMP_(ULONGLONG) GetCapabilities() override {
        LogFormat(L"IPhoneExtendedCameraControl::GetCapabilities property=%u", propertyId_);
        return 0;
    }

    STDMETHODIMP SetFlags(ULONGLONG flags) override {
        LogFormat(L"IPhoneExtendedCameraControl::SetFlags property=%u flags=0x%016llX", propertyId_, flags);
        flags_ = flags;
        return flags == 0 ? S_OK : MF_E_INVALIDREQUEST;
    }

    STDMETHODIMP_(ULONGLONG) GetFlags() override {
        LogFormat(L"IPhoneExtendedCameraControl::GetFlags property=%u flags=0x%016llX", propertyId_, flags_);
        return flags_;
    }

    STDMETHODIMP LockPayload(BYTE** payload, ULONG* payloadSize) override {
        LogFormat(L"IPhoneExtendedCameraControl::LockPayload property=%u", propertyId_);
        if (!payload || !payloadSize) return E_POINTER;
        *payload = nullptr;
        *payloadSize = 0;
        if (propertyId_ == KSPROPERTY_CAMERACONTROL_EXTENDED_ROI_CONFIGCAPS) {
            *payload = reinterpret_cast<BYTE*>(&roiConfigCaps_);
            *payloadSize = sizeof(roiConfigCaps_);
        }
        LogFormat(L"IPhoneExtendedCameraControl::LockPayload size=%u", *payloadSize);
        return S_OK;
    }

    STDMETHODIMP UnlockPayload() override {
        LogFormat(L"IPhoneExtendedCameraControl::UnlockPayload property=%u", propertyId_);
        return S_OK;
    }

    STDMETHODIMP CommitSettings() override {
        LogFormat(L"IPhoneExtendedCameraControl::CommitSettings property=%u", propertyId_);
        return S_OK;
    }

private:
    std::atomic<long> refCount_;
    ULONG propertyId_ = 0;
    ULONGLONG flags_ = 0;
    KSCAMERA_EXTENDEDPROP_ROI_CONFIGCAPSHEADER roiConfigCaps_ = {};
};

enum class SourceState {
    Stopped,
    Started,
    Shutdown
};

class IPhoneCameraSource final : public IMFMediaSource2, public IMFGetService, public IMFExtendedCameraController, public IKsControl, public IMFRealTimeClient, public IMFRealTimeClientEx, public IMFSampleAllocatorControl {
public:
    IPhoneCameraSource() : refCount_(1) {
        g_objectCount.fetch_add(1);
        MFCreateEventQueue(&eventQueue_);
        stream_ = new (std::nothrow) IPhoneCameraStream(this);
        CreateDefaultPresentationDescriptor();
    }

    ~IPhoneCameraSource() {
        if (presentationDescriptor_) presentationDescriptor_->Release();
        if (stream_) stream_->Release();
        if (eventQueue_) eventQueue_->Release();
        g_objectCount.fetch_sub(1);
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        LogGuid(L"IPhoneCameraSource::QueryInterface", riid);
        if (!object) return E_POINTER;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == __uuidof(IMFMediaEventGenerator) || riid == __uuidof(IMFMediaSource) || riid == __uuidof(IMFMediaSourceEx) || riid == __uuidof(IMFMediaSource2)) {
            *object = static_cast<IMFMediaSource2*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IMFGetService)) {
            *object = static_cast<IMFGetService*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IMFExtendedCameraController)) {
            *object = static_cast<IMFExtendedCameraController*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IKsControl)) {
            *object = static_cast<IKsControl*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IMFRealTimeClient)) {
            *object = static_cast<IMFRealTimeClient*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IMFRealTimeClientEx)) {
            *object = static_cast<IMFRealTimeClientEx*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IMFSampleAllocatorControl)) {
            *object = static_cast<IMFSampleAllocatorControl*>(this);
            AddRef();
            return S_OK;
        }
        LogGuid(L"IPhoneCameraSource::QueryInterface unsupported", riid);
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(refCount_.fetch_add(1) + 1); }
    STDMETHODIMP_(ULONG) Release() override {
        const ULONG count = static_cast<ULONG>(refCount_.fetch_sub(1) - 1);
        if (count == 0) delete this;
        return count;
    }

    STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override { return eventQueue_ ? eventQueue_->GetEvent(flags, event) : MF_E_SHUTDOWN; }
    STDMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override { return eventQueue_ ? eventQueue_->BeginGetEvent(callback, state) : MF_E_SHUTDOWN; }
    STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override { return eventQueue_ ? eventQueue_->EndGetEvent(result, event) : MF_E_SHUTDOWN; }
    STDMETHODIMP QueueEvent(MediaEventType type, REFGUID extendedType, HRESULT status, const PROPVARIANT* value) override {
        return eventQueue_ ? eventQueue_->QueueEventParamVar(type, extendedType, status, value) : MF_E_SHUTDOWN;
    }

    STDMETHODIMP GetService(REFGUID guidService, REFIID riid, LPVOID* object) override {
        LogGuid(L"IPhoneCameraSource::GetService service", guidService);
        LogGuid(L"IPhoneCameraSource::GetService riid", riid);
        if (!object) return E_POINTER;
        *object = nullptr;
        if (riid == __uuidof(IMFExtendedCameraController)) {
            *object = static_cast<IMFExtendedCameraController*>(this);
            AddRef();
            return S_OK;
        }
        if (riid == __uuidof(IKsControl)) {
            *object = static_cast<IKsControl*>(this);
            AddRef();
            return S_OK;
        }
        return MF_E_UNSUPPORTED_SERVICE;
    }

    STDMETHODIMP GetExtendedCameraControl(DWORD streamIndex, ULONG propertyId, IMFExtendedCameraControl** control) override {
        LogFormat(L"IPhoneCameraSource::GetExtendedCameraControl stream=%u property=%u", streamIndex, propertyId);
        if (!control) return E_POINTER;
        *control = nullptr;
        if (propertyId == KSPROPERTY_CAMERACONTROL_EXTENDED_ROI_CONFIGCAPS) {
            auto* created = new (std::nothrow) IPhoneExtendedCameraControl(propertyId);
            if (!created) return E_OUTOFMEMORY;
            *control = created;
            LogLine(L"IPhoneCameraSource::GetExtendedCameraControl returned ROI config caps control");
            return S_OK;
        }
        return MF_E_UNSUPPORTED_SERVICE;
    }

    STDMETHODIMP KsProperty(PKSPROPERTY property, ULONG propertyLength, LPVOID propertyData, ULONG dataLength, ULONG* bytesReturned) override {
        LogFormat(L"IPhoneCameraSource::KsProperty propertyLength=%u dataLength=%u", propertyLength, dataLength);
        if (bytesReturned) *bytesReturned = 0;
        if (!property || propertyLength < sizeof(KSPROPERTY)) return E_INVALIDARG;
        LogGuid(L"IPhoneCameraSource::KsProperty set", property->Set);
        LogFormat(L"IPhoneCameraSource::KsProperty id=%u flags=0x%08X", property->Id, property->Flags);

        if (property->Set == PROPSETID_VIDCAP_CAMERACONTROL && (property->Flags & KSPROPERTY_TYPE_BASICSUPPORT)) {
            const ULONG accessFlags = 0;
            if (propertyData && dataLength >= sizeof(ULONG)) {
                *reinterpret_cast<ULONG*>(propertyData) = accessFlags;
                if (bytesReturned) *bytesReturned = sizeof(ULONG);
                LogLine(L"IPhoneCameraSource::KsProperty camera-control basic support returned no access flags");
                return S_OK;
            }
            if (bytesReturned) *bytesReturned = sizeof(ULONG);
            return HRESULT_FROM_WIN32(ERROR_MORE_DATA);
        }

        if (property->Set == PROPSETID_VIDCAP_CAMERACONTROL && property->Id == KSPROPERTY_CAMERACONTROL_PRIVACY && (property->Flags & KSPROPERTY_TYPE_GET)) {
            if (!propertyData || dataLength < sizeof(KSPROPERTY_CAMERACONTROL_S)) {
                if (bytesReturned) *bytesReturned = sizeof(KSPROPERTY_CAMERACONTROL_S);
                return HRESULT_FROM_WIN32(ERROR_MORE_DATA);
            }
            auto* value = reinterpret_cast<KSPROPERTY_CAMERACONTROL_S*>(propertyData);
            value->Property = *property;
            value->Value = 0;
            value->Flags = KSPROPERTY_CAMERACONTROL_FLAGS_MANUAL;
            value->Capabilities = 0;
            if (bytesReturned) *bytesReturned = sizeof(KSPROPERTY_CAMERACONTROL_S);
            LogLine(L"IPhoneCameraSource::KsProperty privacy returned off");
            return S_OK;
        }

        return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    }

    STDMETHODIMP KsMethod(PKSMETHOD method, ULONG methodLength, LPVOID methodData, ULONG dataLength, ULONG* bytesReturned) override {
        LogFormat(L"IPhoneCameraSource::KsMethod methodLength=%u dataLength=%u", methodLength, dataLength);
        if (method && methodLength >= sizeof(KSMETHOD)) LogGuid(L"IPhoneCameraSource::KsMethod set", method->Set);
        if (bytesReturned) *bytesReturned = 0;
        return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    }

    STDMETHODIMP KsEvent(PKSEVENT event, ULONG eventLength, LPVOID eventData, ULONG dataLength, ULONG* bytesReturned) override {
        LogFormat(L"IPhoneCameraSource::KsEvent eventLength=%u dataLength=%u", eventLength, dataLength);
        if (event && eventLength >= sizeof(KSEVENT)) {
            LogGuid(L"IPhoneCameraSource::KsEvent set", event->Set);
            LogFormat(L"IPhoneCameraSource::KsEvent id=%u flags=0x%08X", event->Id, event->Flags);
            if (event->Set == PROPSETID_VIDCAP_CAMERACONTROL && event->Id == KSPROPERTY_CAMERACONTROL_PRIVACY && (event->Flags & KSPROPERTY_TYPE_BASICSUPPORT)) {
                if (eventData && dataLength >= sizeof(ULONG)) {
                    *reinterpret_cast<ULONG*>(eventData) = 0;
                    if (bytesReturned) *bytesReturned = sizeof(ULONG);
                    LogLine(L"IPhoneCameraSource::KsEvent privacy basic support returned no flags");
                    return S_OK;
                }
                if (bytesReturned) *bytesReturned = sizeof(ULONG);
                return HRESULT_FROM_WIN32(ERROR_MORE_DATA);
            }
        }
        if (bytesReturned) *bytesReturned = 0;
        return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    }


    STDMETHODIMP GetCharacteristics(DWORD* characteristics) override {
        LogLine(L"IPhoneCameraSource::GetCharacteristics");
        if (!characteristics) return E_POINTER;
        if (state_ == SourceState::Shutdown) return MF_E_SHUTDOWN;
        *characteristics = MFMEDIASOURCE_IS_LIVE;
        return S_OK;
    }

    STDMETHODIMP GetSourceAttributes(IMFAttributes** attributes) override {
        LogLine(L"IPhoneCameraSource::GetSourceAttributes");
        if (!attributes) return E_POINTER;
        *attributes = nullptr;
        IMFAttributes* created = nullptr;
        HRESULT hr = MFCreateAttributes(&created, 8);
        if (SUCCEEDED(hr)) hr = created->SetString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, L"iPhone Camera");
        if (SUCCEEDED(hr)) hr = created->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
        if (SUCCEEDED(hr)) hr = created->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY, KSCATEGORY_VIDEO_CAMERA);
        if (SUCCEEDED(hr)) hr = created->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_PROVIDER_DEVICE_ID, L"IPhoneCameraStreaming");
        if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_MAX_BUFFERS, 3);
        if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_LOW_LATENCY, TRUE);
        if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, FALSE);
        if (SUCCEEDED(hr)) LogAttributes(L"Source attributes", created);
        if (SUCCEEDED(hr)) { *attributes = created; created = nullptr; }
        if (created) created->Release();
        LogHResult(L"IPhoneCameraSource::GetSourceAttributes", hr);
        return hr;
    }

    STDMETHODIMP GetStreamAttributes(DWORD streamIdentifier, IMFAttributes** attributes) override {
        LogLine(L"IPhoneCameraSource::GetStreamAttributes");
        if (!attributes) return E_POINTER;
        *attributes = nullptr;
        if (streamIdentifier != 1) return MF_E_INVALIDSTREAMNUMBER;
        IMFAttributes* created = nullptr;
        HRESULT hr = MFCreateAttributes(&created, 4);
        if (SUCCEEDED(hr)) hr = created->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, PINNAME_VIDEO_CAPTURE);
        if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_DEVICESTREAM_STREAM_ID, streamIdentifier);
        if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
        if (SUCCEEDED(hr)) hr = created->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, MFFrameSourceTypes_Color);
        if (SUCCEEDED(hr)) LogAttributes(L"Stream attributes", created);
        if (SUCCEEDED(hr)) { *attributes = created; created = nullptr; }
        if (created) created->Release();
        LogHResult(L"IPhoneCameraSource::GetStreamAttributes", hr);
        return hr;
    }

    STDMETHODIMP SetD3DManager(IUnknown* manager) override {
        LogFormat(L"IPhoneCameraSource::SetD3DManager manager=%p", manager);
        return S_OK;
    }

    STDMETHODIMP SetMediaType(DWORD streamId, IMFMediaType* mediaType) override {
        LogFormat(L"IPhoneCameraSource::SetMediaType stream=%u", streamId);
        if (mediaType) LogAttributes(L"IPhoneCameraSource::SetMediaType media type", mediaType);
        if (state_ == SourceState::Shutdown) return MF_E_SHUTDOWN;
        if (streamId != 1 || !mediaType) return E_INVALIDARG;
        return stream_ ? stream_->SetMediaTypeInternal(mediaType) : E_FAIL;
    }

    STDMETHODIMP RegisterThreads(DWORD taskIndex, LPCWSTR className) override {
        LogFormat(L"IPhoneCameraSource::RegisterThreads task=%u class=%s", taskIndex, className ? className : L"");
        return S_OK;
    }

    STDMETHODIMP RegisterThreadsEx(DWORD* taskIndex, LPCWSTR className, LONG basePriority) override {
        LogFormat(L"IPhoneCameraSource::RegisterThreadsEx task=%u class=%s priority=%ld", taskIndex ? *taskIndex : 0, className ? className : L"", basePriority);
        if (taskIndex && *taskIndex == 0) *taskIndex = MFASYNC_CALLBACK_QUEUE_MULTITHREADED;
        return S_OK;
    }

    STDMETHODIMP UnregisterThreads() override {
        LogLine(L"IPhoneCameraSource::UnregisterThreads");
        return S_OK;
    }

    STDMETHODIMP SetDefaultAllocator(DWORD outputStreamId, IUnknown* allocator) override {
        LogFormat(L"IPhoneCameraSource::SetDefaultAllocator stream=%u allocator=%p", outputStreamId, allocator);
        return stream_ ? stream_->SetAllocator(allocator) : E_FAIL;
    }

    STDMETHODIMP GetAllocatorUsage(DWORD outputStreamId, DWORD* inputStreamId, MFSampleAllocatorUsage* usage) override {
        LogFormat(L"IPhoneCameraSource::GetAllocatorUsage stream=%u", outputStreamId);
        if (!inputStreamId || !usage) return E_POINTER;
        *inputStreamId = 0;
        *usage = MFSampleAllocatorUsage_UsesProvidedAllocator;
        return S_OK;
    }

    STDMETHODIMP SetWorkQueue(DWORD workQueueId) override {
        LogFormat(L"IPhoneCameraSource::SetWorkQueue queue=%u", workQueueId);
        workQueueId_ = workQueueId;
        return S_OK;
    }

    STDMETHODIMP SetWorkQueueEx(DWORD workQueueId, LONG basePriority) override {
        LogFormat(L"IPhoneCameraSource::SetWorkQueueEx queue=%u priority=%ld", workQueueId, basePriority);
        workQueueId_ = workQueueId;
        return S_OK;
    }

    STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** descriptor) override {
        LogLine(L"IPhoneCameraSource::CreatePresentationDescriptor");
        if (!descriptor) return E_POINTER;
        *descriptor = nullptr;
        if (state_ == SourceState::Shutdown) return MF_E_SHUTDOWN;
        if (!presentationDescriptor_) return MF_E_NOT_INITIALIZED;
        HRESULT hr = presentationDescriptor_->Clone(descriptor);
        if (SUCCEEDED(hr) && *descriptor) LogAttributes(L"Presentation descriptor clone attributes", *descriptor);
        LogHResult(L"IPhoneCameraSource::CreatePresentationDescriptor", hr);
        return hr;
    }

    STDMETHODIMP Start(IMFPresentationDescriptor* descriptor, const GUID* timeFormat, const PROPVARIANT* startPosition) override {
        LogLine(L"IPhoneCameraSource::Start");
        if (state_ == SourceState::Shutdown) return MF_E_SHUTDOWN;
        if (timeFormat && *timeFormat != GUID_NULL) return MF_E_UNSUPPORTED_TIME_FORMAT;

        IMFPresentationDescriptor* descriptorToUse = descriptor ? descriptor : presentationDescriptor_;
        if (!descriptorToUse) return E_INVALIDARG;
        BOOL selected = FALSE;
        IMFStreamDescriptor* selectedDescriptor = nullptr;
        HRESULT hr = descriptorToUse->GetStreamDescriptorByIndex(0, &selected, &selectedDescriptor);
        if (selectedDescriptor) selectedDescriptor->Release();
        LogFormat(L"IPhoneCameraSource::Start stream selected=%u previous_state=%u", selected ? 1 : 0, static_cast<unsigned int>(state_));
        if (SUCCEEDED(hr) && !selected) hr = MF_E_INVALIDREQUEST;

        PROPVARIANT empty;
        PropVariantInit(&empty);
        const PROPVARIANT* value = startPosition ? startPosition : &empty;
        if (SUCCEEDED(hr) && stream_) {
            const MediaEventType streamEvent = streamDelivered_ ? MEUpdatedStream : MENewStream;
            LogFormat(L"IPhoneCameraSource::Start queueing %s", streamDelivered_ ? L"MEUpdatedStream" : L"MENewStream");
            hr = eventQueue_->QueueEventParamUnk(streamEvent, GUID_NULL, S_OK, static_cast<IMFMediaStream*>(stream_));
            if (SUCCEEDED(hr)) streamDelivered_ = true;
        }
        if (SUCCEEDED(hr)) hr = eventQueue_->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, value);
        if (SUCCEEDED(hr) && stream_) hr = stream_->Start(value);
        if (SUCCEEDED(hr)) state_ = SourceState::Started;
        LogHResult(L"IPhoneCameraSource::Start", hr);
        return hr;
    }

    STDMETHODIMP Stop() override {
        LogLine(L"IPhoneCameraSource::Stop");
        if (state_ == SourceState::Shutdown) return MF_E_SHUTDOWN;
        if (state_ == SourceState::Stopped) return S_OK;
        PROPVARIANT empty;
        PropVariantInit(&empty);
        HRESULT hr = eventQueue_->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, &empty);
        if (SUCCEEDED(hr) && stream_) hr = stream_->Stop();
        if (SUCCEEDED(hr)) state_ = SourceState::Stopped;
        LogHResult(L"IPhoneCameraSource::Stop", hr);
        return hr;
    }

    STDMETHODIMP Pause() override {
        LogLine(L"IPhoneCameraSource::Pause unsupported");
        return state_ == SourceState::Shutdown ? MF_E_SHUTDOWN : MF_E_INVALID_STATE_TRANSITION;
    }

    STDMETHODIMP Shutdown() override {
        LogLine(L"IPhoneCameraSource::Shutdown");
        if (state_ == SourceState::Shutdown) return S_OK;
        state_ = SourceState::Shutdown;
        if (stream_) stream_->Shutdown();
        if (eventQueue_) eventQueue_->Shutdown();
        return S_OK;
    }

private:
    HRESULT CreateDefaultPresentationDescriptor() {
        IMFStreamDescriptor* streamDescriptor = nullptr;
        HRESULT hr = stream_ ? stream_->GetStreamDescriptor(&streamDescriptor) : E_OUTOFMEMORY;
        if (SUCCEEDED(hr)) hr = MFCreatePresentationDescriptor(1, &streamDescriptor, &presentationDescriptor_);
        if (SUCCEEDED(hr)) hr = presentationDescriptor_->SelectStream(0);
        if (SUCCEEDED(hr) && presentationDescriptor_) LogAttributes(L"Default presentation descriptor attributes", presentationDescriptor_);
        if (streamDescriptor) streamDescriptor->Release();
        LogHResult(L"IPhoneCameraSource::CreateDefaultPresentationDescriptor", hr);
        return hr;
    }

    std::atomic<long> refCount_;
    SourceState state_ = SourceState::Stopped;
    IMFMediaEventQueue* eventQueue_ = nullptr;
    IMFPresentationDescriptor* presentationDescriptor_ = nullptr;
    DWORD workQueueId_ = MFASYNC_CALLBACK_QUEUE_UNDEFINED;
    bool streamDelivered_ = false;
    IPhoneCameraStream* stream_ = nullptr;
};

class IPhoneCameraActivate final : public IMFActivate {
public:
    IPhoneCameraActivate() : refCount_(1) {
        g_objectCount.fetch_add(1);
        if (SUCCEEDED(MFCreateAttributes(&attributes_, 10)) && attributes_) {
            attributes_->SetString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, L"iPhone Camera");
            attributes_->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
            attributes_->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_CATEGORY, KSCATEGORY_VIDEO_CAMERA);
            attributes_->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_PROVIDER_DEVICE_ID, L"IPhoneCameraStreaming");
            attributes_->SetUINT32(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_MAX_BUFFERS, 3);
            attributes_->SetUINT32(MF_LOW_LATENCY, TRUE);
            attributes_->SetUINT32(MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, FALSE);
            LogAttributes(L"Activate initial attributes", attributes_);
        }
    }
    ~IPhoneCameraActivate() { if (attributes_) attributes_->Release(); g_objectCount.fetch_sub(1); }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        LogGuid(L"IPhoneCameraActivate::QueryInterface", riid);
        if (!object) return E_POINTER;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == __uuidof(IMFActivate) || riid == __uuidof(IMFAttributes)) {
            *object = static_cast<IMFActivate*>(this);
            AddRef();
            return S_OK;
        }
        LogGuid(L"IPhoneCameraActivate::QueryInterface unsupported", riid);
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(refCount_.fetch_add(1) + 1); }
    STDMETHODIMP_(ULONG) Release() override { const ULONG count = static_cast<ULONG>(refCount_.fetch_sub(1) - 1); if (count == 0) delete this; return count; }
    STDMETHODIMP ActivateObject(REFIID riid, void** object) override {
        LogGuid(L"IPhoneCameraActivate::ActivateObject", riid);
        auto* source = new (std::nothrow) IPhoneCameraSource();
        if (!source) return E_OUTOFMEMORY;
        HRESULT hr = source->QueryInterface(riid, object);
        LogHResult(L"IPhoneCameraActivate::ActivateObject", hr);
        source->Release();
        return hr;
    }
    STDMETHODIMP ShutdownObject() override { return S_OK; }
    STDMETHODIMP DetachObject() override { return E_NOTIMPL; }

    STDMETHODIMP GetItem(REFGUID key, PROPVARIANT* value) override { LogGuid(L"IPhoneCameraActivate::GetItem", key); HRESULT hr = attributes_->GetItem(key, value); LogHResult(L"IPhoneCameraActivate::GetItem", hr); return hr; }
    STDMETHODIMP GetItemType(REFGUID key, MF_ATTRIBUTE_TYPE* type) override { LogGuid(L"IPhoneCameraActivate::GetItemType", key); HRESULT hr = attributes_->GetItemType(key, type); LogHResult(L"IPhoneCameraActivate::GetItemType", hr); return hr; }
    STDMETHODIMP CompareItem(REFGUID key, REFPROPVARIANT value, BOOL* result) override { LogGuid(L"IPhoneCameraActivate::CompareItem", key); HRESULT hr = attributes_->CompareItem(key, value, result); LogHResult(L"IPhoneCameraActivate::CompareItem", hr); return hr; }
    STDMETHODIMP Compare(IMFAttributes* theirs, MF_ATTRIBUTES_MATCH_TYPE matchType, BOOL* result) override { LogFormat(L"IPhoneCameraActivate::Compare matchType=%u", matchType); HRESULT hr = attributes_->Compare(theirs, matchType, result); LogHResult(L"IPhoneCameraActivate::Compare", hr); return hr; }
    STDMETHODIMP GetUINT32(REFGUID key, UINT32* value) override { LogGuid(L"IPhoneCameraActivate::GetUINT32", key); HRESULT hr = attributes_->GetUINT32(key, value); if (SUCCEEDED(hr) && value) LogFormat(L"IPhoneCameraActivate::GetUINT32 value=%u", *value); LogHResult(L"IPhoneCameraActivate::GetUINT32", hr); return hr; }
    STDMETHODIMP GetUINT64(REFGUID key, UINT64* value) override { LogGuid(L"IPhoneCameraActivate::GetUINT64", key); HRESULT hr = attributes_->GetUINT64(key, value); LogHResult(L"IPhoneCameraActivate::GetUINT64", hr); return hr; }
    STDMETHODIMP GetDouble(REFGUID key, double* value) override { LogGuid(L"IPhoneCameraActivate::GetDouble", key); HRESULT hr = attributes_->GetDouble(key, value); LogHResult(L"IPhoneCameraActivate::GetDouble", hr); return hr; }
    STDMETHODIMP GetGUID(REFGUID key, GUID* value) override { LogGuid(L"IPhoneCameraActivate::GetGUID", key); HRESULT hr = attributes_->GetGUID(key, value); if (SUCCEEDED(hr) && value) LogGuid(L"IPhoneCameraActivate::GetGUID value", *value); LogHResult(L"IPhoneCameraActivate::GetGUID", hr); return hr; }
    STDMETHODIMP GetStringLength(REFGUID key, UINT32* length) override { LogGuid(L"IPhoneCameraActivate::GetStringLength", key); HRESULT hr = attributes_->GetStringLength(key, length); if (SUCCEEDED(hr) && length) LogFormat(L"IPhoneCameraActivate::GetStringLength value=%u", *length); LogHResult(L"IPhoneCameraActivate::GetStringLength", hr); return hr; }
    STDMETHODIMP GetString(REFGUID key, LPWSTR value, UINT32 size, UINT32* length) override { LogGuid(L"IPhoneCameraActivate::GetString", key); HRESULT hr = attributes_->GetString(key, value, size, length); LogHResult(L"IPhoneCameraActivate::GetString", hr); return hr; }
    STDMETHODIMP GetAllocatedString(REFGUID key, LPWSTR* value, UINT32* length) override { LogGuid(L"IPhoneCameraActivate::GetAllocatedString", key); HRESULT hr = attributes_->GetAllocatedString(key, value, length); if (SUCCEEDED(hr) && value && *value) LogFormat(L"IPhoneCameraActivate::GetAllocatedString value=\"%s\"", *value); LogHResult(L"IPhoneCameraActivate::GetAllocatedString", hr); return hr; }
    STDMETHODIMP GetBlobSize(REFGUID key, UINT32* size) override { LogGuid(L"IPhoneCameraActivate::GetBlobSize", key); HRESULT hr = attributes_->GetBlobSize(key, size); LogHResult(L"IPhoneCameraActivate::GetBlobSize", hr); return hr; }
    STDMETHODIMP GetBlob(REFGUID key, UINT8* value, UINT32 size, UINT32* blobSize) override { LogGuid(L"IPhoneCameraActivate::GetBlob", key); HRESULT hr = attributes_->GetBlob(key, value, size, blobSize); LogHResult(L"IPhoneCameraActivate::GetBlob", hr); return hr; }
    STDMETHODIMP GetAllocatedBlob(REFGUID key, UINT8** value, UINT32* size) override { LogGuid(L"IPhoneCameraActivate::GetAllocatedBlob", key); HRESULT hr = attributes_->GetAllocatedBlob(key, value, size); LogHResult(L"IPhoneCameraActivate::GetAllocatedBlob", hr); return hr; }
    STDMETHODIMP GetUnknown(REFGUID key, REFIID riid, LPVOID* unknown) override { LogGuid(L"IPhoneCameraActivate::GetUnknown key", key); LogGuid(L"IPhoneCameraActivate::GetUnknown riid", riid); HRESULT hr = attributes_->GetUnknown(key, riid, unknown); LogHResult(L"IPhoneCameraActivate::GetUnknown", hr); return hr; }
    STDMETHODIMP SetItem(REFGUID key, REFPROPVARIANT value) override { return attributes_->SetItem(key, value); }
    STDMETHODIMP DeleteItem(REFGUID key) override { return attributes_->DeleteItem(key); }
    STDMETHODIMP DeleteAllItems() override { return attributes_->DeleteAllItems(); }
    STDMETHODIMP SetUINT32(REFGUID key, UINT32 value) override { return attributes_->SetUINT32(key, value); }
    STDMETHODIMP SetUINT64(REFGUID key, UINT64 value) override { return attributes_->SetUINT64(key, value); }
    STDMETHODIMP SetDouble(REFGUID key, double value) override { return attributes_->SetDouble(key, value); }
    STDMETHODIMP SetGUID(REFGUID key, REFGUID value) override { return attributes_->SetGUID(key, value); }
    STDMETHODIMP SetString(REFGUID key, LPCWSTR value) override { return attributes_->SetString(key, value); }
    STDMETHODIMP SetBlob(REFGUID key, const UINT8* value, UINT32 size) override { return attributes_->SetBlob(key, value, size); }
    STDMETHODIMP SetUnknown(REFGUID key, IUnknown* unknown) override { return attributes_->SetUnknown(key, unknown); }
    STDMETHODIMP LockStore() override { return attributes_->LockStore(); }
    STDMETHODIMP UnlockStore() override { return attributes_->UnlockStore(); }
    STDMETHODIMP GetCount(UINT32* count) override { return attributes_->GetCount(count); }
    STDMETHODIMP GetItemByIndex(UINT32 index, GUID* key, PROPVARIANT* value) override { return attributes_->GetItemByIndex(index, key, value); }
    STDMETHODIMP CopyAllItems(IMFAttributes* destination) override { return attributes_->CopyAllItems(destination); }
private:
    std::atomic<long> refCount_;
    IMFAttributes* attributes_ = nullptr;
};

class ClassFactory final : public IClassFactory {
public:
    ClassFactory() : refCount_(1) {}
    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        LogGuid(L"ClassFactory::QueryInterface", riid);
        if (!object) return E_POINTER;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == IID_IClassFactory) { *object = static_cast<IClassFactory*>(this); AddRef(); return S_OK; }
        LogGuid(L"ClassFactory::QueryInterface unsupported", riid);
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(refCount_.fetch_add(1) + 1); }
    STDMETHODIMP_(ULONG) Release() override { const ULONG count = static_cast<ULONG>(refCount_.fetch_sub(1) - 1); if (count == 0) delete this; return count; }
    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** object) override {
        LogGuid(L"ClassFactory::CreateInstance", riid);
        if (outer) return CLASS_E_NOAGGREGATION;
        if (riid == __uuidof(IMFMediaSource) || riid == __uuidof(IMFMediaSourceEx) || riid == __uuidof(IMFMediaEventGenerator)) {
            auto* source = new (std::nothrow) IPhoneCameraSource();
            if (!source) return E_OUTOFMEMORY;
            HRESULT hr = source->QueryInterface(riid, object);
            source->Release();
            return hr;
        }
        auto* activate = new (std::nothrow) IPhoneCameraActivate();
        if (!activate) return E_OUTOFMEMORY;
        HRESULT hr = activate->QueryInterface(riid, object);
        activate->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL lock) override { if (lock) g_lockCount.fetch_add(1); else g_lockCount.fetch_sub(1); return S_OK; }
private:
    std::atomic<long> refCount_;
};

HRESULT SetStringValue(HKEY root, const wchar_t* registryPath, const wchar_t* name, const wchar_t* value) {
    HKEY key = nullptr;
    LONG result = RegCreateKeyExW(root, registryPath, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
    if (result != ERROR_SUCCESS) return HRESULT_FROM_WIN32(result);
    result = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value), static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(result);
}

HRESULT RegisterServer() {
    wchar_t modulePath[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_module, modulePath, MAX_PATH)) return HRESULT_FROM_WIN32(GetLastError());
    const wchar_t* clsidPath = L"Software\\Classes\\CLSID\\{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}";
    HRESULT hr = SetStringValue(HKEY_CURRENT_USER, clsidPath, nullptr, L"iPhone Camera Source");
    wchar_t inprocPath[256] = {};
    StringCchCopyW(inprocPath, 256, clsidPath);
    StringCchCatW(inprocPath, 256, L"\\InprocServer32");
    if (SUCCEEDED(hr)) hr = SetStringValue(HKEY_CURRENT_USER, inprocPath, nullptr, modulePath);
    if (SUCCEEDED(hr)) hr = SetStringValue(HKEY_CURRENT_USER, inprocPath, L"ThreadingModel", L"Both");
    return hr;
}

HRESULT UnregisterServer() { RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Classes\\CLSID\\{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}"); return S_OK; }

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** object) {
    LogGuid(L"DllGetClassObject clsid", clsid);
    LogGuid(L"DllGetClassObject riid", riid);
    if (clsid != CLSID_IPhoneCameraSource) return CLASS_E_CLASSNOTAVAILABLE;
    auto* factory = new (std::nothrow) ClassFactory();
    if (!factory) return E_OUTOFMEMORY;
    HRESULT hr = factory->QueryInterface(riid, object);
    factory->Release();
    return hr;
}

STDAPI DllCanUnloadNow() { return (g_objectCount.load() == 0 && g_lockCount.load() == 0) ? S_OK : S_FALSE; }
STDAPI DllRegisterServer() { return RegisterServer(); }
STDAPI DllUnregisterServer() { return UnregisterServer(); }

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { g_module = module; DisableThreadLibraryCalls(module); LogLine(L"DllMain attach"); }
    return TRUE;
}
