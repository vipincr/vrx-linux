// The photo folder (plan 0018 D15): /data/photos, written by camerad and
// read by whoever holds the `photos` grant. Names and numbering are
// take.rs's; this file is the disk: listing, free space, the atomic write.
// camerad never deletes a photo.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::bounds::MIN_FREE_BYTES;
use crate::take;

/// Why a photo was not stored.
#[derive(Debug, PartialEq, Eq)]
pub enum SaveError {
    /// IMG_9999.JPG exists.
    FolderFull,
    /// Under the free-space floor.
    NoRoom,
    Failed(String),
}

/// Free bytes on the folder's filesystem.
pub type FreeSpace = Box<dyn Fn(&Path) -> std::io::Result<u64> + Send>;

/// The folder and how it measures free space (a test says how much).
pub struct Folder {
    dir: PathBuf,
    free: FreeSpace,
}

fn statvfs_free(dir: &Path) -> std::io::Result<u64> {
    let s = rustix::fs::statvfs(dir)?;
    Ok(s.f_bavail.saturating_mul(s.f_frsize))
}

impl Folder {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: dir.into(),
            free: Box::new(statvfs_free),
        }
    }

    pub fn with_free(dir: impl Into<PathBuf>, free: FreeSpace) -> Self {
        Self {
            dir: dir.into(),
            free,
        }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The folder's file names (none when it does not exist yet).
    pub fn names(&self) -> Vec<String> {
        std::fs::read_dir(&self.dir)
            .map(|rd| {
                rd.flatten()
                    .filter_map(|e| e.file_name().into_string().ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Whether a photo can be kept now: the folder has a number left and the
    /// disk has the floor. Asked before a capture, so the camera is not
    /// started for a photo that cannot be stored.
    pub fn can_keep(&self) -> Result<(), SaveError> {
        if take::next_in(self.names().iter().map(String::as_str)).is_none() {
            return Err(SaveError::FolderFull);
        }
        // a folder not made yet is on its parent's filesystem
        let probe = if self.dir.exists() {
            self.dir.as_path()
        } else {
            self.dir.parent().unwrap_or(Path::new("/"))
        };
        match (self.free)(probe) {
            Ok(free) if free >= MIN_FREE_BYTES => Ok(()),
            Ok(_) => Err(SaveError::NoRoom),
            Err(e) => Err(SaveError::Failed(e.to_string())),
        }
    }

    /// Store `jpeg` as the next IMG_dddd.JPG and return its name. Written to
    /// a temp name and renamed, so a reader never sees half a photo.
    pub fn save(&self, jpeg: &[u8]) -> Result<String, SaveError> {
        self.can_keep()?;
        std::fs::create_dir_all(&self.dir)
            .map_err(|e| SaveError::Failed(e.to_string()))?;
        let n = take::next_in(self.names().iter().map(String::as_str))
            .ok_or(SaveError::FolderFull)?;
        let name = take::name(n).ok_or(SaveError::FolderFull)?;
        let tmp = self.dir.join(format!(".{name}.tmp"));
        let written = std::fs::File::create(&tmp)
            .and_then(|mut f| f.write_all(jpeg).and_then(|()| f.sync_all()));
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            return Err(SaveError::Failed(e.to_string()));
        }
        // the unit's UMask is 0077: the photos group reads what is kept
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Err(e) =
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o640))
            {
                let _ = std::fs::remove_file(&tmp);
                return Err(SaveError::Failed(e.to_string()));
            }
        }
        std::fs::rename(&tmp, self.dir.join(&name))
            .map_err(|e| SaveError::Failed(e.to_string()))?;
        Ok(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(dir: &Path, free: u64) -> Folder {
        Folder::with_free(dir, Box::new(move |_| Ok(free)))
    }

    #[test]
    fn photos_are_numbered_from_one_and_never_overwrite_a_higher_number() {
        let dir = tempfile::tempdir().unwrap();
        let f = folder(&dir.path().join("photos"), u64::MAX);
        assert_eq!(f.save(b"a").unwrap(), "IMG_0001.JPG");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(f.dir().join("IMG_0001.JPG"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o640, "the photos group can read it");
        }
        assert_eq!(f.save(b"b").unwrap(), "IMG_0002.JPG");
        std::fs::write(f.dir().join("IMG_0007.JPG"), b"x").unwrap();
        assert_eq!(f.save(b"c").unwrap(), "IMG_0008.JPG");
        assert_eq!(std::fs::read(f.dir().join("IMG_0002.JPG")).unwrap(), b"b");
        // no temp file is left behind
        assert!(
            f.names().iter().all(|n| !n.ends_with(".tmp")),
            "{:?}",
            f.names()
        );
    }

    #[test]
    fn a_full_folder_and_a_full_disk_are_named() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("IMG_9999.JPG"), b"x").unwrap();
        assert_eq!(
            folder(dir.path(), u64::MAX).save(b"a"),
            Err(SaveError::FolderFull)
        );
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            folder(dir.path(), MIN_FREE_BYTES - 1).save(b"a"),
            Err(SaveError::NoRoom)
        );
        assert!(folder(dir.path(), MIN_FREE_BYTES).can_keep().is_ok());
        assert!(std::fs::read_dir(dir.path()).unwrap().next().is_none());
    }

    #[test]
    fn the_real_free_space_reads() {
        let dir = tempfile::tempdir().unwrap();
        assert!(statvfs_free(dir.path()).unwrap() > 0);
    }
}
