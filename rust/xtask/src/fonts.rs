// `cargo xtask fonts`: the image's fonts, for vrx_check's layout test.
//
// Text has to measure on the host as it does on the board, so the gate
// lays screens out in the fonts the image ships, fetched from the same
// sources and checked against the same sha256 as the Yocto recipes
// (meta-oe ttf-roboto_2.138, oe-core liberation-fonts_2.1.5). They land
// in ~/.cache/vrx/fonts, or VRX_FONTS, and are fetched once.

use std::path::{Path, PathBuf};
use std::process::Command;

struct Source {
    url: &'static str,
    sha256: &'static str,
    files: &'static [&'static str],
}

const SOURCES: &[Source] = &[
    Source {
        url: "https://github.com/google/roboto/releases/download/v2.138/roboto-android.zip",
        sha256: "c825453253f590cfe62557733e7173f9a421fff103b00f57d33c4ad28ae53baf",
        files: &["Roboto-Regular.ttf", "Roboto-Medium.ttf", "Roboto-Light.ttf"],
    },
    Source {
        url: "https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz",
        sha256: "7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0",
        files: &["LiberationMono-Regular.ttf"],
    },
];

/// Where vrx_check reads the fonts from.
pub fn dir() -> PathBuf {
    if let Some(d) = std::env::var_os("VRX_FONTS") {
        return PathBuf::from(d);
    }
    let home = std::env::var_os("HOME").unwrap_or_default();
    Path::new(&home).join(".cache/vrx/fonts")
}

/// Make sure every font is in [dir]; fetch what is missing.
pub fn ensure() -> Result<(), String> {
    let dir = dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for source in SOURCES {
        if source.files.iter().all(|f| dir.join(f).is_file()) {
            continue;
        }
        fetch(source, &dir)?;
    }
    Ok(())
}

fn run(cmd: &mut Command) -> Result<String, String> {
    let out = cmd.output().map_err(|e| format!("{cmd:?}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{cmd:?}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn sha256(path: &Path) -> Result<String, String> {
    // sha256sum on Linux, shasum on macOS
    let out = run(Command::new("sha256sum").arg(path))
        .or_else(|_| run(Command::new("shasum").args(["-a", "256"]).arg(path)))?;
    Ok(out.split_whitespace().next().unwrap_or_default().to_owned())
}

fn find(dir: &Path, name: &str) -> Option<PathBuf> {
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(found) = find(&path, name) {
                return Some(found);
            }
        } else if path.file_name().is_some_and(|n| n == name) {
            return Some(path);
        }
    }
    None
}

fn fetch(source: &Source, dir: &Path) -> Result<(), String> {
    println!("fonts: fetching {}", source.url);
    let work = std::env::temp_dir().join(format!("vrx-fonts-{}", std::process::id()));
    std::fs::create_dir_all(&work).map_err(|e| format!("{}: {e}", work.display()))?;
    let archive = work.join("archive");
    let result = (|| {
        run(Command::new("curl")
            .args(["-fsSL", "-o"])
            .arg(&archive)
            .arg(source.url))?;
        let got = sha256(&archive)?;
        if got != source.sha256 {
            return Err(format!(
                "{}: sha256 {got}, the recipe pins {}",
                source.url, source.sha256
            ));
        }
        if source.url.ends_with(".zip") {
            run(Command::new("unzip")
                .args(["-q", "-o"])
                .arg(&archive)
                .arg("-d")
                .arg(&work))?;
        } else {
            run(Command::new("tar")
                .arg("-xzf")
                .arg(&archive)
                .arg("-C")
                .arg(&work))?;
        }
        for file in source.files {
            let from = find(&work, file)
                .ok_or_else(|| format!("{}: no {file} inside", source.url))?;
            std::fs::copy(&from, dir.join(file)).map_err(|e| format!("{file}: {e}"))?;
        }
        Ok(())
    })();
    // the scratch copy goes either way
    let _ = std::fs::remove_dir_all(&work);
    result
}
