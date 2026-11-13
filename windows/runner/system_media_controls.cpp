#include "system_media_controls.h"

#include <SystemMediaTransportControlsInterop.h>
#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <shobjidl.h>
#include <shellapi.h>

#include <algorithm>
#include <chrono>
#include <string>

namespace {
constexpr UINT kMediaButton = WM_APP + 40;
constexpr UINT kMediaSeek = WM_APP + 41;
constexpr UINT kCloseReady = WM_APP + 42;

template <typename T>
T Value(const flutter::EncodableMap& values, const char* name) {
  return std::get<T>(values.at(flutter::EncodableValue(name)));
}

int64_t Milliseconds(const flutter::EncodableMap& values, const char* name) {
  const auto& value = values.at(flutter::EncodableValue(name));
  if (const auto* number = std::get_if<int32_t>(&value)) return *number;
  return std::get<int64_t>(value);
}
}  // namespace

SystemMediaControls::SystemMediaControls(flutter::BinaryMessenger* messenger,
                                         HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "pikmelo/system_media", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      if (call.method_name() == "initialize") {
        Initialize();
        initialized_ = true;
      } else if (call.method_name() == "update") {
        Update(std::get<flutter::EncodableMap>(*call.arguments()));
      } else if (call.method_name() == "dispose") {
        Dispose();
      } else if (call.method_name() == "chooseDirectory") {
        winrt::com_ptr<IFileOpenDialog> dialog;
        winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(dialog.put())));
        DWORD options;
        winrt::check_hresult(dialog->GetOptions(&options));
        winrt::check_hresult(dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM));
        const HRESULT response = dialog->Show(window_);
        if (response == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
          result->Success();
          return;
        }
        winrt::check_hresult(response);
        winrt::com_ptr<IShellItem> selection;
        winrt::check_hresult(dialog->GetResult(selection.put()));
        PWSTR path = nullptr;
        winrt::check_hresult(selection->GetDisplayName(SIGDN_FILESYSPATH, &path));
        const auto value = winrt::to_string(std::wstring_view(path));
        CoTaskMemFree(path);
        result->Success(flutter::EncodableValue(value));
        return;
      } else if (call.method_name() == "updateInfo") {
        flutter::EncodableMap info;
        info[flutter::EncodableValue("platform")] = flutter::EncodableValue("windows");
        info[flutter::EncodableValue("version")] = flutter::EncodableValue(FLUTTER_VERSION);
        info[flutter::EncodableValue("versionCode")] = flutter::EncodableValue(FLUTTER_VERSION_BUILD);
        info[flutter::EncodableValue("abis")] = flutter::EncodableValue(flutter::EncodableList{flutter::EncodableValue("x86_64")});
        result->Success(flutter::EncodableValue(info));
        return;
      } else if (call.method_name() == "openRelease") {
        const auto url = Value<std::string>(std::get<flutter::EncodableMap>(*call.arguments()), "url");
        if (url.rfind("https://github.com/ShenYunyao1/Pikmelo-Player/releases", 0) != 0) {
          result->Error("update", "Untrusted release URL");
          return;
        }
        const auto response = ShellExecuteW(window_, L"open", winrt::to_hstring(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        if (reinterpret_cast<INT_PTR>(response) <= 32) {
          result->Error("update", "Unable to open the release page");
          return;
        }
        result->Success();
        return;
      } else if (call.method_name() == "network") {
        const auto profile = winrt::Windows::Networking::Connectivity::
            NetworkInformation::GetInternetConnectionProfile();
        flutter::EncodableMap network;
        network[flutter::EncodableValue("connected")] = flutter::EncodableValue(profile != nullptr);
        network[flutter::EncodableValue("cellular")] = flutter::EncodableValue(profile && profile.IsWwanConnectionProfile());
        result->Success(flutter::EncodableValue(network));
        return;
      } else {
        result->NotImplemented();
        return;
      }
      result->Success();
    } catch (const winrt::hresult_error& error) {
      result->Error("smtc", winrt::to_string(error.message()));
    } catch (const std::exception& error) {
      result->Error("smtc", error.what());
    }
  });
}

SystemMediaControls::~SystemMediaControls() {
  Dispose();
  channel_->SetMethodCallHandler(nullptr);
}

