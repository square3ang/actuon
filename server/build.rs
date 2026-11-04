// libactuon_core.a comes from `zig build core`; the musl deploy build uses zig-out/musl so tests keep theirs.
fn main() {
    let root = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let out = if std::env::var("TARGET").unwrap().ends_with("musl") {
        "zig-out/musl"
    } else {
        "zig-out"
    };
    println!("cargo:rustc-link-search=native={root}/../{out}/lib");
    println!("cargo:rustc-link-lib=static=actuon_core");
    println!("cargo:rerun-if-changed={root}/../{out}/lib/libactuon_core.a");
}
