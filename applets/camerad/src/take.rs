// What a photo is called and which number comes next (plan 0018 D15), the
// port of evrx-rt's camera_take.c with the same behaviour: IMG_0001.JPG to
// IMG_9999.JPG, the next one past the highest the folder already holds, so
// a drive that returns with files removed never has one overwritten and
// nothing is kept between runs.

use crate::bounds::MAX_PHOTO_NUMBER;

/// "IMG_0042.JPG" for 42; None outside 1..=9999.
pub fn name(n: u32) -> Option<String> {
    (1..=MAX_PHOTO_NUMBER)
        .contains(&n)
        .then(|| format!("IMG_{n:04}.JPG"))
}

/// The number in `file`, if it is exactly IMG_dddd.JPG with a number from 1.
pub fn parse(file: &str) -> Option<u32> {
    let digits = file.strip_prefix("IMG_")?.strip_suffix(".JPG")?;
    if digits.len() != 4 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse::<u32>().ok().filter(|n| *n >= 1)
}

/// The number after `highest` (0 for an empty folder); None when the folder
/// is full.
pub fn next(highest: u32) -> Option<u32> {
    (highest < MAX_PHOTO_NUMBER).then_some(highest + 1)
}

/// The next photo's number for a folder holding `files`.
pub fn next_in<'a>(files: impl IntoIterator<Item = &'a str>) -> Option<u32> {
    next(files.into_iter().filter_map(parse).max().unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_four_digits_and_in_range() {
        assert_eq!(name(1).as_deref(), Some("IMG_0001.JPG"));
        assert_eq!(name(9999).as_deref(), Some("IMG_9999.JPG"));
        assert_eq!(name(0), None);
        assert_eq!(name(10_000), None);
    }

    #[test]
    fn only_exactly_img_dddd_jpg_with_a_number_from_one_parses() {
        assert_eq!(parse("IMG_0042.JPG"), Some(42));
        for bad in [
            "IMG_0000.JPG",
            "IMG_42.JPG",
            "IMG_00042.JPG",
            "img_0042.jpg",
            "IMG_0042.JPEG",
            "IMG_004a.JPG",
            "IMG_0042.JPG.tmp",
            "",
        ] {
            assert_eq!(parse(bad), None, "{bad}");
        }
    }

    #[test]
    fn the_next_is_one_past_the_highest_and_a_full_folder_has_none() {
        assert_eq!(next_in([]), Some(1));
        assert_eq!(next_in(["IMG_0001.JPG", "IMG_0002.JPG"]), Some(3));
        // IMG_0007 present, lower ones gone: never reuse a lower number
        assert_eq!(next_in(["IMG_0007.JPG", "notes.txt"]), Some(8));
        assert_eq!(next_in(["IMG_9999.JPG"]), None);
        assert_eq!(next(9998), Some(9999));
        assert_eq!(next(9999), None);
    }
}
