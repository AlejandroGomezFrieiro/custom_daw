//! Tells the crate whether LuaJIT is being built to look for hooks in
//! compiled code: `.cargo/config.toml` asks for it through the C flags that
//! `mlua`'s build of LuaJIT reads.
//!
//! It also compiles the Lua runtime (`runtime/lua`) to LuaJIT bytecode, which
//! the kernel loads in place of the source: parsing the runtime was most of
//! the time the program took to start.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

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
    compile_runtime(&target);
}

/// Write `$OUT_DIR/bytecode.rs`: the runtime's modules as bytecode, by their
/// path under `runtime/lua`, sorted. Empty when the program is built for
/// another machine, whose LuaJIT may not read this one's bytecode.
fn compile_runtime(target: &str) {
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"))
        .join("../../runtime/lua");
    println!("cargo:rerun-if-changed={}", root.display());
    let mut files = Vec::new();
    if std::env::var("HOST").ok().as_deref() == Some(target) {
        collect(&root, &root, &mut files);
    }
    files.sort();
    let lua = mlua::Lua::new();
    let dir = out.join("bytecode");
    std::fs::create_dir_all(&dir).expect("bytecode directory");
    let mut code = String::from("pub static BYTECODE: &[(&str, &[u8])] = &[\n");
    for (i, rel) in files.iter().enumerate() {
        let source = std::fs::read(root.join(rel)).expect("a runtime file");
        // A module that does not compile is left as source: loading it
        // gives the same error, with the same message, as before.
        let Ok(func) = lua
            .load(&source[..])
            .set_name(format!("@runtime/lua/{rel}"))
            .into_function()
        else {
            continue;
        };
        let file = dir.join(format!("{i}.luac"));
        std::fs::write(&file, func.dump(false)).expect("writing bytecode");
        writeln!(code, "    ({rel:?}, include_bytes!({:?})),", file.display().to_string()).unwrap();
    }
    code.push_str("];\n");
    std::fs::write(out.join("bytecode.rs"), code).expect("writing bytecode.rs");
}

/// The `.lua` files under `dir`, as paths relative to `root` with `/`.
fn collect(root: &Path, dir: &Path, files: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(root, &path, files);
        } else if path.extension().is_some_and(|e| e == "lua")
            && let Ok(rel) = path.strip_prefix(root)
        {
            files.push(rel.to_string_lossy().replace('\\', "/"));
        }
    }
}
