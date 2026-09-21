#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BrowsemiumCEFBrowser;

/// Everything a Chromium tab reports. Mirrors the WebKit engine's vocabulary so
/// the window model does not care which engine it is driving.
@protocol BrowsemiumCEFBrowserDelegate <NSObject>
@optional
- (void)cefBrowserDidStartLoading:(BrowsemiumCEFBrowser *)browser;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didCommitNavigationToURL:(nullable NSString *)url;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didFinishLoadingURL:(nullable NSString *)url;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didFailLoadingWithMessage:(NSString *)message;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didChangeProgress:(double)progress;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didChangeTitle:(nullable NSString *)title;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didChangeURL:(nullable NSString *)url;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didChangeNavigationStateCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward isLoading:(BOOL)isLoading;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didChangeAudioStatePlaying:(BOOL)playing capturing:(BOOL)capturing;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser didRequestNewWindowForURL:(NSString *)url;
- (void)cefBrowserDidCrash:(BrowsemiumCEFBrowser *)browser;
- (void)cefBrowserDidClose:(BrowsemiumCEFBrowser *)browser;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser
    didStartDownloadWithIdentifier:(NSString *)identifier
                          filename:(NSString *)filename
                     destination:(nullable NSString *)destination;
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser
    didUpdateDownloadWithIdentifier:(NSString *)identifier
                    receivedBytes:(int64_t)receivedBytes
                       totalBytes:(int64_t)totalBytes
                         finished:(BOOL)finished
                          failure:(nullable NSString *)failure;
/// Asked before a page is granted the camera or the microphone. Call the
/// completion with the decision; the browser waits for it.
- (void)cefBrowser:(BrowsemiumCEFBrowser *)browser
    requestsMediaAccessForKind:(NSString *)kind
                        origin:(NSString *)origin
                    completion:(void (^)(BOOL granted))completion;
@end

/// Process-wide CEF lifecycle. The app must load the framework and hand off
/// helper processes before creating any browser.
@interface BrowsemiumCEFRuntime : NSObject

/// Loads the CEF framework from the app bundle. Must be the first CEF call.
+ (BOOL)loadFramework;

/// Runs the helper-process path when this process was launched as one.
/// Returns -1 when this is the browser process, otherwise the exit code.
+ (int)executeProcess;

/// Initializes CEF for the browser process. Returns NO and fills `error` when
/// Chromium refuses to start.
+ (BOOL)startWithRootCachePath:(NSString *)rootCachePath
                     cachePath:(NSString *)cachePath
                     userAgent:(nullable NSString *)userAgent
                       logPath:(nullable NSString *)logPath
                        error:(NSError **)error;

+ (BOOL)isRunning;
+ (void)shutdown;

@end

/// One Chromium tab, rendered into a native view.
@interface BrowsemiumCEFBrowser : NSObject

@property (nonatomic, weak, nullable) id<BrowsemiumCEFBrowserDelegate> delegate;
@property (nonatomic, readonly, copy, nullable) NSString *currentURL;
@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isClosed;

- (instancetype)initWithDelegate:(id<BrowsemiumCEFBrowserDelegate>)delegate
                       cachePath:(nullable NSString *)cachePath;

/// Creates the browser as a child of `host` and fills it.
- (void)attachToView:(NSView *)host;
- (void)resizeToBounds:(NSRect)bounds;
- (void)loadURLString:(NSString *)urlString;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)setZoomLevel:(double)zoomLevel;
- (void)setMuted:(BOOL)muted;
- (void)evaluateJavaScript:(NSString *)script
                completion:(void (^)(id _Nullable result, NSString *_Nullable error))completion;
- (void)findText:(NSString *)text
         forward:(BOOL)forward
      completion:(void (^)(int matchCount, BOOL found))completion;
/// Destroys the browser and its renderer process. Used by the memory saver.
- (void)close;

@end

/// Entry point for the helper executable. Never returns.
int BrowsemiumCEFHelperMain(int argc, char *argv[]);

NS_ASSUME_NONNULL_END
