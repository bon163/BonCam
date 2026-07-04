// Enumerates video capture devices via DirectShow (CLSID_VideoInputDeviceCategory),
// which is how WebRTC-based apps like Discord discover cameras on Windows.
// Also binds the iPhone Camera filter and lists its output pin formats.
#include <Windows.h>
#include <dshow.h>
#include <iostream>

#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

int wmain() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::wcout << L"CoInitializeEx hr=0x" << std::hex << hr << std::dec << std::endl;

    ICreateDevEnum* devEnum = nullptr;
    hr = CoCreateInstance(CLSID_SystemDeviceEnum, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&devEnum));
    if (FAILED(hr)) { std::wcout << L"CoCreateInstance SystemDeviceEnum failed hr=0x" << std::hex << hr << std::endl; return 1; }

    IEnumMoniker* enumMoniker = nullptr;
    hr = devEnum->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, &enumMoniker, 0);
    std::wcout << L"CreateClassEnumerator hr=0x" << std::hex << hr << std::dec << std::endl;
    if (hr != S_OK) { std::wcout << L"No video input devices." << std::endl; return 1; }

    IMoniker* moniker = nullptr;
    int index = 0;
    IBaseFilter* targetFilter = nullptr;
    while (enumMoniker->Next(1, &moniker, nullptr) == S_OK) {
        IPropertyBag* bag = nullptr;
        if (SUCCEEDED(moniker->BindToStorage(nullptr, nullptr, IID_PPV_ARGS(&bag)))) {
            VARIANT name;
            VariantInit(&name);
            if (SUCCEEDED(bag->Read(L"FriendlyName", &name, nullptr))) {
                std::wcout << L"Device " << index << L": " << name.bstrVal << std::endl;
                if (wcsstr(name.bstrVal, L"iPhone Camera") && !targetFilter) {
                    HRESULT bindHr = moniker->BindToObject(nullptr, nullptr, IID_PPV_ARGS(&targetFilter));
                    std::wcout << L"  BindToObject hr=0x" << std::hex << bindHr << std::dec << std::endl;
                }
                VariantClear(&name);
            }
            bag->Release();
        }
        moniker->Release();
        ++index;
    }
    enumMoniker->Release();
    devEnum->Release();

    if (!targetFilter) {
        std::wcout << L"iPhone Camera not visible to DirectShow." << std::endl;
        return 1;
    }

    IEnumPins* pins = nullptr;
    if (SUCCEEDED(targetFilter->EnumPins(&pins))) {
        IPin* pin = nullptr;
        while (pins->Next(1, &pin, nullptr) == S_OK) {
            PIN_INFO info = {};
            if (SUCCEEDED(pin->QueryPinInfo(&info))) {
                std::wcout << L"Pin: " << info.achName << L" direction=" << (info.dir == PINDIR_OUTPUT ? L"out" : L"in") << std::endl;
                if (info.pFilter) info.pFilter->Release();
            }
            IEnumMediaTypes* types = nullptr;
            if (SUCCEEDED(pin->EnumMediaTypes(&types))) {
                AM_MEDIA_TYPE* type = nullptr;
                int typeIndex = 0;
                while (types->Next(1, &type, nullptr) == S_OK) {
                    WCHAR sub[64] = {};
                    StringFromGUID2(type->subtype, sub, 64);
                    LONG width = 0, height = 0;
                    if (type->formattype == FORMAT_VideoInfo && type->pbFormat) {
                        auto* vih = reinterpret_cast<VIDEOINFOHEADER*>(type->pbFormat);
                        width = vih->bmiHeader.biWidth;
                        height = vih->bmiHeader.biHeight;
                    }
                    std::wcout << L"  MediaType " << typeIndex++ << L": subtype=" << sub << L" size=" << width << L"x" << height << std::endl;
                    if (type->pbFormat) CoTaskMemFree(type->pbFormat);
                    if (type->pUnk) type->pUnk->Release();
                    CoTaskMemFree(type);
                }
                types->Release();
            }
            pin->Release();
        }
        pins->Release();
    }
    targetFilter->Release();
    CoUninitialize();
    return 0;
}
