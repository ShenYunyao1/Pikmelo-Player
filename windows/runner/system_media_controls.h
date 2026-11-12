#ifndef RUNNER_SYSTEM_MEDIA_CONTROLS_H_
#define RUNNER_SYSTEM_MEDIA_CONTROLS_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <winrt/Windows.Media.h>

#include <memory>
#include <optional>

class SystemMediaControls {
 public:
  SystemMediaControls(flutter::BinaryMessenger* messenger, HWND window);
  ~SystemMediaControls();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void Initialize();
  void Update(const flutter::EncodableMap& values);
  void Dispose();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  winrt::event_token seek_token_{};
  bool initialized_ = false;
  bool closing_ = false;
  bool close_requested_ = false;
};

#endif
