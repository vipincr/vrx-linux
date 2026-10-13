// The page's files: stored gzipped (index.html is index.html.gz) and sent
// with Content-Encoding: gzip; a client that does not take gzip gets 406.

use std::path::{Path, PathBuf};

/// What a path answers.
#[derive(Debug, PartialEq, Eq)]
pub enum Answer {
    File {
        path: PathBuf,
        content_type: &'static str,
    },
    NotFound,
    NotAcceptable,
}

fn content_type(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "txt" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

/// The file for `path` (already checked by http::path_allowed) under
/// `root`: a directory is its index.html.
pub fn find(root: &Path, path: &str, accepts_gzip: bool) -> Answer {
    let rel = path.trim_start_matches('/');
    let rel = if rel.is_empty() || rel.ends_with('/') {
        format!("{rel}index.html")
    } else if root.join(rel).is_dir() {
        format!("{rel}/index.html")
    } else {
        rel.to_owned()
    };
    let file = root.join(format!("{rel}.gz"));
    if !file.is_file() {
        return Answer::NotFound;
    }
    if !accepts_gzip {
        return Answer::NotAcceptable;
    }
    Answer::File {
        path: file,
        content_type: content_type(&rel),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_are_their_gz_and_a_directory_is_its_index() {
        let root = std::env::temp_dir().join(format!("vrx-files-{}", std::process::id()));
        std::fs::create_dir_all(root.join("_next/static")).unwrap();
        std::fs::write(root.join("index.html.gz"), b"x").unwrap();
        std::fs::write(root.join("_next/static/a.js.gz"), b"x").unwrap();
        assert_eq!(
            find(&root, "/", true),
            Answer::File {
                path: root.join("index.html.gz"),
                content_type: "text/html; charset=utf-8"
            }
        );
        assert_eq!(
            find(&root, "/_next/static/a.js", true),
            Answer::File {
                path: root.join("_next/static/a.js.gz"),
                content_type: "text/javascript; charset=utf-8"
            }
        );
        assert_eq!(find(&root, "/missing.js", true), Answer::NotFound);
        assert_eq!(find(&root, "/", false), Answer::NotAcceptable);
        let _ = std::fs::remove_dir_all(&root);
    }
}
