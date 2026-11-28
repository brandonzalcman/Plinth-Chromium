// The CEF side of the bridge. Compiled with ARC; CEF objects are held in CefRefPtr ivars and the
// C++ handlers point back at their Objective-C owners weakly.
#import "PlinthCEF.h"

#include <atomic>
#include <crt_externs.h>
#include <map>
#include <set>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_id_mappers.h"
#include "include/cef_process_message.h"
#include "include/cef_values.h"
#include "include/cef_request_context.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_version_info.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/base/cef_callback.h"

static NSString *NSStringFromCef(const CefString &s) {
    std::string utf8 = s.ToString();
    return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static CefString CefFromNSString(NSString *s) { return CefString(std::string(s.UTF8String ?: "")); }

static cef_color_t CefColor(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    return CefColorSetARGB((int)lround(c.alphaComponent * 255), (int)lround(c.redComponent * 255),
                           (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255));
}

/// AppKit rects are bottom-left based; CEF screen rects are top-left based on the primary display.
static CefRect CefRectFromScreenRect(NSRect r) {
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    return CefRect((int)r.origin.x, (int)(primaryHeight - r.origin.y - r.size.height), (int)r.size.width,
                   (int)r.size.height);
}

/// The process messages the renderer helper answers (see PlinthChromiumHelper/main.mm).
static const char *kEvalMessage = "plinth.eval";
static const char *kEvalResultMessage = "plinth.eval.result";
/// The password script's messages, and the fill sent back to it.
static const char *kPasswordMessage = "plinth.pw";
static const char *kPasswordFillMessage = "plinth.pw.fill";
static const char *kMediaMessage = "plinth.media";
/// How long a script's answer is waited for.
static const int64_t kEvalTimeout = 6 * NSEC_PER_SEC;

/// A CefValue from the renderer as Foundation objects.
static id NSObjectFromCefValue(CefRefPtr<CefValue> value, int depth) {
    if (!value || depth > 12) return NSNull.null;
    switch (value->GetType()) {
    case VTYPE_BOOL: return @(value->GetBool());
    case VTYPE_INT: return @(value->GetInt());
    case VTYPE_DOUBLE: return @(value->GetDouble());
    case VTYPE_STRING: return NSStringFromCef(value->GetString());
    case VTYPE_LIST: {
        CefRefPtr<CefListValue> list = value->GetList();
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:list->GetSize()];
        for (size_t i = 0; i < list->GetSize(); i++) [array addObject:NSObjectFromCefValue(list->GetValue(i), depth + 1)];
        return array;
    }
    case VTYPE_DICTIONARY: {
        CefRefPtr<CefDictionaryValue> dict = value->GetDictionary();
        CefDictionaryValue::KeyList keys;
        dict->GetKeys(keys);
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:keys.size()];
        for (const CefString &key : keys) result[NSStringFromCef(key)] = NSObjectFromCefValue(dict->GetValue(key), depth + 1);
        return result;
    }
    default: return NSNull.null;
    }
}

static void PLog(NSString *message) {
    if (getenv("PLINTH_CEF_LOG")) fprintf(stderr, "[cef] %s\n", message.UTF8String);
}

/// The Plinth window in front: the main window (or the one owning the key window), else the
/// frontmost visible Plinth window, even while Plinth itself is in the background.
static NSWindow *FrontPlinthWindow(void) {
    NSWindow *front = NSApp.mainWindow ?: NSApp.keyWindow;
    while (front.parentWindow) front = front.parentWindow;
    if ([front.identifier isEqualToString:@"plinth.main"]) return front;
    for (NSWindow *w in NSApp.orderedWindows) {
        if (w.isVisible && [w.identifier isEqualToString:@"plinth.main"]) return w;
    }
    return nil;
}

/// The size a page asked for in window.open(…, "width=…,height=…"), for the popup about to be made.
static CefSize gNextPopupSize(0, 0);

/// Puts a popup window centred over the Plinth window that is in front, as a child so it moves with it
/// and stays above it: a floating sheet, like a sign-in window should be.
static void FloatOverPlinth(CefRefPtr<CefWindow> window, CefSize size) {
    id handle = (__bridge id)window->GetWindowHandle();
    NSWindow *ns = [handle isKindOfClass:NSWindow.class] ? handle : [(NSView *)handle window];
    NSWindow *front = FrontPlinthWindow();
    int w = size.width > 200 ? std::min(size.width, 1000) : 520;
    int h = size.height > 200 ? std::min(size.height, 900) : 680;
    if (front) {
        NSRect f = front.frame;
        NSRect r = NSMakeRect(NSMidX(f) - w / 2.0, NSMidY(f) - h / 2.0 + 20, w, h);
        CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
        window->SetBounds(CefRect((int)r.origin.x, (int)(primaryHeight - r.origin.y - r.size.height), w, h));
    } else {
        window->CenterWindow(CefSize(w, h));
    }
    window->Show();
    ns.identifier = @"plinth.floating-popup";
    if (front && ns && ns != front) [front addChildWindow:ns ordered:NSWindowAbove];
    [ns makeKeyAndOrderFront:nil];
}

/// Centres a window over the Plinth window in front and makes it a child, so it floats above it and
/// moves with it. Big windows (a whole Chromium tab window) are kept to a comfortable sheet size.
static void FloatWindowOverPlinth(NSWindow *ns, NSSize size) {
    NSWindow *front = FrontPlinthWindow();
    if (!front || front == ns) { [ns makeKeyAndOrderFront:nil]; return; }
    NSRect f = front.frame;
    CGFloat w = MIN(MAX(size.width, 420), MIN(1000, f.size.width - 80));
    CGFloat h = MIN(MAX(size.height, 480), MIN(900, f.size.height - 80));
    [ns setFrame:NSMakeRect(NSMidX(f) - w / 2, NSMidY(f) - h / 2 + 20, w, h) display:YES];
    ns.identifier = @"plinth.floating-popup";
    if (ns.parentWindow != front) [front addChildWindow:ns ordered:NSWindowAbove];
    [ns makeKeyAndOrderFront:nil];
}

