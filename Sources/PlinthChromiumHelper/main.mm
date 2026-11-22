// The helper executable Chromium launches for its renderer, GPU, utility and plugin processes.
// Scripts/bundle.sh copies it into the five "<App> Helper*.app" bundles under Contents/Frameworks.
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char *argv[]) {
    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper()) return 1;
    CefMainArgs mainArgs(argc, argv);
    return CefExecuteProcess(mainArgs, nullptr, nullptr);
}
