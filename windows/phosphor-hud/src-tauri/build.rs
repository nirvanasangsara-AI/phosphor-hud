fn main() {
    let manifest_dir = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let version_file = manifest_dir.join("../../../VERSION");
    println!("cargo:rerun-if-changed={}", version_file.display());
    let raw = std::fs::read_to_string(&version_file)
        .unwrap_or_else(|err| panic!("VERSION file is missing ({}): {err}", version_file.display()));
    let version = raw.trim();
    if !version_ok(version) {
        panic!("VERSION must look like 0.2.1, found: {version}");
    }
    println!("cargo:rustc-env=PHOSPHOR_VERSION={version}");
    // The bundler also reads this when the Tauri CLI is given the same overlay.
    std::env::set_var("TAURI_CONFIG", format!(r#"{{"version":"{version}"}}"#));
    tauri_build::build();
}

fn version_ok(version: &str) -> bool {
    let mut parts = version.split('.');
    let Some(major) = parts.next() else {
        return false;
    };
    if major.is_empty() || !major.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let rest: Vec<&str> = parts.collect();
    (1..=3).contains(&rest.len()) && rest.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}