static int gLiveBrowsers = 0;
/// When Chromium started, to tell its own session restore apart from windows opened later.
static CFAbsoluteTime gLaunchTime = 0;
static bool gQuitWhenClosed = false;

/// Ends the run loop. CefQuitMessageLoop alone does not always return from CefRunMessageLoop with the
/// Chrome bootstrap (Chromium may still hold keep-alives), so AppKit's loop is stopped as a fallback.
static bool gForcedStop = false;

static void QuitLoop() {
    // Write cookies to disk now, in case the loop has to be forced to stop below.
    CefCookieManager::GetGlobalManager(nullptr)->FlushStore(nullptr);
    CefQuitMessageLoop();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PLog(@"run loop still going; stopping AppKit's loop");
        gForcedStop = true;
        [NSApp stop:nil];
        NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                          timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
        [NSApp postEvent:wake atStart:YES];
    });
}

static void NoteBrowserClosed() {
    gLiveBrowsers = std::max(0, gLiveBrowsers - 1);
    PLog([NSString stringWithFormat:@"browser closed, %d left, quitting=%d", gLiveBrowsers, gQuitWhenClosed]);
    if (gQuitWhenClosed && gLiveBrowsers == 0) QuitLoop();
}

// MARK: - Downloads

@interface PCEFDownload ()
@property (readwrite) uint32_t identifier;
@property (readwrite, copy) NSString *url;
@property (readwrite, copy) NSString *filename;
@property (readwrite, copy) NSString *path;
@property (readwrite) int64_t receivedBytes;
@property (readwrite) int64_t totalBytes;
@property (readwrite) int64_t bytesPerSecond;
@property (readwrite) BOOL isInProgress;
@property (readwrite) BOOL isComplete;
@property (readwrite) BOOL isCanceled;
@property (readwrite) BOOL isInterrupted;
@end

@implementation PCEFDownload
@end

static PCEFDownload *DownloadFrom(CefRefPtr<CefDownloadItem> item) {
    PCEFDownload *d = [PCEFDownload new];
    d.identifier = item->GetId();
    d.url = NSStringFromCef(item->GetURL());
    d.path = NSStringFromCef(item->GetFullPath());
    NSString *name = d.path.length ? d.path.lastPathComponent : NSStringFromCef(item->GetSuggestedFileName());
    d.filename = name.length ? name : @"Download";
    d.receivedBytes = item->GetReceivedBytes();
    d.totalBytes = item->GetTotalBytes() > 0 ? item->GetTotalBytes() : -1;
    d.bytesPerSecond = item->GetCurrentSpeed();
    d.isInProgress = item->IsInProgress();
    d.isComplete = item->IsComplete();
    d.isCanceled = item->IsCanceled();
    d.isInterrupted = item->IsInterrupted();
    return d;
}

/// A file name that doesn't overwrite one already in `folder`: "name (2).ext" and so on.
static NSString *UniquePath(NSString *folder, NSString *name) {
    NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    NSString *path = [folder stringByAppendingPathComponent:name];
    for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:path] && n < 1000; n++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ (%d)", base, n];
        if (ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
        path = [folder stringByAppendingPathComponent:candidate];
    }
    return path;
}

// MARK: - Application

@interface PCEFApplication () <CefAppProtocol> {
    BOOL _handlingSendEvent;
}
@end

@implementation PCEFApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent { _handlingSendEvent = handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent sendingEventScoper;
    [super sendEvent:event];
}
- (void)terminate:(id)sender {
    // Never let AppKit exit() underneath Chromium: the shell closes everything and quits the loop.
    if (self.terminateHandler) self.terminateHandler();
    else [PCEFRuntime quitAfterBrowsersClose];
}
@end

// MARK: - Runtime

static NSArray<NSString *> *gUnpackedExtensions = @[];
static NSString *gPasswordScript = nil;
static NSString *gMediaScript;
static BOOL gPasswordTestMode = NO;
static void (^gStrayHandler)(NSString *) = nil;
static void (^gDownloadHandler)(PCEFDownload *) = nil;
static NSString *gDownloadsDirectory = nil;
static std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> gDownloadCallbacks;
static void (^gSaveChooser)(NSString *, void (^)(NSString *)) = nil;
/// Read on Chromium's IO and launcher threads too.
static std::atomic<bool> gGlobalPrivacyControl{false};
/// The renderer helper's switch for navigator.globalPrivacyControl (see PlinthChromiumHelper/main.mm).
static const char *kGPCSwitch = "plinth-gpc";


namespace {

/// The client Chromium uses for browsers it opens by itself. Plinth closes them at once and opens
/// their address as a Plinth page instead.
class StrayClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler {
public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        // Right after launch, a browser Chromium opens by itself is a leftover from its own session
        // (after a crash, say): Plinth has its own session, so it goes, and its address opens as a page.
        if (CFAbsoluteTimeGetCurrent() - gLaunchTime < 5) {
            PLog(@"closing a browser Chromium restored by itself");
            CefRefPtr<CefBrowser> keep = browser;
            CefPostDelayedTask(TID_UI, base::BindOnce([](CefRefPtr<CefBrowser> b) {
                std::string url = b->GetMainFrame()->GetURL().ToString();
                NSString *address = [NSString stringWithUTF8String:url.c_str()];
                if (gStrayHandler && address.length && ![address hasPrefix:@"chrome://newtab"] &&
                    ![address isEqualToString:@"about:blank"]) {
                    gStrayHandler(address);
                }
                b->GetHost()->CloseBrowser(true);
            }, keep), 300);
            return;
        }
        // Later, it is something an extension or page asked for: a sign-in window, a login tab
        // (chrome.windows.create, chrome.tabs.create). It must stay the very browser the extension
        // created, or the extension loses track of it, so it stays and floats over Plinth.
        PLog([NSString stringWithFormat:@"floating a window Chromium opened (popup=%d)", browser->IsPopup()]);
        // Chromium's own windows have no CEF browser view; go through the page's view to its window,
        // once Chromium has put it on screen and the page has an address.
        AdoptOrFloat(browser, 0);
    }

