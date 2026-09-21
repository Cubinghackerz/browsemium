#import "BrowsemiumCEF.h"
#import "BrowsemiumCEFInternal.h"

#include <map>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_registration.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_task.h"

/// The context handler below fires this when the request context is ready.
@interface BrowsemiumCEFBrowser (RequestContextCallback)
- (void)cefContextInitialized;
@end

namespace {

/// Per-profile request contexts initialize asynchronously: CreateContext
/// returns an object whose browser context is not ready yet, and
/// CreateBrowserSync returns nullptr until it is. This handler delivers
/// OnRequestContextInitialized so the browser is created once the context —
/// and its on-disk profile — actually exists.
class BrowsemiumRequestContextHandler : public CefRequestContextHandler {
 public:
  explicit BrowsemiumRequestContextHandler(BrowsemiumCEFBrowser* owner)
      : owner_(owner) {}

  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context) override {
    NSLog(@"[cef] request context initialized");
    if (BrowsemiumCEFBrowser* owner = owner_) {
      [owner cefContextInitialized];
    }
  }

 private:
  __weak BrowsemiumCEFBrowser* owner_;
  IMPLEMENT_REFCOUNTING(BrowsemiumRequestContextHandler);
};

/// Bridges CEF's JSON values to Objective-C so Swift callers get normal types.
id BrowsemiumObjectFromCefValue(CefRefPtr<CefValue> value) {
  if (!value) {
    return nil;
  }
  switch (value->GetType()) {
    case VTYPE_NULL:
      return [NSNull null];
    case VTYPE_BOOL:
      return @(value->GetBool());
    case VTYPE_INT:
      return @(value->GetInt());
    case VTYPE_DOUBLE:
      return @(value->GetDouble());
    case VTYPE_STRING:
      return [NSString stringWithUTF8String:value->GetString().ToString().c_str()];
    case VTYPE_LIST: {
      CefRefPtr<CefListValue> list = value->GetList();
      NSMutableArray* array = [NSMutableArray arrayWithCapacity:list->GetSize()];
      for (size_t index = 0; index < list->GetSize(); index++) {
        id element = BrowsemiumObjectFromCefValue(list->GetValue(index));
        [array addObject:element ?: [NSNull null]];
      }
      return array;
    }
    case VTYPE_DICTIONARY: {
      CefRefPtr<CefDictionaryValue> dictionary = value->GetDictionary();
      CefDictionaryValue::KeyList keys;
      dictionary->GetKeys(keys);
      NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:keys.size()];
      for (const CefString& key : keys) {
        NSString* name = [NSString stringWithUTF8String:key.ToString().c_str()];
        result[name] = BrowsemiumObjectFromCefValue(dictionary->GetValue(key)) ?: [NSNull null];
      }
      return result;
    }
  }
  return nil;
}

/// Sends DevTools protocol messages to one browser and routes replies back.
/// This is how the app evaluates JavaScript with a result — the CEF API itself
/// only offers fire-and-forget `ExecuteJavaScript`.
class BrowsemiumDevToolsBridge : public CefDevToolsMessageObserver {
 public:
  using Reply = void (^)(id _Nullable result, NSString* _Nullable error);

  void Attach(CefRefPtr<CefBrowserHost> host) {
    browser_host_ = host;
    registration_ = host->AddDevToolsMessageObserver(this);
  }

  void Detach() {
    browser_host_ = nullptr;
    registration_ = nullptr;
    replies_.clear();
  }

