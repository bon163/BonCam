#include <Windows.h>
#include <mfapi.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksmedia.h>
#include <iostream>
#include <string>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfsensorgroup.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")

// Reserved for the custom Media Foundation source we will build next.
static constexpr wchar_t kIPhoneCameraSourceClsid[] = L"{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}";
static constexpr wchar_t kFriendlyName[] = L"iPhone Camera";

std::wstring HResultText(HRESULT hr) {
    wchar_t* message = nullptr;
    FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        static_cast<DWORD>(hr),
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPWSTR>(&message),
        0,
        nullptr);

    std::wstring result = message ? message : L"Unknown error";
    if (message) {
        LocalFree(message);
    }
    return result;
}

void Check(HRESULT hr, const wchar_t* step) {
    if (FAILED(hr)) {
        std::wcerr << step << L" failed: 0x" << std::hex << hr << L" - " << HResultText(hr) << std::endl;
        ExitProcess(static_cast<UINT>(hr));
    }
}


bool IsElevated() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
    TOKEN_ELEVATION elevation = {};
    DWORD size = 0;
    const BOOL ok = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size);
    CloseHandle(token);
    return ok && elevation.TokenIsElevated != 0;
}

IMFVirtualCamera* OpenVirtualCamera(MFVirtualCameraAccess access, MFVirtualCameraLifetime lifetime) {
    IMFVirtualCamera* camera = nullptr;
    GUID categories[] = { KSCATEGORY_VIDEO_CAMERA, KSCATEGORY_VIDEO, KSCATEGORY_CAPTURE };
    HRESULT hr = MFCreateVirtualCamera(
        MFVirtualCameraType_SoftwareCameraSource,
        lifetime,
        access,
        kFriendlyName,
        kIPhoneCameraSourceClsid,
        categories,
        ARRAYSIZE(categories),
        &camera);
    Check(hr, L"MFCreateVirtualCamera");
    return camera;
}

int wmain(int argc, wchar_t** argv) {
    const std::wstring command = argc > 1 ? argv[1] : L"start";
    const bool allUsers = argc > 2 && std::wstring(argv[2]) == L"all-users";
    const bool systemLifetime = argc > 3 && std::wstring(argv[3]) == L"system";

    Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), L"CoInitializeEx");
    Check(MFStartup(MF_VERSION), L"MFStartup");

    IMFVirtualCamera* camera = OpenVirtualCamera(allUsers ? MFVirtualCameraAccess_AllUsers : MFVirtualCameraAccess_CurrentUser, systemLifetime ? MFVirtualCameraLifetime_System : MFVirtualCameraLifetime_Session);

    if (command == L"start") {
        std::wcout << L"Registering virtual camera: " << kFriendlyName << std::endl;
        std::wcout << L"Access scope: " << (allUsers ? L"all users" : L"current user") << std::endl;
        std::wcout << L"Lifetime: " << (systemLifetime ? L"system" : L"session") << std::endl;
        std::wcout << L"Process elevated: " << (IsElevated() ? L"yes" : L"no") << std::endl;
        std::wcout << L"Camera categories: VIDEO_CAMERA, VIDEO, CAPTURE" << std::endl;
        std::wcout << L"Media source CLSID: " << kIPhoneCameraSourceClsid << std::endl;
        HRESULT startHr = camera->Start(nullptr);
        if (startHr == E_ACCESSDENIED) {
            std::wcerr << L"Access denied. Try running from an Administrator PowerShell window and confirm Windows Settings > Privacy & security > Camera allows camera access and desktop app access." << std::endl;
        }
        Check(startHr, L"IMFVirtualCamera::Start");
        std::wcout << L"Virtual camera registered for this session." << std::endl;
        std::wcout << L"Keep this process running while testing camera enumeration." << std::endl;
        std::wcout << L"Press Enter to stop." << std::endl;
        std::wstring line;
        std::getline(std::wcin, line);
        camera->Stop();
    } else if (command == L"stop") {
        Check(camera->Stop(), L"IMFVirtualCamera::Stop");
        std::wcout << L"Virtual camera stopped." << std::endl;
    } else if (command == L"remove") {
        Check(camera->Remove(), L"IMFVirtualCamera::Remove");
        std::wcout << L"Virtual camera removed." << std::endl;
    } else {
        std::wcerr << L"Usage: register_virtual_camera.exe [start|stop|remove]" << std::endl;
    }

    camera->Release();
    MFShutdown();
    CoUninitialize();
    return 0;
}
