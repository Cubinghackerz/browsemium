#import <Foundation/Foundation.h>

#include "include/cef_client.h"

@class BrowsemiumCEFBrowser;

/// Creates the browser-process handler set for one tab. Implemented in
/// CEFBrowserClient.mm so the C++ client never leaks into the public header.
CefRefPtr<CefClient> BrowsemiumCreateClient(BrowsemiumCEFBrowser* owner);
