// `vrx camera`: the reference headless client of camerad (plan 0018 D13).
// It opens `camerad.photos` the way an applet does (a caller that is no
// applet is the system, which vrxhost lets through), asks, and writes what
// comes back: the camera list, or the JPEG that rides the response as a
// sealed memfd. It is also the bench tool for a board with no screen.
//
//   vrx camera list
//   vrx camera capture [-o FILE] [--keep] [--width N] [--camera ID]

use std::process::ExitCode;

/// The request line for `vrx camera capture`'s arguments: the JSON the
/// photos channel reads (id 1, the bytes attached, `keep` when asked).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn capture_request(args: &[String]) -> Result<serde_json::Value, String> {
    let width = match crate::flags::value(args, "--width") {
        Some(w) => Some(
            w.parse::<u32>()
                .map_err(|_| format!("--width wants a number, not {w:?}"))?,
        ),
        None => None,
    };
    Ok(serde_json::json!({
        "op": "capture",
        "id": 1,
        "camera": crate::flags::value(args, "--camera"),
        "width": width,
        "keep": crate::flags::present(args, "--keep"),
        "fd": true,
    }))
}

/// Why a response is not a photo, in the camera service's words.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn refusal(response: &serde_json::Value) -> Option<String> {
    (response["ok"] != true)
        .then(|| response["error"].as_str().unwrap_or("no answer").to_owned())
}

#[cfg(target_os = "linux")]
pub fn run(args: &[String]) -> ExitCode {
    use std::io::{Read, Write};
    use vrx::ipc::Channel;

    let usage = || {
        eprintln!("usage: vrx camera list | capture [-o FILE] [--keep] [--width N] [--camera ID]");
        ExitCode::from(64)
    };
    let Some(verb) = args.first().map(String::as_str) else {
        return usage();
    };
    let request = match verb {
        "list" => serde_json::json!({ "op": "list", "id": 1 }),
        "capture" => match capture_request(&args[1..]) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("vrx camera: {e}");
                return ExitCode::from(64);
            }
        },
        _ => return usage(),
    };
    let mut channel = match Channel::open("camerad", "photos") {
        Ok(c) => c,
        Err(e) => {
            eprintln!("vrx camera: cannot reach the camera service: {e}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(e) = channel.write(request) {
        eprintln!("vrx camera: {e}");
        return ExitCode::FAILURE;
    }
    let Some((response, fd)) = channel.next_record_with_fd() else {
        eprintln!("vrx camera: the camera service closed without answering");
        return ExitCode::FAILURE;
    };
    if let Some(why) = refusal(&response) {
        eprintln!("vrx camera: {why}");
        return ExitCode::FAILURE;
    }
    if verb == "list" {
        println!("{}", response["cameras"]);
        return ExitCode::SUCCESS;
    }
    let Some(fd) = fd else {
        eprintln!("vrx camera: the answer carried no picture");
        return ExitCode::FAILURE;
    };
    let mut bytes = Vec::new();
    if let Err(e) = std::fs::File::from(fd).read_to_end(&mut bytes) {
        eprintln!("vrx camera: reading the picture: {e}");
        return ExitCode::FAILURE;
    }
    let out = crate::flags::value(&args[1..], "-o").unwrap_or("capture.jpg");
    if let Err(e) = std::fs::File::create(out).and_then(|mut f| f.write_all(&bytes)) {
        eprintln!("vrx camera: {out}: {e}");
        return ExitCode::FAILURE;
    }
    println!(
        "{out}: {} bytes, {}x{}{}",
        bytes.len(),
        response["width"],
        response["height"],
        response["path"]
            .as_str()
            .map(|p| format!(", kept as {p}"))
            .unwrap_or_default()
    );
    ExitCode::SUCCESS
}

#[cfg(not(target_os = "linux"))]
pub fn run(_args: &[String]) -> ExitCode {
    eprintln!("vrx camera talks to the camera service: run it on the device");
    ExitCode::from(69)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> Vec<String> {
        s.iter().map(|a| (*a).to_owned()).collect()
    }

    #[test]
    fn the_request_carries_what_was_asked_and_always_wants_the_bytes() {
        let r =
            capture_request(&args(&["-o", "x.jpg", "--keep", "--width", "640"])).unwrap();
        assert_eq!(r["op"], "capture");
        assert_eq!(r["keep"], true);
        assert_eq!(r["width"], 640);
        assert_eq!(r["fd"], true);
        assert!(r["camera"].is_null());
        let r = capture_request(&args(&["--camera", "usb0"])).unwrap();
        assert_eq!(
            (r["camera"].as_str(), r["keep"].as_bool()),
            (Some("usb0"), Some(false))
        );
        assert!(capture_request(&args(&["--width", "wide"])).is_err());
    }

    #[test]
    fn a_refusal_is_named_and_a_photo_is_not_one() {
        let no = serde_json::json!({"id":1,"ok":false,"error":"no-camera"});
        assert_eq!(refusal(&no).as_deref(), Some("no-camera"));
        let yes = serde_json::json!({"id":1,"ok":true,"bytes":3});
        assert_eq!(refusal(&yes), None);
    }
}
