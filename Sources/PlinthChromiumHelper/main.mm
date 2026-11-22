// The helper executable Chromium launches for its renderer, GPU, utility and plugin processes.
// Scripts/bundle.sh copies it into the five "<App> Helper*.app" bundles under Contents/Frameworks.
//
// In a renderer it also answers Plinth's "plinth.eval" messages: it evaluates a script in the page's
// main frame and sends the value back as plain values (see -[PCEFBrowser evaluateJavaScript:completion:]).
//
// And it runs Plinth's password script in every http(s) frame, before the page's own scripts (see
// +[PCEFRuntime passwordScript]). The script gets a native `post` function and returns its fill
// function; both stay here, never on `window`, so the page can neither send Plinth messages that look
// like the person's input nor swap the fill function for one that keeps the password.
#include <map>
#include <string>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

/// A V8 value as a CefValue that can cross to the browser process. Functions and anything deeper
/// than a few levels become null.
CefRefPtr<CefValue> ToCefValue(CefRefPtr<CefV8Value> v, int depth) {
    CefRefPtr<CefValue> out = CefValue::Create();
    if (!v || depth > 12 || v->IsNull() || v->IsUndefined() || v->IsFunction()) {
        out->SetNull();
    } else if (v->IsBool()) {
        out->SetBool(v->GetBoolValue());
    } else if (v->IsInt()) {
        out->SetInt(v->GetIntValue());
    } else if (v->IsUInt() || v->IsDouble()) {
        out->SetDouble(v->GetDoubleValue());
    } else if (v->IsString()) {
        out->SetString(v->GetStringValue());
    } else if (v->IsArray()) {
        CefRefPtr<CefListValue> list = CefListValue::Create();
        int count = v->GetArrayLength();
        for (int i = 0; i < count; i++) list->SetValue(i, ToCefValue(v->GetValue(i), depth + 1));
        out->SetList(list);
    } else if (v->IsObject()) {
        CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
        std::vector<CefString> keys;
        if (v->GetKeys(keys)) {
            for (const CefString &key : keys) dict->SetValue(key, ToCefValue(v->GetValue(key), depth + 1));
        }
        out->SetDictionary(dict);
    } else {
        out->SetNull();
    }
    return out;
}

/// The password script for each browser (from OnBrowserCreated's extra_info), with a count of the
/// browser objects alive under that identifier: a cross-origin navigation can create the new one
/// before the old one is destroyed.
struct PasswordConfig {
    std::string script;
    bool testMode = false;
    int live = 0;
};
std::map<int, PasswordConfig> gPasswordConfigs;

/// The fill function the script returned in each frame, with the context it belongs to.
struct FrameFill {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> fill;
};
std::map<std::string, FrameFill> gFills;

bool IsWebAddress(const std::string &url) { return url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0; }

/// The script's `post`: sends one plain object to the browser process, from this frame.
class PasswordPost : public CefV8Handler {
public:
    explicit PasswordPost(CefRefPtr<CefFrame> frame) : frame_(frame) {}
    bool Execute(const CefString &, CefRefPtr<CefV8Value>, const CefV8ValueList &arguments, CefRefPtr<CefV8Value> &,
                 CefString &) override {
        if (arguments.size() != 1 || !arguments[0]->IsObject() || arguments[0]->IsArray() || arguments[0]->IsFunction()) return true;
        if (!frame_ || !frame_->IsValid()) return true;
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create("plinth.pw");
        message->GetArgumentList()->SetValue(0, ToCefValue(arguments[0], 0));
        frame_->SendProcessMessage(PID_BROWSER, message);
        return true;
    }

private:
    CefRefPtr<CefFrame> frame_;
    IMPLEMENT_REFCOUNTING(PasswordPost);
};

class HelperApp : public CefApp, public CefRenderProcessHandler {
public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra) override {
        if (!extra || !extra->HasKey("plinth.passwords")) return;
        PasswordConfig &config = gPasswordConfigs[browser->GetIdentifier()];
        config.script = extra->GetString("plinth.passwords").ToString();
        config.testMode = extra->HasKey("plinth.passwords.test") && extra->GetBool("plinth.passwords.test");
        config.live += 1;
    }

    void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
        auto it = gPasswordConfigs.find(browser->GetIdentifier());
        if (it != gPasswordConfigs.end() && --it->second.live <= 0) gPasswordConfigs.erase(it);
    }

    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        auto it = gPasswordConfigs.find(browser->GetIdentifier());
        if (it == gPasswordConfigs.end() || it->second.script.empty() || !IsWebAddress(frame->GetURL().ToString())) return;
        CefRefPtr<CefV8Value> factory;
        CefRefPtr<CefV8Exception> exception;
        if (!context->Eval(it->second.script, CefString(), 0, factory, exception) || !factory || !factory->IsFunction()) return;
        CefV8ValueList args;
        args.push_back(CefV8Value::CreateFunction("post", new PasswordPost(frame)));
        args.push_back(CefV8Value::CreateBool(it->second.testMode));
        CefRefPtr<CefV8Value> fill = factory->ExecuteFunctionWithContext(context, nullptr, args);
        if (fill && fill->IsFunction()) gFills[frame->GetIdentifier().ToString()] = FrameFill{context, fill};
    }

    void OnContextReleased(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
        auto it = gFills.find(frame->GetIdentifier().ToString());
        if (it != gFills.end() && it->second.context->IsSame(context)) gFills.erase(it);
    }

    /// Plinth's fill for one frame: the login the person chose, handed straight to the script's fill function.
    void FillPassword(CefRefPtr<CefFrame> frame, CefRefPtr<CefListValue> args) {
        auto it = gFills.find(frame->GetIdentifier().ToString());
        if (it == gFills.end() || args->GetSize() < 3) return;
        if (!it->second.context->IsValid()) { gFills.erase(it); return; }
        CefV8ValueList values;
        values.push_back(CefV8Value::CreateInt(args->GetInt(0)));
        values.push_back(CefV8Value::CreateString(args->GetString(1)));
        values.push_back(CefV8Value::CreateString(args->GetString(2)));
        it->second.fill->ExecuteFunctionWithContext(it->second.context, nullptr, values);
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (source == PID_BROWSER && message->GetName().ToString() == "plinth.pw.fill") {
            FillPassword(frame, message->GetArgumentList());
            return true;
        }
        if (source != PID_BROWSER || message->GetName().ToString() != "plinth.eval") return false;
        CefRefPtr<CefListValue> args = message->GetArgumentList();
        CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create("plinth.eval.result");
        CefRefPtr<CefListValue> out = reply->GetArgumentList();
        out->SetInt(0, args->GetInt(0));
        bool ok = false;
        CefRefPtr<CefV8Context> context = frame->GetV8Context();
        if (context && context->Enter()) {
            CefRefPtr<CefV8Value> value;
            CefRefPtr<CefV8Exception> exception;
            if (context->Eval(args->GetString(1), CefString(), 0, value, exception) && value) {
                out->SetValue(2, ToCefValue(value, 0));
                ok = true;
            }
            context->Exit();
        }
        out->SetBool(1, ok);
        if (!ok) out->SetNull(2);
        frame->SendProcessMessage(PID_BROWSER, reply);
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(HelperApp);
};

} // namespace

int main(int argc, char *argv[]) {
    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper()) return 1;
    CefMainArgs mainArgs(argc, argv);
    CefRefPtr<HelperApp> app(new HelperApp());
    return CefExecuteProcess(mainArgs, app, nullptr);
}
