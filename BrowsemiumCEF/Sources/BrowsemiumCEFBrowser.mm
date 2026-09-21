#import "BrowsemiumCEF.h"
#import "BrowsemiumCEFInternal.h"

#include <map>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_registration.h"
#include "include/cef_request_context.h"

namespace {

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
        CefRefPtr<CefValue> item = CefValue::Create();
        item->SetValue(list->GetValue(index));
        id element = BrowsemiumObjectFromCefValue(item);
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
        CefRefPtr<CefValue> item = CefValue::Create();
        item->SetValue(dictionary->GetValue(key));
        NSString* name = [NSString stringWithUTF8String:key.ToString().c_str()];
        result[name] = BrowsemiumObjectFromCefValue(item) ?: [NSNull null];
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
    browser_host_->SendDevToolsMessage(CefWriteJSON(value, JSON_WRITER_DEFAULT));
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

    CefRefPtr<CefValue> result_value = CefValue::Create();
    result_value->SetValue(response->GetValue("result"));
    id result = BrowsemiumObjectFromCefValue(result_value);
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
  CefRefPtr<BrowsemiumDevToolsBridge> _devTools;
  __weak NSView* _hostView;
  NSString* _title;
  NSString* _pendingURL;
  BOOL _closed;
  int _findIdentifier;
  void (^_findCompletion)(int matchCount, BOOL found);
}

- (void)cefBrowserDidCreate;
- (void)cefBrowserDidClose;
- (void)cefBrowserDidStartLoading;
- (void)cefBrowserDidFinishLoadingURL:(NSString*)url;
- (void)cefBrowserDidFailLoadingWithMessage:(NSString*)message;
- (void)cefBrowserDidChangeProgress:(double)progress;
- (void)cefBrowserDidChangeTitle:(NSString*)title;
- (void)cefBrowserDidChangeURL:(NSString*)url;
- (void)cefBrowserDidChangeNavigationStateCanGoBack:(BOOL)canGoBack
                                       canGoForward:(BOOL)canGoForward
                                          isLoading:(BOOL)isLoading;
- (void)cefBrowserDidChangeAudioStatePlaying:(BOOL)playing capturing:(BOOL)capturing;
- (void)cefBrowserDidRequestNewWindow:(NSString*)url;
- (void)cefBrowserDidCrash;
- (void)cefBrowserDidStartDownload:(NSString*)identifier
                          filename:(NSString*)filename
                       destination:(NSString*)destination;
- (void)cefBrowserDidUpdateDownload:(NSString*)identifier
                      receivedBytes:(int64_t)receivedBytes
                         totalBytes:(int64_t)totalBytes
                           finished:(BOOL)finished
                            failure:(NSString*)failure;
- (void)cefBrowserRequestsMediaAccessForKind:(NSString*)kind
                                      origin:(NSString*)origin
                                  completion:(void (^)(BOOL granted))completion;
- (void)cefBrowserDidFindMatches:(int)count;
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
      _context = CefRequestContext::CreateContext(settings, nullptr);
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
  if (_browser) {
    return;
  }
  CefWindowInfo window_info;
  const CefRect rect(0, 0, (int)MAX(host.bounds.size.width, 1), (int)MAX(host.bounds.size.height, 1));
  window_info.SetAsChild((__bridge void*)host, rect);

  CefBrowserSettings browser_settings;
  browser_settings.background_color = 0xFFFFFFFF;

  _browser = CefBrowserHost::CreateBrowserSync(window_info, _client, "about:blank",
                                               browser_settings, nullptr, _context);
  if (_browser) {
    _devTools->Attach(_browser->GetHost());
    _browser->GetHost()->WasResized();
  }
  if (_pendingURL.length > 0) {
    NSString* url = _pendingURL;
    _pendingURL = nil;
    [self loadURLString:url];
  }
}

- (void)resizeToBounds:(NSRect)bounds {
  if (_browser) {
    _browser->GetHost()->WasResized();
  }
}

- (void)loadURLString:(NSString*)urlString {
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(urlString.UTF8String);
  } else {
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
  [_devTools Detach];
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