  void SendEvaluate(NSString* script, Reply reply) {
    if (!browser_host_) {
      reply(nil, @"The page is not loaded.");
      return;
    }
    const int identifier = ++next_identifier_;
    replies_[identifier] = [reply copy];

    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("expression", script.UTF8String);
    params->SetBool("awaitPromise", true);
    params->SetBool("returnByValue", true);
    params->SetBool("userGesture", true);

    CefRefPtr<CefDictionaryValue> request = CefDictionaryValue::Create();
    request->SetInt("id", identifier);
    request->SetString("method", "Runtime.evaluate");
    request->SetDictionary("params", params);

    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetDictionary(request);
    const std::string json = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
    browser_host_->SendDevToolsMessage(json.data(), json.size());
  }

  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser,
                         const void* message,
                         size_t message_size) override {
    const std::string payload(static_cast<const char*>(message), message_size);
    CefRefPtr<CefValue> parsed = CefParseJSON(CefString(payload), JSON_PARSER_RFC);
    if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
      return false;
    }
    CefRefPtr<CefDictionaryValue> response = parsed->GetDictionary();
    if (!response->HasKey("id")) {
      return false;  // An event, not a reply.
    }
    const int identifier = response->GetInt("id");
    auto entry = replies_.find(identifier);
    if (entry == replies_.end()) {
      return false;
    }
    Reply reply = entry->second;
    replies_.erase(entry);

    if (response->HasKey("error")) {
      CefRefPtr<CefDictionaryValue> error = response->GetDictionary("error");
      NSString* text = [NSString stringWithUTF8String:error->GetString("message").ToString().c_str()];
      reply(nil, text);
      return true;
    }

    id result = BrowsemiumObjectFromCefValue(response->GetValue("result"));
    if ([result isKindOfClass:[NSDictionary class]]) {
      id remote = ((NSDictionary*)result)[@"result"];
      if ([remote isKindOfClass:[NSDictionary class]]) {
        NSDictionary* remoteObject = remote;
        if (remoteObject[@"value"] != nil) {
          reply(remoteObject[@"value"], nil);
          return true;
        }
        if (remoteObject[@"subtype"] != nil) {
          // undefined or null: report the value as nil rather than an error.
          reply(nil, nil);
          return true;
        }
        reply(remoteObject[@"description"], nil);
        return true;
      }
      reply(remote, nil);
      return true;
    }
    reply(result, nil);
    return true;
  }

 private:
  CefRefPtr<CefBrowserHost> browser_host_;
  CefRefPtr<CefRegistration> registration_;
  int next_identifier_ = 0;
  std::map<int, Reply> replies_;
  IMPLEMENT_REFCOUNTING(BrowsemiumDevToolsBridge);
};

}  // namespace

@interface BrowsemiumCEFBrowser () {
  CefRefPtr<CefClient> _client;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefRequestContext> _context;
  CefRefPtr<CefRequestContextHandler> _contextHandler;
  CefRefPtr<BrowsemiumDevToolsBridge> _devTools;
  __weak NSView* _hostView;
  NSString* _title;
  NSString* _pendingURL;
  BOOL _closed;
  BOOL _browserPending;
  int _findIdentifier;
  void (^_findCompletion)(int matchCount, BOOL found);
}
- (void)cefContextInitialized;
@end

@implementation BrowsemiumCEFBrowser

- (instancetype)initWithDelegate:(id<BrowsemiumCEFBrowserDelegate>)delegate
                       cachePath:(NSString*)cachePath {
  self = [super init];
  if (self != nil) {
    _delegate = delegate;
    _closed = NO;
    if (cachePath.length > 0) {
      CefRequestContextSettings settings;
      CefString(&settings.cache_path) = cachePath.UTF8String;
      _contextHandler = new BrowsemiumRequestContextHandler(self);
      _context = CefRequestContext::CreateContext(settings, _contextHandler);
      if (!_context) {
        // Profile creation can reject the path outright; fall back to the
        // global context rather than leaving the tab permanently blank.
        NSLog(@"[cef] CreateContext failed for %@, using global context", cachePath);
        _context = CefRequestContext::GetGlobalContext();
      }
    } else {
      _context = CefRequestContext::GetGlobalContext();
    }
    _client = BrowsemiumCreateClient(self);
    _devTools = new BrowsemiumDevToolsBridge();
  }
  return self;
}

- (void)dealloc {
  [self close];
}

- (void)attachToView:(NSView*)host {
  _hostView = host;
  [self createBrowserIfNeeded];
}

