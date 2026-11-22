// The helper executable Chromium launches for its renderer, GPU, utility and plugin processes.
// Scripts/bundle.sh copies it into the five "<App> Helper*.app" bundles under Contents/Frameworks.
//
// In a renderer it also answers Plinth's "plinth.eval" messages: it evaluates a script in the page's
// main frame and sends the value back as plain values (see -[PCEFBrowser evaluateJavaScript:completion:]).
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

class HelperApp : public CefApp, public CefRenderProcessHandler {
public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
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