    /// A tab (chrome.tabs.create: Chromium's tabbed browser window) becomes an ordinary Plinth page.
    /// Anything else (a popup or sign-in window) keeps its window, floating over Plinth.
    static void AdoptOrFloat(CefRefPtr<CefBrowser> browser, int attempt) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id handle = (__bridge id)browser->GetHost()->GetWindowHandle();
            NSWindow *ns = [handle isKindOfClass:NSWindow.class] ? handle : [(NSView *)handle window];
            std::string url = browser->GetMainFrame()->GetURL().ToString();
            NSString *address = [NSString stringWithUTF8String:url.c_str()];
            BOOL known = address.length && ![address isEqualToString:@"about:blank"];
            if (!ns || (!known && attempt < 12)) { AdoptOrFloat(browser, attempt + 1); return; }
            BOOL isTabWindow = [NSStringFromClass(ns.class) containsString:@"BrowserNativeWidgetWindow"] && !browser->IsPopup();
            if (isTabWindow && known && ![address hasPrefix:@"chrome://newtab"]) {
                PLog(@"a tab Chromium opened becomes a Plinth page");
                ns.alphaValue = 0;   // never flash Chrome's own tab strip
                if (gStrayHandler) gStrayHandler(address);
                browser->GetHost()->CloseBrowser(true);
            } else {
                FloatWindowOverPlinth(ns, NSMakeSize(ns.frame.size.width, ns.frame.size.height));
            }
        });
    }
    IMPLEMENT_REFCOUNTING(StrayClient);
};

class PlinthCefApp : public CefApp, public CefBrowserProcessHandler {
public:
    explicit PlinthCefApp(bool mockKeychain) : mockKeychain_(mockKeychain) {}

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    CefRefPtr<CefClient> GetDefaultClient() override {
        if (!strayClient_) strayClient_ = new StrayClient();
        return strayClient_;
    }

    void OnBeforeCommandLineProcessing(const CefString &processType, CefRefPtr<CefCommandLine> commandLine) override {
        if (!processType.empty()) return;
        // Test runs skip the Keychain prompt for Chromium's cookie encryption key.
        if (mockKeychain_) commandLine->AppendSwitch("use-mock-keychain");
        // Plinth draws its own tab UI; Chrome's first-run and default-browser prompts don't apply.
        commandLine->AppendSwitch("no-first-run");
        commandLine->AppendSwitch("no-default-browser-check");
        // Every Chromium window belongs to a Plinth page; Chromium must not open or restore its own.
        commandLine->AppendSwitch("no-startup-window");
        commandLine->AppendSwitch("disable-session-crashed-bubble");
        commandLine->AppendSwitch("hide-crash-restore-bubble");
        // Chrome's own split view draws an outline and shadow around page contents, which shows as a
        // frame inside Plinth's page hole. Plinth has its own split view.
        std::string disabled = commandLine->GetSwitchValue("disable-features").ToString();
        disabled += disabled.empty() ? "SideBySide" : ",SideBySide";
        commandLine->AppendSwitchWithValue("disable-features", disabled);
        if (gUnpackedExtensions.count) {
            commandLine->AppendSwitchWithValue("load-extension",
                                               CefFromNSString([gUnpackedExtensions componentsJoinedByString:@","]));
        }
    }

    // Renderers read this once at start, so a change reaches renderers launched after it.
    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> commandLine) override {
        if (gGlobalPrivacyControl) commandLine->AppendSwitch(kGPCSwitch);
    }

private:
    bool mockKeychain_;
    CefRefPtr<CefClient> strayClient_;
    IMPLEMENT_REFCOUNTING(PlinthCefApp);
};

CefScopedLibraryLoader *gLoader = nullptr;

} // namespace

@implementation PCEFRuntime

+ (NSArray<NSString *> *)unpackedExtensions { return gUnpackedExtensions; }
+ (void (^)(NSString *))strayBrowserHandler { return gStrayHandler; }
+ (void)setStrayBrowserHandler:(void (^)(NSString *))handler { gStrayHandler = [handler copy]; }
+ (void)log:(NSString *)message { PLog(message); }
+ (void (^)(PCEFDownload *))downloadHandler { return gDownloadHandler; }
+ (void)setDownloadHandler:(void (^)(PCEFDownload *))handler { gDownloadHandler = [handler copy]; }
+ (NSString *)downloadsDirectory {
    return gDownloadsDirectory ?: [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
}
+ (void)setDownloadsDirectory:(NSString *)path { gDownloadsDirectory = [path copy]; }
+ (void (^)(NSString *, void (^)(NSString *)))saveLocationChooser { return gSaveChooser; }
+ (void)setSaveLocationChooser:(void (^)(NSString *, void (^)(NSString *)))chooser { gSaveChooser = [chooser copy]; }
+ (BOOL)globalPrivacyControl { return gGlobalPrivacyControl; }
+ (void)setGlobalPrivacyControl:(BOOL)on { gGlobalPrivacyControl = on; }
+ (void)cancelDownload:(uint32_t)identifier {
    auto it = gDownloadCallbacks.find(identifier);
    if (it != gDownloadCallbacks.end()) it->second->Cancel();
}
+ (void)setUnpackedExtensions:(NSArray<NSString *> *)paths { gUnpackedExtensions = [paths copy] ?: @[]; }
+ (NSString *)passwordScript { return gPasswordScript; }
+ (void)setPasswordScript:(NSString *)script { gPasswordScript = [script copy]; }
+ (BOOL)passwordScriptTestMode { return gPasswordTestMode; }
+ (NSString *)mediaScript { return gMediaScript; }
+ (void)setMediaScript:(NSString *)script { gMediaScript = [script copy]; }
+ (void)setPasswordScriptTestMode:(BOOL)on { gPasswordTestMode = on; }

+ (BOOL)startWithCachePath:(NSString *)cachePath mockKeychain:(BOOL)mockKeychain {
    gLoader = new CefScopedLibraryLoader();
    if (!gLoader->LoadInMain()) return NO;

    CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());
    CefSettings settings;
    settings.no_sandbox = true;
    settings.persist_session_cookies = true;
    CefString(&settings.root_cache_path) = CefFromNSString(cachePath);
    CefString(&settings.cache_path) = CefFromNSString([cachePath stringByAppendingPathComponent:@"Default"]);
    NSString *locale = NSLocale.preferredLanguages.firstObject;
    if (locale) CefString(&settings.locale) = CefFromNSString(locale);

    gLaunchTime = CFAbsoluteTimeGetCurrent();
    CefRefPtr<PlinthCefApp> app(new PlinthCefApp(mockKeychain));
    return CefInitialize(mainArgs, settings, app, nullptr);
}

