// G036 (vrx plan 0013 D16): every doc AGENTS.md names exists. AGENTS.md
// is where an agent or a developer starts; a doc it names that is not
// there sends them nowhere, and AGENTS.md named five such docs for months
// while only one existed.

use std::path::Path;

/// The `docs/...` paths named in `agents` (between backticks).
pub fn named(agents: &str) -> Vec<String> {
    let mut found = Vec::new();
    for piece in agents.split('`').skip(1).step_by(2) {
        if piece.starts_with("docs/") && !piece.contains(char::is_whitespace) {
            found.push(piece.to_owned());
        }
    }
    found.sort();
    found.dedup();
    found
}

/// The named docs that do not exist under `repo`.
pub fn missing(repo: &Path) -> Result<Vec<String>, String> {
    let agents = std::fs::read_to_string(repo.join("AGENTS.md"))
        .map_err(|err| format!("reading AGENTS.md: {err}"))?;
    Ok(named(&agents)
        .into_iter()
        .filter(|doc| !repo.join(doc).is_file())
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_takes_backticked_docs_paths_only() {
        let text = "- `docs/00-architecture.md` here\n- `rust/host/` and \
                    `docs/03-ipc.md`, `docs/03-ipc.md` again, plain docs/x.md";
        assert_eq!(
            named(text),
            vec!["docs/00-architecture.md", "docs/03-ipc.md"]
        );
    }

    #[test]
    fn a_named_doc_that_is_not_there_fails() {
        let repo = std::env::temp_dir().join(format!("vrx-docs-{}", std::process::id()));
        std::fs::create_dir_all(repo.join("docs")).unwrap();
        std::fs::write(repo.join("AGENTS.md"), "`docs/a.md` and `docs/b.md`").unwrap();
        std::fs::write(repo.join("docs/a.md"), "a").unwrap();
        assert_eq!(missing(&repo).unwrap(), vec!["docs/b.md"]);
        std::fs::write(repo.join("docs/b.md"), "b").unwrap();
        assert!(missing(&repo).unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&repo);
    }
}
