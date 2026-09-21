#import "BrowsemiumCEF.h"

#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_command_line.h"
#include "include/cef_process_message.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_values.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

/// The script the renderer installs in every page. Chromium, like WebKit, has
/// no per-tab "is playing audio" callback that a client can use, so the page
/// reports its own media state and the renderer forwards it to the browser.
const char kAudioMessageName[] = "browsemiumAudio";

const char kAudioMonitorScript[] = R"JS(
(function() {
  if (window.__browsemiumAudioInstalled) { return; }
  window.__browsemiumAudioInstalled = true;
  window.__browsemiumContexts = window.__browsemiumContexts || [];
  window.__browsemiumCaptureStreams = window.__browsemiumCaptureStreams || [];
  window.__browsemiumMuted = window.__browsemiumMuted || false;

  try {
    var Original = window.AudioContext || window.webkitAudioContext;
    if (Original && !Original.__browsemiumPatched) {
      var Patched = function() {
        var ctx = new (Function.prototype.bind.apply(Original, [null].concat(Array.prototype.slice.call(arguments))))();
        window.__browsemiumContexts.push(ctx);
        return ctx;
      };
      Patched.prototype = Original.prototype;
      Patched.__browsemiumPatched = true;
      window.AudioContext = Patched;
      window.webkitAudioContext = Patched;
    }
  } catch (error) {}

  try {
    var devices = navigator.mediaDevices;
    if (devices && !devices.__browsemiumPatched) {
      var remember = function(promise) {
        return promise.then(function(stream) {
          try {
            window.__browsemiumCaptureStreams.push(stream);
            (stream.getTracks ? stream.getTracks() : []).forEach(function(track) {
              track.addEventListener('ended', function() { window.__browsemiumReportAudio(); });
            });
            window.__browsemiumReportAudio();
          } catch (error) {}
          return stream;
        });
      };
      var wrap = function(name) {
        var original = devices[name];
        if (typeof original !== 'function') { return; }
        devices[name] = function(constraints) { return remember(original.call(devices, constraints)); };
      };
      wrap('getUserMedia');
      wrap('getDisplayMedia');
      devices.__browsemiumPatched = true;
    }
  } catch (error) {}

  window.__browsemiumReportAudio = function() {
    var playing = false;
    var media = document.querySelectorAll('audio, video');
    for (var i = 0; i < media.length; i++) {
      var el = media[i];
      if (!el.paused && !el.ended && el.volume > 0 && !el.muted) { playing = true; break; }
    }
    if (!playing && !window.__browsemiumMuted) {
      playing = window.__browsemiumContexts.some(function(ctx) { return ctx.state === 'running'; });
    }
    var capturing = false;
    try {
      capturing = window.__browsemiumCaptureStreams.some(function(stream) {
        return (stream.getTracks ? stream.getTracks() : []).some(function(track) {
          return track.readyState === 'live';
        });
      });
    } catch (error) {}
    window.__browsemiumAudioState = { playing: playing, capturing: capturing };
    if (window.__browsemiumSendAudioState) { window.__browsemiumSendAudioState(playing, capturing); }
  };

  window.__browsemiumSetMuted = function(muted) {
    window.__browsemiumMuted = !!muted;
    var media = document.querySelectorAll('audio, video');
    for (var i = 0; i < media.length; i++) {
      try { media[i].muted = !!muted; } catch (error) {}
    }
    window.__browsemiumContexts.forEach(function(ctx) {
      try {
        if (muted && ctx.state === 'running') { ctx.suspend(); }
        else if (!muted && ctx.state === 'suspended') { ctx.resume(); }
      } catch (error) {}
    });
    window.__browsemiumReportAudio();
  };

  ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadeddata'].forEach(function(event) {
    document.addEventListener(event, function() { window.__browsemiumReportAudio(); }, true);
  });
  document.addEventListener('visibilitychange', function() { window.__browsemiumReportAudio(); });
})();
)JS";