+ (void)runMessageLoop { CefRunMessageLoop(); }
+ (void)quitMessageLoop { CefQuitMessageLoop(); }

+ (void)quitAfterBrowsersClose {
    PLog([NSString stringWithFormat:@"quit requested, %d browsers open", gLiveBrowsers]);
    gQuitWhenClosed = true;
    if (gLiveBrowsers == 0) QuitLoop();
}

+ (BOOL)loopWasForcedToStop { return gForcedStop; }

+ (void)shutdown {
    PLog(@"shutting down");
    CefShutdown();
    PLog(@"shut down");
    delete gLoader;
    gLoader = nullptr;
}

+ (NSString *)chromiumVersion {
    return [NSString stringWithFormat:@"%d.%d.%d.%d", cef_version_info(4), cef_version_info(5), cef_version_info(6),
                                      cef_version_info(7)];
}

@end

// MARK: - Profile

@interface PCEFProfile () {
@public
    CefRefPtr<CefRequestContext> _context;
}
@property (readwrite) BOOL isPrivate;
@property (readwrite, nullable) NSString *path;
@end

/// Profile preferences Plinth needs: Chromium's own download pop-up is off (Plinth shows downloads
/// itself), downloads never ask where to save, and Chromium's own password manager is off (Plinth
/// fills and saves logins itself, and two managers would both offer to save every sign-in).
static void ApplyPlinthPreferences(CefRefPtr<CefRequestContext> context) {
    CefString error;
    for (const char *name : {"download_bubble.partial_view_enabled", "download.prompt_for_download",
                             "credentials_enable_service", "credentials_enable_autosignin",
                             "profile.password_manager_enabled"}) {
        CefRefPtr<CefValue> value = CefValue::Create();
        value->SetBool(false);
        if (context->CanSetPreference(name)) context->SetPreference(name, value, error);
    }
}

/// A Foundation value as a CefValue for SetPreference (nil when it has no CEF form).
static CefRefPtr<CefValue> CefValueFromNSObject(id object) {
    CefRefPtr<CefValue> value = CefValue::Create();
    if ([object isKindOfClass:NSNumber.class]) {
        NSNumber *n = object;
        const char *type = n.objCType;
        if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) value->SetBool(n.boolValue);
        else if (type[0] == 'd' || type[0] == 'f') value->SetDouble(n.doubleValue);
        else value->SetInt(n.intValue);
    } else if ([object isKindOfClass:NSString.class]) {
        value->SetString(CefFromNSString(object));
    } else if ([object isKindOfClass:NSDictionary.class]) {
        CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
        for (NSString *key in (NSDictionary *)object) {
            CefRefPtr<CefValue> item = CefValueFromNSObject(((NSDictionary *)object)[key]);
            if (!item || ![key isKindOfClass:NSString.class]) return nullptr;
            dict->SetValue(CefFromNSString(key), item);
        }
        value->SetDictionary(dict);
    } else {
        return nullptr;
    }
    return value;
}

@implementation PCEFProfile

- (BOOL)setPreference:(NSString *)name value:(id)object {
    CefRefPtr<CefValue> value = CefValueFromNSObject(object);
    CefString cefName = CefFromNSString(name), error;
    bool ok = value && _context->CanSetPreference(cefName) && _context->SetPreference(cefName, value, error);
    PLog([NSString stringWithFormat:@"pref %@ = %@ (%@): %@%@", name, object, self.isPrivate ? @"private" : @"shared",
                                    ok ? @"set" : @"refused", error.empty() ? @"" : [@" " stringByAppendingString:NSStringFromCef(error)]]);
    return ok;
}

+ (PCEFProfile *)shared {
    static PCEFProfile *shared;
    if (!shared) {
        shared = [PCEFProfile new];
        shared->_context = CefRequestContext::GetGlobalContext();
        ApplyPlinthPreferences(shared->_context);
        shared.path = NSStringFromCef(shared->_context->GetCachePath());
    }
    return shared;
}

+ (PCEFProfile *)makePrivate {
    PCEFProfile *profile = [PCEFProfile new];
    CefRequestContextSettings settings;   // empty cache_path: in memory only
    profile->_context = CefRequestContext::CreateContext(settings, nullptr);
    ApplyPlinthPreferences(profile->_context);
    profile.isPrivate = YES;
    return profile;
}

@end

// MARK: - Browser

@interface PCEFBrowser ()
- (void)_created:(CefRefPtr<CefBrowser>)browser;
- (void)_destroyed;
- (CefRefPtr<CefBrowserView>)_view;
- (void)_hostCreated:(CefRefPtr<CefWindow>)window;
- (void)_hostDestroyed;
- (void)_hostActivated;
- (BOOL)_hostCanClose;
- (void)_evaluationFinished:(int)requestID value:(nullable id)value;
@property (readwrite, copy) NSString *address;
@property (readwrite, copy) NSString *title;
@property (readwrite) BOOL isLoading;
@property (readwrite) BOOL canGoBack;
@property (readwrite) BOOL canGoForward;
@end

