//! Tells the crate whether LuaJIT is being built to look for hooks in
//! compiled code: `.cargo/config.toml` asks for it through the C flags that
//! `mlua`'s build of LuaJIT reads.

fn main() {
    println!("cargo:rustc-check-cfg=cfg(lua_checkhook)");
    let target = std::env::var("TARGET").unwrap_or_default();
    let names = [
        format!("CFLAGS_{target}"),
        format!("CFLAGS_{}", target.replace('-', "_")),
        "TARGET_CFLAGS".to_string(),
        "CFLAGS".to_string(),
    ];
    for name in &names {
        println!("cargo:rerun-if-env-changed={name}");
    }
    // The first of these that is set is the one the C compiler is given.
    let flags = names.iter().find_map(|name| std::env::var(name).ok());
    if flags.is_some_and(|flags| flags.contains("LUAJIT_ENABLE_CHECKHOOK")) {
        println!("cargo:rustc-cfg=lua_checkhook");
    }
}