void SystemMediaControls::Initialize() {
  if (controls_) return;
  using namespace winrt::Windows::Media;
  const auto interop = winrt::get_activation_factory<
      SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
  winrt::check_hresult(interop->GetForWindow(
      window_, winrt::guid_of<SystemMediaTransportControls>(),
      winrt::put_abi(controls_)));
  controls_.IsEnabled(false);
  controls_.IsPlayEnabled(true);
  controls_.IsPauseEnabled(true);
  controls_.IsNextEnabled(true);
  controls_.IsPreviousEnabled(true);
  controls_.IsStopEnabled(true);
  const HWND window = window_;
  button_token_ = controls_.ButtonPressed([window](const auto&, const auto& args) {
    // WinRT events arrive off the Flutter thread. Marshal callbacks to the window.
    PostMessage(window, kMediaButton, static_cast<WPARAM>(args.Button()), 0);
  });
  seek_token_ = controls_.PlaybackPositionChangeRequested(
      [window](const auto&, const auto& args) {
        const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            args.RequestedPlaybackPosition()).count();
        PostMessage(window, kMediaSeek, 0, static_cast<LPARAM>(milliseconds));
      });
}

void SystemMediaControls::Update(const flutter::EncodableMap& values) {
  if (!controls_) return;
  using namespace winrt::Windows::Media;
  const bool has_media = Value<bool>(values, "hasMedia");
  controls_.IsEnabled(has_media);
  const auto updater = controls_.DisplayUpdater();
  if (!has_media) {
    controls_.PlaybackStatus(MediaPlaybackStatus::Stopped);
    updater.ClearAll();
    updater.Update();
    return;
  }
  updater.Type(MediaPlaybackType::Music);
  updater.MusicProperties().Title(winrt::to_hstring(Value<std::string>(values, "title")));
  updater.MusicProperties().Artist(winrt::to_hstring(Value<std::string>(values, "artist")));
  updater.MusicProperties().AlbumTitle(winrt::to_hstring(Value<std::string>(values, "album")));
  updater.Update();
  controls_.PlaybackStatus(Value<bool>(values, "playing")
                               ? MediaPlaybackStatus::Playing
                               : MediaPlaybackStatus::Paused);
  const int64_t duration = std::max<int64_t>(0, Milliseconds(values, "duration"));
  const int64_t position = std::clamp<int64_t>(Milliseconds(values, "position"), 0, duration);
  SystemMediaTransportControlsTimelineProperties timeline;
  timeline.StartTime(std::chrono::milliseconds(0));
  timeline.EndTime(std::chrono::milliseconds(duration));
  timeline.MinSeekTime(std::chrono::milliseconds(0));
  timeline.MaxSeekTime(std::chrono::milliseconds(duration));
  timeline.Position(std::chrono::milliseconds(position));
  controls_.UpdateTimelineProperties(timeline);
}

void SystemMediaControls::Dispose() {
  initialized_ = false;
  if (!controls_) return;
  controls_.ButtonPressed(button_token_);
  controls_.PlaybackPositionChangeRequested(seek_token_);
  controls_.IsEnabled(false);
  controls_.DisplayUpdater().ClearAll();
  controls_.DisplayUpdater().Update();
  controls_ = nullptr;
}

std::optional<LRESULT> SystemMediaControls::HandleMessage(
    UINT message, WPARAM wparam, LPARAM lparam) {
  using namespace winrt::Windows::Media;
  if (message == kMediaButton) {
    std::string method;
    switch (static_cast<SystemMediaTransportControlsButton>(wparam)) {
      case SystemMediaTransportControlsButton::Play: method = "play"; break;
      case SystemMediaTransportControlsButton::Pause: method = "pause"; break;
      case SystemMediaTransportControlsButton::Next: method = "next"; break;
      case SystemMediaTransportControlsButton::Previous: method = "previous"; break;
      case SystemMediaTransportControlsButton::Stop: method = "stop"; break;
      default: return 0;
    }
    channel_->InvokeMethod(method, nullptr);
    return 0;
  }
  if (message == kMediaSeek) {
    channel_->InvokeMethod("seek", std::make_unique<flutter::EncodableValue>(
        static_cast<int64_t>(lparam)));
    return 0;
  }
  if (message == kCloseReady) {
    closing_ = true;
    PostMessage(window_, WM_CLOSE, 0, 0);
    return 0;
  }
  if (message == WM_CLOSE && initialized_ && !closing_) {
    if (close_requested_) return 0;
    close_requested_ = true;
    const HWND window = window_;
    auto complete = [window]() { PostMessage(window, kCloseReady, 0, 0); };
    channel_->InvokeMethod("close", nullptr,
        std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [complete](const auto*) { complete(); },
            [complete](const auto&, const auto&, const auto*) { complete(); },
            complete));
    return 0;
  }
  return std::nullopt;
}