namespace {

PCEFOpenDisposition DispositionFrom(cef_window_open_disposition_t d) {
    switch (d) {
    case CEF_WOD_NEW_FOREGROUND_TAB: return PCEFOpenDispositionForegroundTab;
    case CEF_WOD_NEW_BACKGROUND_TAB: return PCEFOpenDispositionBackgroundTab;
    case CEF_WOD_NEW_WINDOW: return PCEFOpenDispositionNewWindow;
    case CEF_WOD_NEW_POPUP: return PCEFOpenDispositionPopup;
    default: return PCEFOpenDispositionCurrentTab;
    }
}

/// Chrome commands that would open Chrome's own tabs or windows; Plinth owns those.
const std::set<int> &BlockedChromeCommands() {
    static std::set<int> blocked = [] {
        std::set<int> ids;
        for (const char *name : {"IDC_NEW_TAB", "IDC_NEW_WINDOW", "IDC_NEW_INCOGNITO_WINDOW", "IDC_CLOSE_TAB",
                                 "IDC_CLOSE_WINDOW", "IDC_SELECT_NEXT_TAB", "IDC_SELECT_PREVIOUS_TAB",
                                 "IDC_RESTORE_TAB", "IDC_FOCUS_LOCATION", "IDC_FOCUS_SEARCH", "IDC_SHOW_HISTORY",
                                 "IDC_DUPLICATE_TAB", "IDC_MOVE_TAB_TO_NEW_WINDOW", "IDC_PIN_TARGET_TAB"}) {
            int id = cef_id_for_command_id_name(name);
            if (id > 0) ids.insert(id);
        }
        return ids;
    }();
    return blocked;
}

/// Adds the Global Privacy Control header to requests while it is on.
class PrivacySignalHandler : public CefResourceRequestHandler {
public:
    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefCallback>) override {
        if (gGlobalPrivacyControl) request->SetHeaderByName("Sec-GPC", "1", true);
        return RV_CONTINUE;
    }
    IMPLEMENT_REFCOUNTING(PrivacySignalHandler);
};

/// The handler for a request (called on the IO thread): none while Global Privacy Control is off.
CefRefPtr<CefResourceRequestHandler> PrivacySignals() {
    static CefRefPtr<CefResourceRequestHandler> handler = new PrivacySignalHandler();
    return gGlobalPrivacyControl ? handler : nullptr;
}

/// The client for a scripted popup's own window: it counts itself and sends Plinth's privacy signals.
class PopupClient : public CefClient, public CefLifeSpanHandler, public CefRequestHandler {
public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                                   CefRefPtr<CefRequest>, bool, bool, const CefString &,
                                                                   bool &) override {
        return PrivacySignals();
    }
    void OnAfterCreated(CefRefPtr<CefBrowser>) override { gLiveBrowsers++; }
    void OnBeforeClose(CefRefPtr<CefBrowser>) override { NoteBrowserClosed(); }
    IMPLEMENT_REFCOUNTING(PopupClient);
};

