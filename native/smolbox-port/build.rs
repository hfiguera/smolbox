fn main() {
    match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") => println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/lib"),
        Ok("linux") => println!("cargo:rustc-link-arg=-Wl,--disable-new-dtags,-rpath,$ORIGIN/lib"),
        _ => {}
    }
}
