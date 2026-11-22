// The Swift-facing side of the CEF bridge. Plain Objective-C: no CEF or C++ types leak out.
//
// Everything here runs on the main thread, which CEF uses as its UI thread on macOS.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The application class CEF requires on macOS (it implements CefAppProtocol in the .mm).
/// Create it with `PCEFApplication.shared` before anything else touches NSApp.
@interface PCEFApplication : NSApplication
/// Called instead of quitting outright when the user chooses Quit. The handler saves state,
/// closes windows and then calls +[PCEFRuntime quitMessageLoop].
@property (nonatomic, copy, nullable) void (^terminateHandler)(void);
@end

/// Process-wide CEF lifetime.
@interface PCEFRuntime : NSObject
/// Loads the framework and initializes CEF. `cachePath` is the profile root on disk.
+ (BOOL)startWithCachePath:(NSString *)cachePath mockKeychain:(BOOL)mockKeychain;
/// Chromium sometimes opens a browser of its own: a restored session, or an extension calling
/// chrome.tabs.create / chrome.windows.create. Plinth closes those and gets their address here,
/// to open as an ordinary page instead.
@property (class, copy, nullable) void (^strayBrowserHandler)(NSString *url);
/// Logs lifecycle steps to stderr when PLINTH_CEF_LOG is set.
+ (void)log:(NSString *)message;
/// Unpacked extension folders to load at startup (Chromium's --load-extension), for development and tests.
/// Set before +startWithCachePath:mockKeychain:.
@property (class, copy) NSArray<NSString *> *unpackedExtensions;
/// Runs until +quitMessageLoop. Returns after the last browser has closed.
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
/// Quits the message loop once every open browser has finished closing (now, if none are open).
+ (void)quitAfterBrowsersClose;
+ (void)shutdown;
/// The run loop had to be stopped from AppKit because Chromium did not end it; CefShutdown is
/// then skipped (it crashes in that state). Cookies are flushed before quitting either way.
@property (class, readonly) BOOL loopWasForcedToStop;
/// The Chromium version string, for About and diagnostics.
+ (NSString *)chromiumVersion;
@end

/// A Chromium profile (CEF request context).
@interface PCEFProfile : NSObject
/// The persistent default profile (cookies, extensions, history).
@property (class, readonly) PCEFProfile *shared;
/// A fresh in-memory profile for a private window. Nothing it stores reaches disk.
+ (PCEFProfile *)makePrivate;
@property (readonly) BOOL isPrivate;
/// The profile's folder on disk (nil for a private profile).
@property (readonly, nullable) NSString *path;
@end

typedef NS_ENUM(NSInteger, PCEFOpenDisposition) {
    PCEFOpenDispositionCurrentTab,
    PCEFOpenDispositionForegroundTab,
    PCEFOpenDispositionBackgroundTab,
    PCEFOpenDispositionNewWindow,
    PCEFOpenDispositionPopup,
};

@class PCEFBrowser;

@protocol PCEFBrowserDelegate <NSObject>
- (void)browser:(PCEFBrowser *)browser didChangeAddress:(NSString *)address;
- (void)browser:(PCEFBrowser *)browser didChangeTitle:(NSString *)title;
- (void)browser:(PCEFBrowser *)browser didChangeFaviconURL:(nullable NSString *)url;
- (void)browserLoadingStateChanged:(PCEFBrowser *)browser;
- (void)browser:(PCEFBrowser *)browser didChangeProgress:(double)progress;
/// A link wants a new tab or window. Return YES if the shell opened it (CEF then does nothing).
/// Return NO for a scripted popup that should get its own small window.
- (BOOL)browser:(PCEFBrowser *)browser openURL:(NSString *)url disposition:(PCEFOpenDisposition)disposition
    userGesture:(BOOL)userGesture;
- (void)browser:(PCEFBrowser *)browser fullscreenChanged:(BOOL)fullscreen;
/// A main-frame navigation is about to start. Return NO to cancel it (the shell may open it elsewhere).
- (BOOL)browser:(PCEFBrowser *)browser shouldNavigateTo:(NSString *)url linkClick:(BOOL)linkClick
       isRedirect:(BOOL)isRedirect;
/// A key press before the page sees it. Return YES to swallow it (the shell handled a shortcut).
- (BOOL)browser:(PCEFBrowser *)browser handleKeyEquivalent:(NSEvent *)event;
- (void)browserDidClose:(PCEFBrowser *)browser;
/// The page's own window exists (see `hostWindow`).
- (void)browserHostWindowReady:(PCEFBrowser *)browser;
/// The page's window became key: the user clicked into the page.
- (void)browserDidActivate:(PCEFBrowser *)browser;
@end

/// One page: a Chrome-style browser in a frameless window of its own.
///
/// CEF allows one Chrome-style browser view per window, and only Chrome style runs extensions, so each
/// page gets its own borderless `hostWindow`. The shell attaches the selected page's host window as a
/// child *below* its own window, which draws the chrome and leaves a transparent hole for the page.
@interface PCEFBrowser : NSObject
- (instancetype)initWithURL:(NSString *)url profile:(PCEFProfile *)profile
                   delegate:(id<PCEFBrowserDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (weak, nullable) id<PCEFBrowserDelegate> delegate;
@property (readonly) PCEFProfile *profile;
/// The page's borderless window, once created (nil before browserHostWindowReady: and after close).
@property (readonly, nullable) NSWindow *hostWindow;
/// True once Chromium has created the browser.
@property (readonly) BOOL isCreated;
@property (readonly, copy) NSString *address;
@property (readonly, copy) NSString *title;
@property (readonly) BOOL isLoading;
@property (readonly) BOOL canGoBack;
@property (readonly) BOOL canGoForward;
@property (nonatomic) double zoomLevel;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)find:(NSString *)text forward:(BOOL)forward;
- (void)stopFinding;
/// Runs a Chrome command by its IDC_ name, e.g. "IDC_MANAGE_EXTENSIONS". Returns NO if unknown or disabled.
- (BOOL)executeChromeCommand:(NSString *)name;
/// Runs JavaScript in the main frame (fire and forget).
- (void)executeJavaScript:(NSString *)script;
/// Shows the page's window as a child below `parent`, filling `frame` (screen coordinates),
/// or hides it when `parent` is nil.
- (void)attachBelow:(nullable NSWindow *)parent frame:(NSRect)frame;
/// Shows the page's window as a child above `parent` (for extension popups), filling `frame`.
- (void)attachAbove:(NSWindow *)parent frame:(NSRect)frame;
/// Gives the page keyboard focus.
- (void)focus;
/// Closes the browser for good. The delegate gets browserDidClose: when Chromium is done.
- (void)close;
@end

NS_ASSUME_NONNULL_END