class BrowserClient : public CefClient,
                      public CefDisplayHandler,
                      public CefLoadHandler,
                      public CefLifeSpanHandler,
                      public CefRequestHandler,
                      public CefKeyboardHandler,
                      public CefCommandHandler,
                      public CefDownloadHandler {
public:
    explicit BrowserClient(PCEFBrowser *owner) : owner_(owner) {}

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

    // Downloads: saved into Plinth's folder (or where the person chose) and reported to the shell.
    bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString &suggestedName,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        NSString *folder = gDownloadsDirectory.length ? gDownloadsDirectory
            : [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *name = NSStringFromCef(suggestedName);
        NSString *path = UniquePath(folder, name.length ? name : @"Download");
        if (gSaveChooser) {
            // Dropping the callback without calling it cancels the download.
            __block CefRefPtr<CefBeforeDownloadCallback> pending = callback;
            gSaveChooser(path, ^(NSString *chosen) {
                if (!pending) return;
                if (chosen.length) pending->Continue(CefFromNSString(chosen), false);
                pending = nullptr;
            });
            return true;
        }
        callback->Continue(CefFromNSString(path), false);
        if (gDownloadHandler) gDownloadHandler(DownloadFrom(item));
        return true;
    }
    void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        if (item->IsInProgress()) gDownloadCallbacks[item->GetId()] = callback;
        else gDownloadCallbacks.erase(item->GetId());
        if (gDownloadHandler) gDownloadHandler(DownloadFrom(item));
    }

    // Display
    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString &url) override {
        if (!frame->IsMain()) return;
        PCEFBrowser *owner = owner_;
        owner.address = NSStringFromCef(url);
        [owner.delegate browser:owner didChangeAddress:owner.address];
    }
    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
        PCEFBrowser *owner = owner_;
        owner.title = NSStringFromCef(title);
        [owner.delegate browser:owner didChangeTitle:owner.title];
    }
    void OnFaviconURLChange(CefRefPtr<CefBrowser>, const std::vector<CefString> &urls) override {
        PCEFBrowser *owner = owner_;
        [owner.delegate browser:owner didChangeFaviconURL:urls.empty() ? nil : NSStringFromCef(urls.front())];
    }
    void OnFullscreenModeChange(CefRefPtr<CefBrowser>, bool fullscreen) override {
        PCEFBrowser *owner = owner_;
        [owner.delegate browser:owner fullscreenChanged:fullscreen];
    }
    void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
        PCEFBrowser *owner = owner_;
        [owner.delegate browser:owner didChangeProgress:progress];
    }

    // Load
    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool isLoading, bool canGoBack, bool canGoForward) override {
        PCEFBrowser *owner = owner_;
        owner.isLoading = isLoading;
        owner.canGoBack = canGoBack;
        owner.canGoForward = canGoForward;
        [owner.delegate browserLoadingStateChanged:owner];
    }

    // Life span
    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString &targetURL,
                       const CefString &, WindowOpenDisposition disposition, bool userGesture,
                       const CefPopupFeatures &features, CefWindowInfo &, CefRefPtr<CefClient> &client, CefBrowserSettings &,
                       CefRefPtr<CefDictionaryValue> &, bool *) override {
        gNextPopupSize = CefSize(features.widthSet ? features.width : 0, features.heightSet ? features.height : 0);
        PCEFBrowser *owner = owner_;
        BOOL handled = [owner.delegate browser:owner openURL:NSStringFromCef(targetURL)
                                    disposition:DispositionFrom(disposition)
                                    userGesture:userGesture];
        if (handled) return true;
        client = new PopupClient();   // a popup keeps its own callbacks away from this page
        return false;
    }
    void OnAfterCreated(CefRefPtr<CefBrowser>) override { gLiveBrowsers++; }
    void OnBeforeClose(CefRefPtr<CefBrowser>) override {
        [owner_ _destroyed];
        NoteBrowserClosed();
    }

    // Request
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                                   CefRefPtr<CefRequest>, bool, bool, const CefString &,
                                                                   bool &) override {
        return PrivacySignals();
    }
    bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                        bool userGesture, bool isRedirect) override {
        if (!frame->IsMain()) return false;
        bool linkClick = (request->GetTransitionType() & TT_SOURCE_MASK) == TT_LINK && userGesture;
        PCEFBrowser *owner = owner_;
        BOOL allow = [owner.delegate browser:owner shouldNavigateTo:NSStringFromCef(request->GetURL())
                                    linkClick:linkClick isRedirect:isRedirect];
        return !allow;
    }
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &targetURL,
                          WindowOpenDisposition disposition, bool userGesture) override {
        if (disposition == CEF_WOD_CURRENT_TAB) return false;
        PCEFBrowser *owner = owner_;
        return [owner.delegate browser:owner openURL:NSStringFromCef(targetURL)
                            disposition:DispositionFrom(disposition)
                            userGesture:userGesture];
    }

    // Keyboard: Plinth's menu shortcuts win over the page and over Chrome's own accelerators.
    bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent &event, CefEventHandle osEvent,
                       bool *) override {
        if (event.type != KEYEVENT_RAWKEYDOWN && event.type != KEYEVENT_KEYDOWN) return false;
        NSEvent *nsEvent = (__bridge NSEvent *)osEvent;
        if (!nsEvent || !(nsEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))) return false;
        PCEFBrowser *owner = owner_;
        return [owner.delegate browser:owner handleKeyEquivalent:nsEvent];
    }

    // Commands
    bool OnChromeCommand(CefRefPtr<CefBrowser>, int commandID, cef_window_open_disposition_t) override {
        return BlockedChromeCommands().count(commandID) > 0;
    }
    bool IsChromeAppMenuItemVisible(CefRefPtr<CefBrowser>, int commandID) override {
        return BlockedChromeCommands().count(commandID) == 0;
    }

    // Answers from the renderer helper to -evaluateJavaScript:completion:, and the password script's messages.
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (source != PID_RENDERER) return false;
        if (message->GetName().ToString() == kPasswordMessage) {
            CefRefPtr<CefListValue> args = message->GetArgumentList();
            PCEFBrowser *owner = owner_;
            id<PCEFBrowserDelegate> delegate = owner.delegate;
            if (!frame || args->GetSize() < 1 || args->GetType(0) != VTYPE_DICTIONARY ||
                ![delegate respondsToSelector:@selector(browser:passwordMessage:frame:frameURL:isMainFrame:)]) return true;
            id body = NSObjectFromCefValue(args->GetValue(0), 0);
            if (![body isKindOfClass:NSDictionary.class]) return true;
            [delegate browser:owner passwordMessage:body frame:NSStringFromCef(frame->GetIdentifier())
                     frameURL:NSStringFromCef(frame->GetURL()) isMainFrame:frame->IsMain()];
            return true;
        }
        if (message->GetName().ToString() == kMediaMessage) {
            CefRefPtr<CefListValue> args = message->GetArgumentList();
            PCEFBrowser *owner = owner_;
            id<PCEFBrowserDelegate> delegate = owner.delegate;
            if (!frame || args->GetSize() < 1 || args->GetType(0) != VTYPE_DICTIONARY ||
                ![delegate respondsToSelector:@selector(browser:mediaMessage:frameURL:)]) return true;
            id body = NSObjectFromCefValue(args->GetValue(0), 0);
            if ([body isKindOfClass:NSDictionary.class]) {
                [delegate browser:owner mediaMessage:body frameURL:NSStringFromCef(frame->GetURL())];
            }
            return true;
        }
        if (message->GetName().ToString() != kEvalResultMessage) return false;
        CefRefPtr<CefListValue> args = message->GetArgumentList();
        if (args->GetSize() < 3) return true;
        int requestID = args->GetInt(0);
        id value = args->GetBool(1) ? NSObjectFromCefValue(args->GetValue(2), 0) : nil;
        [owner_ _evaluationFinished:requestID value:value];
        return true;
    }

private:
    __weak PCEFBrowser *owner_;
    IMPLEMENT_REFCOUNTING(BrowserClient);
};

class BrowserViewDelegate : public CefBrowserViewDelegate {
public:
    explicit BrowserViewDelegate(PCEFBrowser *owner) : owner_(owner) {}

    void OnBrowserCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> browser) override {
        [owner_ _created:browser];
    }
    cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
    ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }

    CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(CefRefPtr<CefBrowserView>,
                                                                     const CefBrowserSettings &,
                                                                     CefRefPtr<CefClient>, bool) override;
    bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowserView> popup, bool) override;

private:
    __weak PCEFBrowser *owner_;
    IMPLEMENT_REFCOUNTING(BrowserViewDelegate);
};

/// The delegate for a scripted popup's browser view (sign-in windows and the like).
class PopupViewDelegate : public CefBrowserViewDelegate {
public:
    cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
    ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
    IMPLEMENT_REFCOUNTING(PopupViewDelegate);
};

/// A plain window holding one popup browser view.
class PopupWindowDelegate : public CefWindowDelegate {
public:
    explicit PopupWindowDelegate(CefRefPtr<CefBrowserView> view) : view_(view) {}
    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        window->AddChildView(view_);
        FloatOverPlinth(window, gNextPopupSize);
        gNextPopupSize = CefSize(0, 0);
        view_->RequestFocus();
    }
    void OnWindowDestroyed(CefRefPtr<CefWindow>) override { view_ = nullptr; }
    bool CanClose(CefRefPtr<CefWindow>) override {
        CefRefPtr<CefBrowser> browser = view_ ? view_->GetBrowser() : nullptr;
        return browser ? browser->GetHost()->TryCloseBrowser() : true;
    }
    cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }

private:
    CefRefPtr<CefBrowserView> view_;
    IMPLEMENT_REFCOUNTING(PopupWindowDelegate);
};

/// Hands the main frame's text to a block (CefFrame::GetText).
class TextVisitor : public CefStringVisitor {
public:
    explicit TextVisitor(void (^done)(NSString *)) : done_([done copy]) {}
    void Visit(const CefString &string) override {
        if (done_) done_(NSStringFromCef(string));
        done_ = nil;
    }

private:
    void (^done_)(NSString *);
    IMPLEMENT_REFCOUNTING(TextVisitor);
};

