#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <locale.h>
#include "gdextension_interface.h"

typedef char *(__cdecl *SetLocaleFn)(int, const char *);
static int use_locale_workaround;

static void initialize(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    if (level != GDEXTENSION_INITIALIZATION_CORE || !use_locale_workaround) {
        return;
    }

    // Godot 4.7's official Windows build can hit a process-wide CRT locale race
    // while glslang compiles shader variants. Set the legacy CRT to C before
    // rendering starts. See KhronosGroup/glslang issue #4507.
    HMODULE crt = GetModuleHandleW(L"msvcrt.dll");
    if (crt != NULL) {
        SetLocaleFn set_locale = (SetLocaleFn)GetProcAddress(crt, "setlocale");
        if (set_locale != NULL) {
            set_locale(LC_ALL, "C");
        }
    }
}

static void deinitialize(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    (void)level;
}

__declspec(dllexport) GDExtensionBool windows_shader_locale_init(
    GDExtensionInterfaceGetProcAddress get_proc_address,
    GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization
) {
    (void)library;
    GDExtensionInterfaceGetGodotVersion2 get_version =
        (GDExtensionInterfaceGetGodotVersion2)get_proc_address("get_godot_version2");
    GDExtensionGodotVersion2 version;
    get_version(&version);
    use_locale_workaround = version.major == 4 && version.minor == 7 && version.patch <= 2;
    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_CORE;
    initialization->initialize = initialize;
    initialization->deinitialize = deinitialize;
    initialization->userdata = NULL;
    return 1;
}