/// CreateBrowserSync returns nullptr while the request context's browser
/// context is still initializing — which it does asynchronously, so the first
/// attach almost always lands before it finishes. Failure is not permanent:
/// `_browserPending` marks the tab, and `cefContextInitialized` retries when
/// OnRequestContextInitialized fires. Frame-change re-attaches retry too, in
/// case the callback ran before the host existed.
- (void)createBrowserIfNeeded {
  if (_browser || !_hostView || _closed) {
    return;
  }
  NSView* host = _hostView;
  CefWindowInfo window_info;
  const CefRect rect(0, 0, (int)MAX(host.bounds.size.width, 1), (int)MAX(host.bounds.size.height, 1));
  window_info.SetAsChild((__bridge void*)host, rect);

  CefBrowserSettings browser_settings;
  browser_settings.background_color = 0xFFFFFFFF;

  static BOOL loggedThread = NO;
  if (!loggedThread) {
    loggedThread = YES;
    NSLog(@"[cef] createBrowser onUIThread=%d", CefCurrentlyOn(TID_UI));
  }
  // Load the pending URL as the initial URL: CreateBrowserSync already owns a
  // navigation slot, and a LoadURL issued in the same runloop turn can be lost
  // while the browser's renderer is still binding to the native view.
  NSString* initial = _pendingURL.length > 0 ? _pendingURL : @"about:blank";
  _pendingURL = nil;
  _browser = CefBrowserHost::CreateBrowserSync(window_info, _client, initial.UTF8String,
                                               browser_settings, nullptr, _context);
  if (_browser) {
    NSLog(@"[cef] browser created, host %.0fx%.0f url=%@",
          host.bounds.size.width, host.bounds.size.height, initial);
    _browserPending = NO;
    _devTools->Attach(_browser->GetHost());
    _browser->GetHost()->WasResized();
  } else {
    NSLog(@"[cef] createBrowser: CreateBrowserSync failed (context not ready yet)");
    _browserPending = YES;
  }
}

/// Called on the UI thread when the request context finishes initializing —
/// the earliest moment CreateBrowserSync can succeed.
- (void)cefContextInitialized {
  if (_browserPending) {
    [self createBrowserIfNeeded];
  }
}

- (void)resizeToBounds:(NSRect)bounds {
  if (_browser) {
    _browser->GetHost()->WasResized();
  }
}

- (void)loadURLString:(NSString*)urlString {
  if (_browser) {
    NSLog(@"[cef] LoadURL %@", urlString);
    _browser->GetMainFrame()->LoadURL(urlString.UTF8String);
  } else {
    NSLog(@"[cef] load deferred (no browser): %@", urlString);
    _pendingURL = [urlString copy];
  }
}

- (void)goBack {
  if (_browser) {
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser) {
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    _browser->Reload();
  }
}

- (void)stopLoading {
  if (_browser) {
    _browser->StopLoad();
  }
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_browser) {
    _browser->GetHost()->SetZoomLevel(zoomLevel);
  }
}

- (void)setMuted:(BOOL)muted {
  if (!_browser) {
    return;
  }
  _browser->GetHost()->SetAudioMuted(muted);
  NSString* script = [NSString stringWithFormat:@"window.__browsemiumSetMuted && window.__browsemiumSetMuted(%@)",
                                                muted ? @"true" : @"false"];
  _browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String, "", 0);
}

- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^)(id _Nullable, NSString* _Nullable))completion {
  if (!_browser || !_devTools) {
    if (completion) {
      completion(nil, @"The page is not loaded.");
    }
    return;
  }
  _devTools->SendEvaluate(script, completion);
}

- (void)findText:(NSString*)text
         forward:(BOOL)forward
      completion:(void (^)(int, BOOL))completion {
  if (!_browser) {
    if (completion) {
      completion(0, NO);
    }
    return;
  }
  _findCompletion = [completion copy];
  _findIdentifier += 1;
  _browser->GetHost()->Find(text.UTF8String, forward, false, _findIdentifier);
}

- (void)close {
  if (_closed) {
    return;
  }
  _closed = YES;
  if (_devTools) {
    _devTools->Detach();
  }
  if (_browser) {
    // Closing the host destroys the renderer process, which is what the memory
    // saver relies on.
    _browser->GetHost()->CloseBrowser(true);
    _browser = nullptr;
  }
}

- (NSString*)currentURL {
  if (!_browser) {
    return nil;
  }
  return [NSString stringWithUTF8String:_browser->GetMainFrame()->GetURL().ToString().c_str()];
}

- (NSString*)title {
  return _title;
}

- (BOOL)isLoading {
  return _browser ? _browser->IsLoading() : NO;
}

- (BOOL)canGoBack {
  return _browser ? _browser->CanGoBack() : NO;
}

- (BOOL)canGoForward {
  return _browser ? _browser->CanGoForward() : NO;
}

- (BOOL)isClosed {
  return _closed;
}

#pragma mark - Client callbacks

- (void)cefBrowserDidCreate {
  NSLog(@"[cef] didCreate: host bounds=%.0fx%.0f",
        _hostView.bounds.size.width, _hostView.bounds.size.height);
  [self resizeToBounds:_hostView.bounds];
}