/// Waits for one DevTools method's result (Page.captureScreenshot) and hands its JSON to a block.
class DevToolsResultObserver : public CefDevToolsMessageObserver {
public:
    explicit DevToolsResultObserver(void (^done)(NSData *)) : done_([done copy]) {}
    int messageID = 0;
    CefRefPtr<CefRegistration> registration;

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success, const void *result,
                                size_t result_size) override {
        if (message_id != messageID || !done_) return;
        NSData *json = success && result ? [NSData dataWithBytes:result length:result_size] : nil;
        void (^done)(NSData *) = done_;
        done_ = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
        registration = nullptr;   // stop observing; the browser holds no other reference
    }

private:
    void (^done_)(NSData *);
    IMPLEMENT_REFCOUNTING(DevToolsResultObserver);
};

/// The borderless window that holds one page's browser view.
class HostWindowDelegate : public CefWindowDelegate {
public:
    HostWindowDelegate(PCEFBrowser *owner, CefRefPtr<CefBrowserView> view) : owner_(owner), view_(view) {}

    void OnWindowCreated(CefRefPtr<CefWindow> window) override {
        window->AddChildView(view_);
        [owner_ _hostCreated:window];
    }
    void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
        view_ = nullptr;
        [owner_ _hostDestroyed];
    }
    void OnWindowActivationChanged(CefRefPtr<CefWindow>, bool active) override {
        if (active) [owner_ _hostActivated];
    }
    bool CanClose(CefRefPtr<CefWindow>) override { return [owner_ _hostCanClose]; }
    bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
    bool WithStandardWindowButtons(CefRefPtr<CefWindow>) override { return false; }
    bool CanMaximize(CefRefPtr<CefWindow>) override { return false; }
    bool CanMinimize(CefRefPtr<CefWindow>) override { return false; }
    CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(-20000, -20000, 800, 600); }
    cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }

private:
    __weak PCEFBrowser *owner_;
    CefRefPtr<CefBrowserView> view_;
    IMPLEMENT_REFCOUNTING(HostWindowDelegate);
};

CefRefPtr<CefBrowserViewDelegate> BrowserViewDelegate::GetDelegateForPopupBrowserView(
    CefRefPtr<CefBrowserView>, const CefBrowserSettings &, CefRefPtr<CefClient>, bool) {
    return new PopupViewDelegate();
}

bool BrowserViewDelegate::OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowserView> popup,
                                                    bool) {
    CefWindow::CreateTopLevelWindow(new PopupWindowDelegate(popup));
    return true;
}

} // namespace

@implementation PCEFBrowser {
    CefRefPtr<BrowserClient> _client;
    CefRefPtr<CefBrowserView> _browserView;
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<CefWindow> _host;
    NSString *_pendingURL;
    BOOL _closed;
    double _pendingZoom;
    /// Scripts sent to the renderer and waiting for an answer, by request number.
    NSMutableDictionary<NSNumber *, void (^)(id)> *_evaluations;
}

static int gNextEvaluationID = 1;

- (instancetype)initWithURL:(NSString *)url profile:(PCEFProfile *)profile delegate:(id<PCEFBrowserDelegate>)delegate {
    if ((self = [super init])) {
        _profile = profile;
        _delegate = delegate;
        _address = [url copy];
        _title = @"";
        _client = new BrowserClient(self);
        CefBrowserSettings settings;
        // The renderer helper reads the password and media scripts from here (OnBrowserCreated's extra_info).
        CefRefPtr<CefDictionaryValue> extra = nullptr;
        if (gPasswordScript.length || gMediaScript.length) extra = CefDictionaryValue::Create();
        if (gPasswordScript.length) {
            extra->SetString("plinth.passwords", CefFromNSString(gPasswordScript));
            extra->SetBool("plinth.passwords.test", gPasswordTestMode);
        }
        if (gMediaScript.length) extra->SetString("plinth.media", CefFromNSString(gMediaScript));
        _browserView = CefBrowserView::CreateBrowserView(_client, CefFromNSString(url), settings, extra,
                                                         profile->_context, new BrowserViewDelegate(self));
        CefWindow::CreateTopLevelWindow(new HostWindowDelegate(self, _browserView));
    }
    return self;
}

- (void)_hostCreated:(CefRefPtr<CefWindow>)window {
    _host = window;
    id handle = (__bridge id)window->GetWindowHandle();
    NSWindow *ns = [handle isKindOfClass:NSWindow.class] ? handle : [(NSView *)handle window];
    ns.excludedFromWindowsMenu = YES;
    ns.hasShadow = NO;
    ns.identifier = @"plinth.page";
    _hostWindow = ns;
    [self.delegate browserHostWindowReady:self];
}

- (void)_hostDestroyed {
    _host = nullptr;
    _hostWindow = nil;
}

- (void)_hostActivated { [self.delegate browserDidActivate:self]; }

- (BOOL)_hostCanClose {
    // Only Plinth closes a page's window, and only through -close (which then closes the browser too).
    return _closed;
}

- (void)attachTo:(NSWindow *)parent frame:(NSRect)frame cornerRadius:(CGFloat)cornerRadius {
    if (!_host || !_hostWindow) return;
    NSWindow *ns = _hostWindow;
    if (!parent) {
        if (ns.parentWindow) [ns.parentWindow removeChildWindow:ns];
        // Hide through Views so Chromium knows the page is hidden (it throttles hidden pages).
        _host->Hide();
        return;
    }
    if (ns.parentWindow && ns.parentWindow != parent) [ns.parentWindow removeChildWindow:ns];
    // Corners are rounded by the shell drawing over them: clipping Chromium's own layers here stops
    // the page repainting when it is resized.
    (void)cornerRadius;
    _host->SetBounds(CefRectFromScreenRect(frame));
    if (!_host->IsVisible()) _host->Show();
    if (ns.parentWindow != parent) [parent addChildWindow:ns ordered:NSWindowAbove];
}

- (void)focus {
    if (_browserView) _browserView->RequestFocus();
}

