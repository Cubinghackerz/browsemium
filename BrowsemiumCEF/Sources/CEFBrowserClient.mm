#import "BrowsemiumCEF.h"
#import "BrowsemiumCEFInternal.h"

#include <map>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"

namespace {

/// Identifier CEF uses for the renderer's audio reports.
const char kAudioMessageName[] = "browsemiumAudio";

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()];
}

std::string ToStdString(NSString* value) {
  return value == nil ? std::string() : std::string(value.UTF8String);
}

}  // namespace

@class BrowsemiumCEFBrowser;

/// Browser-process handlers for one tab.
class BrowsemiumClient : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler,
                         public CefDisplayHandler,
                         public CefRequestHandler,
                         public CefDownloadHandler,
                         public CefPermissionHandler,
                         public CefFindHandler {
 public:
  explicit BrowsemiumClient(BrowsemiumCEFBrowser* owner) : owner_(owner) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

  // MARK: Life span

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidCreate];
    }
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    browser_ = nullptr;
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidClose];
    }
  }

  /// A popup becomes a tab in the window model, exactly like the WebKit
  /// engine's `createWebViewWith` returning nil.
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popup_features,
                     CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidRequestNewWindow:ToNSString(target_url)];
    }
    return true;
  }

  // MARK: Load

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidChangeNavigationStateCanGoBack:canGoBack
                                           canGoForward:canGoForward
                                              isLoading:isLoading];
    }
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (!frame->IsMain()) {
      return;
    }
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidStartLoading];
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int http_status_code) override {
    if (!frame->IsMain()) {
      return;
    }
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidFinishLoadingURL:ToNSString(frame->GetURL())];
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    if (!frame->IsMain() || errorCode == ERR_ABORTED) {
      // Aborted loads are normal navigation flow — the user typed a new URL or
      // hit stop — so they never reach the delegate as failures.
      return;
    }
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidFailLoadingWithMessage:ToNSString(errorText)];
    }
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidChangeProgress:progress];
    }
  }

  // MARK: Display

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidChangeTitle:ToNSString(title)];
    }
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) {
      return;
    }
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidChangeURL:ToNSString(url)];
    }
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidCrash];
    }
  }

  // MARK: Downloads

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      NSString* identifier = [NSString stringWithFormat:@"%d", download_item->GetId()];
      [owner cefBrowserDidStartDownload:identifier
                               filename:ToNSString(suggested_name)
                            destination:nil];
    }
    // The window model owns the destination policy; Chromium writes to the
    // default download directory until that policy is wired through.
    callback->Continue(CefString(), false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner == nil) {
      return;
    }
    std::string identifier = std::to_string(download_item->GetId());
    NSString* failure = download_item->IsCanceled()
        ? @"The download was cancelled."
        : (download_item->IsInterrupted() ? @"The download was interrupted." : nil);
    [owner cefBrowserDidUpdateDownload:ToNSString(CefString(identifier.c_str()))
                         receivedBytes:download_item->GetReceivedBytes()
                            totalBytes:download_item->GetTotalBytes()
                              finished:download_item->IsComplete() || failure != nil
                               failure:failure];
  }

  // MARK: Permissions

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner == nil) {
      callback->Cancel();
      return true;
    }
    NSString* kind = @"microphone";
    const bool wantsVideo = (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0;
    const bool wantsAudio = (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0;
    if (wantsVideo && wantsAudio) {
      kind = @"cameraAndMicrophone";
    } else if (wantsVideo) {
      kind = @"camera";
    }
    [owner cefBrowserRequestsMediaAccessForKind:kind
                                         origin:ToNSString(requesting_origin)
                                     completion:^(BOOL granted) {
                                       if (granted) {
                                         callback->Continue(requested_permissions);
                                       } else {
                                         callback->Cancel();
                                       }
                                     }];
    return true;
  }

  // MARK: Find

  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect& selectionRect,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner == nil || !finalUpdate) {
      return;
    }
    [owner cefBrowserDidFindMatches:count];
  }

  /// Receives the renderer's audio reports.
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (message->GetName() != kAudioMessageName) {
      return false;
    }
    CefRefPtr<CefListValue> arguments = message->GetArgumentList();
    const bool playing = arguments->GetSize() > 0 && arguments->GetBool(0);
    const bool capturing = arguments->GetSize() > 1 && arguments->GetBool(1);
    BrowsemiumCEFBrowser* owner = owner_;
    if (owner != nil) {
      [owner cefBrowserDidChangeAudioStatePlaying:playing capturing:capturing];
    }
    return true;
  }

  CefRefPtr<CefBrowser> browser() const { return browser_; }

 private:
  __weak BrowsemiumCEFBrowser* owner_;
  CefRefPtr<CefBrowser> browser_;
  IMPLEMENT_REFCOUNTING(BrowsemiumClient);
};

CefRefPtr<CefClient> BrowsemiumCreateClient(BrowsemiumCEFBrowser* owner) {
  return new BrowsemiumClient(owner);
}
