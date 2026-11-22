// The CEF side of the bridge. Compiled with ARC; CEF objects are held in CefRefPtr ivars and the
// C++ handlers point back at their Objective-C owners weakly.
#import "PlinthCEF.h"

#include <crt_externs.h>
#include <set>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_id_mappers.h"
#include "include/cef_request_context.h"
#include "include/cef_version_info.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_library_loader.h"

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

static int gLiveBrowsers = 0;
static bool gQuitWhenClosed = false;

static void NoteBrowserClosed() {
    gLiveBrowsers = std::max(0, gLiveBrowsers - 1);
    if (gQuitWhenClosed && gLiveBrowsers == 0) CefQuitMessageLoop();
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

namespace {

class PlinthCefApp : public CefApp, public CefBrowserProcessHandler {
public:
    explicit PlinthCefApp(bool mockKeychain) : mockKeychain_(mockKeychain) {}

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnBeforeCommandLineProcessing(const CefString &processType, CefRefPtr<CefCommandLine> commandLine) override {
        if (!processType.empty()) return;
        // Test runs skip the Keychain prompt for Chromium's cookie encryption key.
        if (mockKeychain_) commandLine->AppendSwitch("use-mock-keychain");
        // Plinth draws its own tab UI; Chrome's first-run and default-browser prompts don't apply.
        commandLine->AppendSwitch("no-first-run");
        commandLine->AppendSwitch("no-default-browser-check");
    }

private:
    bool mockKeychain_;
    IMPLEMENT_REFCOUNTING(PlinthCefApp);
};

CefScopedLibraryLoader *gLoader = nullptr;

} // namespace

@implementation PCEFRuntime

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

    CefRefPtr<PlinthCefApp> app(new PlinthCefApp(mockKeychain));
    return CefInitialize(mainArgs, settings, app, nullptr);
}

+ (void)runMessageLoop { CefRunMessageLoop(); }
+ (void)quitMessageLoop { CefQuitMessageLoop(); }

+ (void)quitAfterBrowsersClose {
    gQuitWhenClosed = true;
    if (gLiveBrowsers == 0) CefQuitMessageLoop();
}

+ (void)shutdown {
    CefShutdown();
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

@implementation PCEFProfile

+ (PCEFProfile *)shared {
    static PCEFProfile *shared;
    if (!shared) {
        shared = [PCEFProfile new];
        shared->_context = CefRequestContext::GetGlobalContext();
        shared.path = NSStringFromCef(shared->_context->GetCachePath());
    }
    return shared;
}

+ (PCEFProfile *)makePrivate {
    PCEFProfile *profile = [PCEFProfile new];
    CefRequestContextSettings settings;   // empty cache_path: in memory only
    profile->_context = CefRequestContext::CreateContext(settings, nullptr);
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

/// The client for a scripted popup's own window: it only needs to exist and count itself.
class PopupClient : public CefClient, public CefLifeSpanHandler {
public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
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
                      public CefCommandHandler {
public:
    explicit BrowserClient(PCEFBrowser *owner) : owner_(owner) {}

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }

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
                       const CefPopupFeatures &, CefWindowInfo &, CefRefPtr<CefClient> &client, CefBrowserSettings &,
                       CefRefPtr<CefDictionaryValue> &, bool *) override {
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
        window->CenterWindow(CefSize(520, 680));
        window->Show();
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
}

- (instancetype)initWithURL:(NSString *)url profile:(PCEFProfile *)profile delegate:(id<PCEFBrowserDelegate>)delegate {
    if ((self = [super init])) {
        _profile = profile;
        _delegate = delegate;
        _address = [url copy];
        _title = @"";
        _client = new BrowserClient(self);
        CefBrowserSettings settings;
        _browserView = CefBrowserView::CreateBrowserView(_client, CefFromNSString(url), settings, nullptr,
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
    _hostWindow = ns;
    [self.delegate browserHostWindowReady:self];
}

- (void)_hostDestroyed {
    _host = nullptr;
    _hostWindow = nil;
}

- (void)_hostActivated { [self.delegate browserDidActivate:self]; }

- (BOOL)_hostCanClose {
    // Only Plinth closes a page's window, and only through -close.
    return _closed && !_browser;
}

- (void)attachBelow:(NSWindow *)parent frame:(NSRect)frame {
    if (!_host || !_hostWindow) return;
    NSWindow *ns = _hostWindow;
    if (!parent) {
        if (ns.parentWindow) [ns.parentWindow removeChildWindow:ns];
        // Hide through Views so Chromium knows the page is hidden (it throttles hidden pages).
        _host->Hide();
        return;
    }
    if (ns.parentWindow && ns.parentWindow != parent) [ns.parentWindow removeChildWindow:ns];
    _host->SetBounds(CefRectFromScreenRect(frame));
    if (!_host->IsVisible()) _host->Show();
    if (ns.parentWindow != parent) [parent addChildWindow:ns ordered:NSWindowBelow];
    [ns orderWindow:NSWindowBelow relativeTo:parent.windowNumber];
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

- (void)close {
    if (_closed) return;
    _closed = YES;
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

