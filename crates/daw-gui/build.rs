fn main() {
    // The windowing and OpenGL libraries are loaded by name when the
    // program starts. Where the system keeps none in the usual places
    // (NixOS), the build environment says where they are, and the binary
    // remembers.
    println!("cargo:rerun-if-env-changed=DAW_GUI_LIBS");
    if let Ok(dirs) = std::env::var("DAW_GUI_LIBS") {
        for dir in dirs.split(':').filter(|dir| !dir.is_empty()) {
            println!("cargo:rustc-link-arg-bins=-Wl,-rpath,{dir}");
        }
    }
}
