// vrx's own pages beside the vendored management page (vrx plan 0016
// D11): manage-ui/dist/ is evrx-rt's built page, copied unchanged; a page
// vrx adds lives as readable source in manage-ui/vrx/ and is served from
// its gzipped copy in dist/ (vrx-manage sends only .gz files). This is the
// one writer of those copies, and the gate checks each copy still unpacks
// to its source, so the page served is the page reviewed.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Each page: its source under manage-ui/vrx/, its copy under
/// manage-ui/dist/ (the URL is the copy's directory).
pub const PAGES: &[(&str, &str)] = &[("update.html", "update/index.html.gz")];

fn paths(repo: &Path, src: &str, dst: &str) -> (PathBuf, PathBuf) {
    let ui = repo.join("manage-ui");
    (ui.join("vrx").join(src), ui.join("dist").join(dst))
}

/// Write every copy: `gzip -n -9`, so the bytes depend only on the source.
pub fn run(repo: &Path) -> Result<(), String> {
    for (src, dst) in PAGES {
        let (src, dst) = paths(repo, src, dst);
        let out = Command::new("gzip")
            .args(["-n", "-9", "-c"])
            .arg(&src)
            .output()
            .map_err(|err| format!("gzip: {err}"))?;
        if !out.status.success() {
            return Err(format!("gzip {} failed", src.display()));
        }
        if let Some(dir) = dst.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|err| format!("{}: {err}", dir.display()))?;
        }
        std::fs::write(&dst, out.stdout)
            .map_err(|err| format!("{}: {err}", dst.display()))?;
        println!("manage-page: {}", dst.display());
    }
    Ok(())
}

/// The pages whose copy is missing or no longer unpacks to the source.
pub fn stale(repo: &Path) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for (src_name, dst_name) in PAGES {
        let (src, dst) = paths(repo, src_name, dst_name);
        let source =
            std::fs::read(&src).map_err(|err| format!("{}: {err}", src.display()))?;
        let unpacked = Command::new("gzip")
            .arg("-dc")
            .arg(&dst)
            .output()
            .map_err(|err| format!("gzip: {err}"))?;
        if !unpacked.status.success() || unpacked.stdout != source {
            out.push((*dst_name).to_owned());
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_copy_that_differs_from_its_source_is_stale() {
        let repo =
            std::env::temp_dir().join(format!("vrx-manage-page-{}", std::process::id()));
        std::fs::create_dir_all(repo.join("manage-ui/vrx")).unwrap();
        for (src, _) in PAGES {
            std::fs::write(repo.join("manage-ui/vrx").join(src), "<p>one</p>\n").unwrap();
        }
        assert_eq!(
            stale(&repo).unwrap().len(),
            PAGES.len(),
            "no copy yet: stale"
        );
        run(&repo).unwrap();
        assert!(stale(&repo).unwrap().is_empty(), "fresh copies");
        let (src, _) = PAGES[0];
        std::fs::write(repo.join("manage-ui/vrx").join(src), "<p>two</p>\n").unwrap();
        assert_eq!(stale(&repo).unwrap(), vec![PAGES[0].1.to_owned()]);
        let _ = std::fs::remove_dir_all(&repo);
    }
}
