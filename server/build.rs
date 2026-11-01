// libactuon_core.a comes from `zig build core` in the repository root.
fn main() {
    let root = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    println!("cargo:rustc-link-search=native={root}/../zig-out/lib");
    println!("cargo:rustc-link-lib=static=actuon_core");
    println!("cargo:rerun-if-changed={root}/../zig-out/lib/libactuon_core.a");
}
