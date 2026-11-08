//! Non-VM feasibility fixture linked to the verified clean SDK source.
fn main() {
    let name = std::env::args().nth(1).expect("fixture filename");
    assert!(name.starts_with("smolbox-template-fixture-"));
    assert!(name
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b".-".contains(&byte)));
    if let Some(path) = smolvm_pack::assets::find_existing_template(&name) {
        println!("{}", path.display());
    }
}