/// Receives the page's audio reports inside the renderer and forwards them to
/// the browser process, which is the only place that owns the tab UI.
class BrowsemiumAudioStateHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    const bool playing = arguments.size() > 0 && arguments[0]->IsBool() && arguments[0]->GetBoolValue();
    const bool capturing = arguments.size() > 1 && arguments[1]->IsBool() && arguments[1]->GetBoolValue();
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kAudioMessageName);
    CefRefPtr<CefListValue> arguments_list = message->GetArgumentList();
    arguments_list->SetBool(0, playing);
    arguments_list->SetBool(1, capturing);
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    if (context && context->GetFrame()) {
      context->GetFrame()->SendProcessMessage(PID_BROWSER, message);
    }
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowsemiumAudioStateHandler);
};

/// Renderer-side handler: installs the audio monitor and forwards its reports.
class BrowsemiumRenderProcessHandler : public CefRenderProcessHandler {
 public:
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!frame->IsMain()) {
      return;
    }
    // The page's script needs a way back to the browser process; the binding is
    // created before the script runs so nothing is missed.
    CefRefPtr<CefV8Value> global = context->GetGlobal();
    if (global && !global->HasValue("__browsemiumSendAudioState")) {
      CefRefPtr<CefV8Value> function = CefV8Value::CreateFunction(
          "__browsemiumSendAudioState", new BrowsemiumAudioStateHandler());
      global->SetValue("__browsemiumSendAudioState", function, V8_PROPERTY_ATTRIBUTE_READONLY);
    }
    frame->ExecuteJavaScript(kAudioMonitorScript, frame->GetURL(), 0);
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {}

  void OnWebKitInitialized() override {}

 private:
  IMPLEMENT_REFCOUNTING(BrowsemiumRenderProcessHandler);
};

}  // namespace

namespace {

/// CEF's command line, before Chromium parses it. This is where the product's
/// privacy promise is kept: Chromium would otherwise fetch variations,
/// component updates, and Safe Browsing lists on its own.
void ApplyProductSwitches(CefRefPtr<CefCommandLine> command_line) {
  command_line->AppendSwitch("disable-background-networking");
  command_line->AppendSwitch("disable-component-update");
  command_line->AppendSwitch("disable-domain-reliability");
  command_line->AppendSwitch("disable-sync");
  command_line->AppendSwitch("no-service-autorun");
  command_line->AppendSwitch("disable-client-side-phishing-detection");
  command_line->AppendSwitch("disable-breakpad");
  command_line->AppendSwitch("disable-crash-reporter");
  command_line->AppendSwitch("no-default-browser-check");
  command_line->AppendSwitch("no-first-run");
  // Memory: no spare renderer waiting in the background, and no back/forward
  // cache holding whole pages. Both are pure overhead for a browser whose whole
  // promise is that unused tabs cost nothing.
  command_line->AppendSwitchWithValue(
      "disable-features",
      "SpareRendererForSitePerProcess,BackForwardCache,MediaRouter,"
      "OptimizationHints,Translate,CalculateNativeWinOcclusion,"
      "AutofillServerCommunication,InterestFeedContentSuggestions");
}

class BrowsemiumApp : public CefApp,
                      public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    if (!render_process_handler_) {
      render_process_handler_ = new BrowsemiumRenderProcessHandler();
    }
    return render_process_handler_;
  }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty()) {
      ApplyProductSwitches(command_line);
    }
  }

  /// CEF asks to be pumped from the application's own run loop. SwiftUI owns
  /// the main thread, so the work is scheduled on the main queue instead of
  /// letting CEF run its own blocking loop.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

  void OnContextInitialized() override {}

 private:
  CefRefPtr<BrowsemiumRenderProcessHandler> render_process_handler_;
  IMPLEMENT_REFCOUNTING(BrowsemiumApp);
};

