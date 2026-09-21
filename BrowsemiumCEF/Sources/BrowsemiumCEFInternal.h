#import <Foundation/Foundation.h>

#include "include/cef_client.h"

@class BrowsemiumCEFBrowser;

/// Creates the browser-process handler set for one tab. Implemented in
/// CEFBrowserClient.mm so the C++ client never leaks into the public header.
CefRefPtr<CefClient> BrowsemiumCreateClient(BrowsemiumCEFBrowser* owner);

/// Callbacks the C++ client sends to the Objective-C browser wrapper. They live
/// here rather than in a class extension inside the implementation file,
/// because the client is a separate translation unit and has to see them.
@interface BrowsemiumCEFBrowser (ClientCallbacks)
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
