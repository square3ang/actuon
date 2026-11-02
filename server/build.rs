// libactuon_core.a comes from `zig build core` in the repository root. The static build for deployment
// links one built for musl, kept in zig-out/musl so it never replaces the one tests use.
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