BrowsemiumApp* g_app = nullptr;
CefScopedLibraryLoader* g_library_loader = nullptr;
bool g_initialized = false;

void BrowsemiumApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  static int pumpCount = 0;
  pumpCount += 1;
  if (pumpCount <= 20 || pumpCount % 100 == 0) {
    NSLog(@"[cef] pump #%d delay=%lld", pumpCount, delay_ms);
  }
  const int64_t clamped = delay_ms < 0 ? 0 : delay_ms;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, clamped * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   if (g_initialized) {
                     CefDoMessageLoopWork();
                   }
                 });
}

/// Builds CefMainArgs from the process arguments.
CefMainArgs MakeMainArgs() {
  static std::vector<std::string> storage;
  static std::vector<char*> argv;
  storage.clear();
  argv.clear();
  for (NSString* argument in NSProcessInfo.processInfo.arguments) {
    storage.emplace_back(argument.UTF8String);
  }
  for (std::string& value : storage) {
    argv.push_back(value.data());
  }
  CefMainArgs args(static_cast<int>(argv.size()), argv.data());
  return args;
}

}  // namespace

@implementation BrowsemiumCEFRuntime

+ (BOOL)loadFramework {
  if (g_library_loader != nullptr) {
    return YES;
  }
  g_library_loader = new CefScopedLibraryLoader();
  if (!g_library_loader->LoadInMain()) {
    delete g_library_loader;
    g_library_loader = nullptr;
    return NO;
  }
  return YES;
}

+ (int)executeProcess {
  // A helper process needs the app too: it is what provides the renderer's
  // context handler, which installs the page-side audio monitor.
  CefMainArgs main_args = MakeMainArgs();
  CefRefPtr<BrowsemiumApp> helper_app = new BrowsemiumApp();
  return CefExecuteProcess(main_args, helper_app, nullptr);
}

+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath
                     cachePath:(NSString *)cachePath
                     userAgent:(nullable NSString *)userAgent
                       logPath:(nullable NSString *)logPath
                        error:(NSError **)error {
  if (g_initialized) {
    return YES;
  }
  if (g_library_loader == nullptr) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:@"BrowsemiumCEF"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: @"The CEF framework was not loaded."}];
    }
    return NO;
  }

  CefMainArgs main_args = MakeMainArgs();
  CefSettings settings;
  settings.no_sandbox = false;
  settings.external_message_pump = true;
  settings.multi_threaded_message_loop = false;
  settings.log_severity = getenv("BROWSEMIUM_CEF_VERBOSE") ? LOGSEVERITY_INFO : LOGSEVERITY_WARNING;
  settings.background_color = 0xFFFFFFFF;
  CefString(&settings.locale) = "en-US";
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  CefString(&settings.cache_path) = cachePath.UTF8String;
  if (userAgent.length > 0) {
    CefString(&settings.user_agent) = userAgent.UTF8String;
  }
  if (logPath.length > 0) {
    CefString(&settings.log_file) = logPath.UTF8String;
  }

  g_app = new BrowsemiumApp();
  if (!CefInitialize(main_args, settings, g_app, nullptr)) {
    g_app = nullptr;
    if (error != nullptr) {
      *error = [NSError errorWithDomain:@"BrowsemiumCEF"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey: @"Chromium did not start."}];
    }
    return NO;
  }
  g_initialized = true;
  return YES;
}

+ (BOOL)isRunning {
  return g_initialized;
}

+ (void)shutdown {
  if (!g_initialized) {
    return;
  }
  g_initialized = false;
  CefShutdown();
  g_app = nullptr;
  delete g_library_loader;
  g_library_loader = nullptr;
}

@end

int BrowsemiumCEFHelperMain(int argc, char* argv[]) {
  // A helper process: sandbox first, then the framework, then CEF's own
  // dispatch for renderer, GPU, and utility processes.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefRefPtr<BrowsemiumApp> helper_app = new BrowsemiumApp();
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, helper_app, nullptr);
}
