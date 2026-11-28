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

/// A download Chromium is running or has finished, as last reported.
@interface PCEFDownload : NSObject
@property (readonly) uint32_t identifier;
@property (readonly, copy) NSString *url;
@property (readonly, copy) NSString *filename;
/// Where the file is being written ("" until Chromium has decided).
@property (readonly, copy) NSString *path;
@property (readonly) int64_t receivedBytes;
/// -1 when the server did not say.
@property (readonly) int64_t totalBytes;
@property (readonly) int64_t bytesPerSecond;
@property (readonly) BOOL isInProgress;
@property (readonly) BOOL isComplete;
@property (readonly) BOOL isCanceled;
@property (readonly) BOOL isInterrupted;
@end

/// Process-wide CEF lifetime.
@interface PCEFRuntime : NSObject
/// Loads the framework and initializes CEF. `cachePath` is the profile root on disk.
+ (BOOL)startWithCachePath:(NSString *)cachePath mockKeychain:(BOOL)mockKeychain;
/// Chromium sometimes opens a browser of its own: a restored session, or an extension calling
/// chrome.tabs.create / chrome.windows.create. Plinth closes those and gets their address here,
/// to open as an ordinary page instead.
@property (class, copy, nullable) void (^strayBrowserHandler)(NSString *url);
/// Every download update from any page. Plinth takes downloads over from Chromium's own UI
/// (which is hidden) and saves them into `downloadsDirectory`.
@property (class, copy, nullable) void (^downloadHandler)(PCEFDownload *download);
/// Folder new downloads are saved to (~/Downloads unless set).
@property (class, copy) NSString *downloadsDirectory;
+ (void)cancelDownload:(uint32_t)identifier;
/// Asks where to save each new download. It gets the path Plinth would use and must call `decide` once,
/// on the main thread, with the chosen path, or nil to cancel the download. Nil saves straight away.
@property (class, copy, nullable) void (^saveLocationChooser)(NSString *suggestedPath, void (^decide)(NSString *_Nullable path));
/// Global Privacy Control: sends `Sec-GPC: 1` with every page request and makes
/// `navigator.globalPrivacyControl` true in renderers started from now on.
@property (class) BOOL globalPrivacyControl;
/// Logs lifecycle steps to stderr when PLINTH_CEF_LOG is set.
+ (void)log:(NSString *)message;
/// Unpacked extension folders to load at startup (Chromium's --load-extension), for development and tests.
/// Set before +startWithCachePath:mockKeychain:.
@property (class, copy) NSArray<NSString *> *unpackedExtensions;
/// Plinth's password script (a function expression taking `post` and `testMode` and returning its fill
/// function). Plinth's renderer helper runs it in every http(s) frame before the page's own scripts,
/// handing it a private `post` that reaches `-browser:passwordMessage:…` and keeping the fill function to
/// itself, so neither is ever reachable from the page. Set before the first browser is made; nil turns it off.
@property (class, copy, nullable) NSString *passwordScript;
/// Lets scripted events stand in for real input (scratch-profile test launches only).
@property (class) BOOL passwordScriptTestMode;
/// Plinth's media script (a function expression taking `post`). The renderer helper runs it in every http(s)
/// frame before the page's own scripts; what it posts reaches `-browser:mediaMessage:frameURL:`. Used to hand
/// videos this build can't decode (H.264, AAC) to macOS's own player. Set before the first browser is made.
@property (class, copy, nullable) NSString *mediaScript;
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
/// Sets one Chromium preference. `value` is an NSNumber (bool, integer or double), an NSString, or an
/// NSDictionary of those. Returns NO, and logs, when Chromium refuses it.
- (BOOL)setPreference:(NSString *)name value:(id)value;
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
@optional
/// A message from the password script in one of the page's frames (see `passwordScript`). `message` can
/// hold what was typed into a login form; it must never be logged. `frameURL` is the frame's own address.
- (void)browser:(PCEFBrowser *)browser passwordMessage:(NSDictionary *)message frame:(NSString *)frameID
       frameURL:(NSString *)frameURL isMainFrame:(BOOL)isMainFrame;
/// A message from the media script in one of the page's frames (see `mediaScript`).
- (void)browser:(PCEFBrowser *)browser mediaMessage:(NSDictionary *)message frameURL:(NSString *)frameURL;
@end

/// One page: a Chrome-style browser in a frameless window of its own.
///
/// CEF allows one Chrome-style browser view per window, and only Chrome style runs extensions, so each
/// page gets its own borderless `hostWindow`. The shell attaches the selected page's host window as a
/// child above its own window, over the space its chrome leaves for the page.
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
/// The profile's default zoom level (0 unless the profile's default zoom was changed).
@property (readonly) double defaultZoomLevel;

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
/// Evaluates `expression` in the main frame (in Plinth's renderer helper, through a process message)
/// and hands back its value as Foundation objects: NSString, NSNumber, NSNull, NSArray and
/// NSDictionary. Promises and functions are not followed. `completion` runs once on the main
/// thread, with nil if the page has no browser yet, the script threw, or no answer came within a
/// few seconds (the page navigated or its renderer went away).
- (void)evaluateJavaScript:(NSString *)expression completion:(void (^)(id _Nullable result))completion;
/// Hands a saved login to the password script's fill function in one frame (`frameID` from
/// `-browser:passwordMessage:…`). An empty password fills the user name alone. Fire and forget.
- (void)fillPasswordInFrame:(NSString *)frameID token:(NSInteger)token username:(NSString *)username
                   password:(NSString *)password;
/// Scrolls the page as a wheel at `point` (the page view's points, top-left origin) would.
- (void)sendScrollAt:(NSPoint)point deltaX:(CGFloat)deltaX deltaY:(CGFloat)deltaY;
/// The main frame's plain text (Chromium's own text dump, no structure), or nil.
- (void)readPlainText:(void (^)(NSString *_Nullable text))completion;
/// A JPEG of what the page shows (Chromium's DevTools screenshot), or nil if it can't be taken.
- (void)captureSnapshot:(void (^)(NSData *_Nullable jpeg))completion;
/// Shows the page's window as a child above `parent`, filling `frame` (screen coordinates) with its
/// corners rounded to `cornerRadius`, or hides it when `parent` is nil. Pages sit above Plinth's
/// window so they get clicks and keys directly.
- (void)attachTo:(nullable NSWindow *)parent frame:(NSRect)frame cornerRadius:(CGFloat)cornerRadius;
/// Gives the page keyboard focus.
- (void)focus;
/// Closes the browser for good. The delegate gets browserDidClose: when Chromium is done.
- (void)close;
@end

NS_ASSUME_NONNULL_END