- (CefRefPtr<CefBrowserView>)_view { return _browserView; }

- (void)_created:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    if (_pendingURL) {
        browser->GetMainFrame()->LoadURL(CefFromNSString(_pendingURL));
        _pendingURL = nil;
    }
    if (_pendingZoom != 0) browser->GetHost()->SetZoomLevel(_pendingZoom);
}

- (void)_destroyed {
    [self _failEvaluations];
    _browser = nullptr;
    _client = nullptr;
    if (_host) _host->Close();
    _browserView = nullptr;
    [self.delegate browserDidClose:self];
}

- (BOOL)isCreated { return _browser != nullptr; }

- (void)loadURL:(NSString *)url {
    self.address = url;
    if (_browser) _browser->GetMainFrame()->LoadURL(CefFromNSString(url));
    else _pendingURL = [url copy];
}

- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }

- (double)defaultZoomLevel { return _browser ? _browser->GetHost()->GetDefaultZoomLevel() : 0; }
- (double)zoomLevel { return _browser ? _browser->GetHost()->GetZoomLevel() : _pendingZoom; }
- (void)setZoomLevel:(double)zoomLevel {
    _pendingZoom = zoomLevel;
    if (_browser) _browser->GetHost()->SetZoomLevel(zoomLevel);
}

- (void)find:(NSString *)text forward:(BOOL)forward {
    if (_browser && text.length) _browser->GetHost()->Find(CefFromNSString(text), forward, false, true);
}
- (void)stopFinding { if (_browser) _browser->GetHost()->StopFinding(true); }

- (BOOL)executeChromeCommand:(NSString *)name {
    if (!_browser) return NO;
    int commandID = cef_id_for_command_id_name(name.UTF8String);
    if (commandID <= 0 || !_browser->GetHost()->CanExecuteChromeCommand(commandID)) return NO;
    _browser->GetHost()->ExecuteChromeCommand(commandID, CEF_WOD_CURRENT_TAB);
    return YES;
}

- (void)executeJavaScript:(NSString *)script {
    if (_browser) _browser->GetMainFrame()->ExecuteJavaScript(CefFromNSString(script), "", 0);
}

- (void)evaluateJavaScript:(NSString *)expression completion:(void (^)(id))completion {
    void (^done)(id) = [completion copy];
    if (!_browser || _closed) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        return;
    }
    int requestID = gNextEvaluationID++;
    if (!_evaluations) _evaluations = [NSMutableDictionary dictionary];
    _evaluations[@(requestID)] = done;
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kEvalMessage);
    message->GetArgumentList()->SetInt(0, requestID);
    message->GetArgumentList()->SetString(1, CefFromNSString(expression));
    _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
    // The renderer can go away mid-navigation without answering.
    __weak PCEFBrowser *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kEvalTimeout), dispatch_get_main_queue(), ^{
        [weakSelf _evaluationFinished:requestID value:nil];
    });
}

- (void)_evaluationFinished:(int)requestID value:(id)value {
    void (^done)(id) = _evaluations[@(requestID)];
    if (!done) return;
    [_evaluations removeObjectForKey:@(requestID)];
    done(value);
}

- (void)_failEvaluations {
    NSDictionary<NSNumber *, void (^)(id)> *pending = [_evaluations copy];
    [_evaluations removeAllObjects];
    for (NSNumber *key in pending) pending[key](nil);
}

- (void)fillPasswordInFrame:(NSString *)frameID token:(NSInteger)token username:(NSString *)username
                   password:(NSString *)password {
    if (!_browser || _closed) return;
    CefRefPtr<CefFrame> frame = _browser->GetFrameByIdentifier(CefFromNSString(frameID));
    if (!frame) return;
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPasswordFillMessage);
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    args->SetInt(0, (int)token);
    args->SetString(1, CefFromNSString(username));
    args->SetString(2, CefFromNSString(password));
    frame->SendProcessMessage(PID_RENDERER, message);
}

- (void)sendScrollAt:(NSPoint)point deltaX:(CGFloat)deltaX deltaY:(CGFloat)deltaY {
    if (!_browser || _closed) return;
    CefMouseEvent event;
    event.x = (int)point.x;
    event.y = (int)point.y;
    event.modifiers = 0;
    _browser->GetHost()->SendMouseWheelEvent(event, (int)deltaX, (int)deltaY);
}

- (void)readPlainText:(void (^)(NSString *))completion {
    __block void (^done)(NSString *) = [completion copy];
    if (!_browser || _closed) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        return;
    }
    void (^once)(NSString *) = ^(NSString *text) {
        if (!done) return;
        void (^call)(NSString *) = done;
        done = nil;
        call(text);
    };
    _browser->GetMainFrame()->GetText(new TextVisitor(once));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kEvalTimeout), dispatch_get_main_queue(), ^{ once(nil); });
}

- (void)captureSnapshot:(void (^)(NSData *))completion {
    __block void (^done)(NSData *) = [completion copy];
    if (!_browser || _closed) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        return;
    }
    void (^once)(NSData *) = ^(NSData *json) {
        if (!done) return;
        void (^call)(NSData *) = done;
        done = nil;
        NSData *image = nil;
        if (json) {
            NSDictionary *result = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
            NSString *base64 = [result isKindOfClass:[NSDictionary class]] ? result[@"data"] : nil;
            if ([base64 isKindOfClass:[NSString class]]) image = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        }
        call(image);
    };
    CefRefPtr<DevToolsResultObserver> observer = new DevToolsResultObserver(once);
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    observer->registration = host->AddDevToolsMessageObserver(observer);
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("format", "jpeg");
    params->SetInt("quality", 70);
    observer->messageID = host->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
    if (observer->messageID == 0) { once(nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kEvalTimeout), dispatch_get_main_queue(), ^{
        observer->registration = nullptr;
        once(nil);
    });
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    PLog([NSString stringWithFormat:@"close browser created=%d host=%d", _browser != nullptr, _host != nullptr]);
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
    } else {
        // Chromium never started it: closing its window is enough.
        _client = nullptr;
        if (_host) _host->Close();
        _browserView = nullptr;
        [self.delegate browserDidClose:self];
    }
}

@end