- (void)cefBrowserDidClose {
  if ([_delegate respondsToSelector:@selector(cefBrowserDidClose:)]) {
    [_delegate cefBrowserDidClose:self];
  }
}

- (void)cefBrowserDidStartLoading {
  if ([_delegate respondsToSelector:@selector(cefBrowserDidStartLoading:)]) {
    [_delegate cefBrowserDidStartLoading:self];
  }
}

- (void)cefBrowserDidFinishLoadingURL:(NSString*)url {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didFinishLoadingURL:)]) {
    [_delegate cefBrowser:self didFinishLoadingURL:url];
  }
}

- (void)cefBrowserDidFailLoadingWithMessage:(NSString*)message {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didFailLoadingWithMessage:)]) {
    [_delegate cefBrowser:self didFailLoadingWithMessage:message];
  }
}

- (void)cefBrowserDidChangeProgress:(double)progress {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didChangeProgress:)]) {
    [_delegate cefBrowser:self didChangeProgress:progress];
  }
}

- (void)cefBrowserDidChangeTitle:(NSString*)title {
  _title = [title copy];
  if ([_delegate respondsToSelector:@selector(cefBrowser:didChangeTitle:)]) {
    [_delegate cefBrowser:self didChangeTitle:title];
  }
}

- (void)cefBrowserDidChangeURL:(NSString*)url {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didChangeURL:)]) {
    [_delegate cefBrowser:self didChangeURL:url];
  }
}

- (void)cefBrowserDidChangeNavigationStateCanGoBack:(BOOL)canGoBack
                                       canGoForward:(BOOL)canGoForward
                                          isLoading:(BOOL)isLoading {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didChangeNavigationStateCanGoBack:canGoForward:isLoading:)]) {
    [_delegate cefBrowser:self
        didChangeNavigationStateCanGoBack:canGoBack
                             canGoForward:canGoForward
                                isLoading:isLoading];
  }
}

- (void)cefBrowserDidChangeAudioStatePlaying:(BOOL)playing capturing:(BOOL)capturing {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didChangeAudioStatePlaying:capturing:)]) {
    [_delegate cefBrowser:self didChangeAudioStatePlaying:playing capturing:capturing];
  }
}

- (void)cefBrowserDidRequestNewWindow:(NSString*)url {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didRequestNewWindowForURL:)]) {
    [_delegate cefBrowser:self didRequestNewWindowForURL:url];
  }
}

- (void)cefBrowserDidCrash {
  if ([_delegate respondsToSelector:@selector(cefBrowserDidCrash:)]) {
    [_delegate cefBrowserDidCrash:self];
  }
}

- (void)cefBrowserDidStartDownload:(NSString*)identifier
                          filename:(NSString*)filename
                       destination:(NSString*)destination {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didStartDownloadWithIdentifier:filename:destination:)]) {
    [_delegate cefBrowser:self
        didStartDownloadWithIdentifier:identifier
                              filename:filename
                             destination:destination];
  }
}

- (void)cefBrowserDidUpdateDownload:(NSString*)identifier
                      receivedBytes:(int64_t)receivedBytes
                         totalBytes:(int64_t)totalBytes
                           finished:(BOOL)finished
                            failure:(NSString*)failure {
  if ([_delegate respondsToSelector:@selector(cefBrowser:didUpdateDownloadWithIdentifier:receivedBytes:totalBytes:finished:failure:)]) {
    [_delegate cefBrowser:self
        didUpdateDownloadWithIdentifier:identifier
                         receivedBytes:receivedBytes
                            totalBytes:totalBytes
                              finished:finished
                               failure:failure];
  }
}

- (void)cefBrowserRequestsMediaAccessForKind:(NSString*)kind
                                      origin:(NSString*)origin
                                  completion:(void (^)(BOOL granted))completion {
  if ([_delegate respondsToSelector:@selector(cefBrowser:requestsMediaAccessForKind:origin:completion:)]) {
    [_delegate cefBrowser:self requestsMediaAccessForKind:kind origin:origin completion:completion];
  } else {
    completion(NO);
  }
}

- (void)cefBrowserDidFindMatches:(int)count {
  if (_findCompletion) {
    void (^completion)(int, BOOL) = _findCompletion;
    _findCompletion = nil;
    completion(count, count > 0);
  }
}

@end
