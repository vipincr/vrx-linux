// The request side of the management server: what it accepts, by the
// contract evrx-rt's docs/47-management-api.md sets for the page, and the
// one POST it allows: a software update bundle sent to /api/update (plan
// 0016 D11). Pure: bytes in, a request or the status that refuses it out.

/// Limits (the contract's).
pub const HEAD_MAX: usize = 1536;
pub const HEADER_LINES_MAX: usize = 32;
pub const TARGET_MAX: usize = 128;
/// The one path a POST may name.
pub const UPLOAD_PATH: &str = "/api/update";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Head,
    /// Only to UPLOAD_PATH, with `X-Vrx-Upload: 1` and a Content-Length.
    Post,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: Method,
    /// The path, percent-decoded once, without the query.
    pub path: String,
    pub query: String,
    pub accepts_gzip: bool,
    /// The body's length; zero for GET and HEAD, which carry none.
    pub length: u64,
}

/// A refusal: the status, and for 405 the Allow header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Refusal(pub u16);

fn decode(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Whether `host` (a Host header) names this device: an IPv4 address,
/// localhost, or `<hostname>.local`, each with or without a port. Anything
/// else is DNS rebinding's way in.
pub fn host_allowed(host: &str, hostname: &str) -> bool {
    let name = match host.rsplit_once(':') {
        Some((n, port))
            if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) =>
        {
            n
        }
        _ => host,
    };
    let name = name.to_ascii_lowercase();
    name.parse::<std::net::Ipv4Addr>().is_ok()
        || name == "localhost"
        || (!hostname.is_empty()
            && name == format!("{}.local", hostname.to_ascii_lowercase()))
}

/// A path the server may open: no empty, `.` or `..` segment, no
/// backslash, NUL or byte outside printable ASCII, no segment starting
/// with a dot or named `secret`.
pub fn path_allowed(path: &str) -> bool {
    let Some(rest) = path.strip_prefix('/') else {
        return false;
    };
    if rest.is_empty() {
        return true;
    }
    rest.split('/').enumerate().all(|(i, seg)| {
        let last = i == rest.split('/').count() - 1;
        // a trailing slash names a directory
        (seg.is_empty() && last)
            || (!seg.is_empty()
                && !seg.starts_with('.')
                && !seg.eq_ignore_ascii_case("secret")
                && seg.bytes().all(|b| (0x21..0x7f).contains(&b) && b != b'\\'))
    })
}

/// Parse the head (everything before the blank line, without it).
pub fn parse(head: &[u8], hostname: &str) -> Result<Request, Refusal> {
    if head.contains(&0) {
        return Err(Refusal(400));
    }
    let text = std::str::from_utf8(head).map_err(|_| Refusal(400))?;
    let text = text.strip_suffix("\r\n").unwrap_or(text);
    // every line ends in CRLF: a bare LF is malformed
    let lines: Vec<&str> = text.split("\r\n").collect();
    if lines.iter().any(|l| l.contains('\n') || l.contains('\r')) {
        return Err(Refusal(400));
    }
    let mut parts = lines[0].split(' ');
    let (Some(method), Some(target), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(Refusal(400));
    };
    let http11 = match version {
        "HTTP/1.1" => true,
        "HTTP/1.0" => false,
        v if v.starts_with("HTTP/") => return Err(Refusal(505)),
        _ => return Err(Refusal(400)),
    };
    if lines.len() - 1 > HEADER_LINES_MAX {
        return Err(Refusal(431));
    }
    let mut host: Option<&str> = None;
    let mut accepts_gzip = false;
    let mut lengths: Vec<&str> = Vec::new();
    let mut upload_header = false;
    for line in &lines[1..] {
        let Some((name, value)) = line.split_once(':') else {
            return Err(Refusal(400));
        };
        // white space before the colon, or a folded line
        if name.is_empty() || name.ends_with([' ', '\t']) || name.starts_with([' ', '\t'])
        {
            return Err(Refusal(400));
        }
        let value = value.trim();
        match name.to_ascii_lowercase().as_str() {
            "host" => {
                if host.replace(value).is_some() {
                    return Err(Refusal(400));
                }
            }
            "accept-encoding" => {
                accepts_gzip |= value.split(',').any(|e| {
                    let mut e = e.split(';');
                    let coding = e.next().unwrap_or("").trim();
                    let q0 = e.any(|p| p.trim().replace(' ', "") == "q=0");
                    (coding.eq_ignore_ascii_case("gzip") || coding == "*") && !q0
                });
            }
            "transfer-encoding" => return Err(Refusal(501)),
            "content-length" => lengths.push(value),
            // a header no form can send: a cross-site page's POST needs a
            // CORS preflight first, and OPTIONS is refused
            "x-vrx-upload" => upload_header = value == "1",
            _ => {}
        }
    }
    // the Host check comes before the path is looked at
    match host {
        Some(h) if !host_allowed(h, hostname) => return Err(Refusal(421)),
        None if http11 => return Err(Refusal(400)),
        _ => {}
    }
    if lengths
        .iter()
        .any(|l| l.is_empty() || !l.bytes().all(|b| b.is_ascii_digit()))
        || lengths.windows(2).any(|w| w[0] != w[1])
    {
        return Err(Refusal(400));
    }
    let method = match method {
        "GET" => Method::Get,
        "HEAD" => Method::Head,
        "POST" => Method::Post,
        "PUT" | "DELETE" | "OPTIONS" | "PATCH" | "TRACE" | "CONNECT" => {
            return Err(Refusal(405))
        }
        _ => return Err(Refusal(501)),
    };
    if target.len() > TARGET_MAX {
        return Err(Refusal(414));
    }
    if !target.starts_with('/') {
        // absolute-form, authority-form, asterisk-form
        return Err(Refusal(400));
    }
    let (raw_path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = decode(raw_path).ok_or(Refusal(404))?;
    if !path_allowed(&path) {
        return Err(Refusal(404));
    }
    let length = if method == Method::Post {
        if path != UPLOAD_PATH {
            return Err(Refusal(405));
        }
        if !upload_header {
            return Err(Refusal(403));
        }
        lengths
            .first()
            .ok_or(Refusal(411))?
            .parse()
            .map_err(|_| Refusal(413))?
    } else {
        if lengths.first().is_some_and(|l| *l != "0") {
            // GET and HEAD carry no body here
            return Err(Refusal(413));
        }
        0
    };
    Ok(Request {
        method,
        path,
        query: query.to_owned(),
        accepts_gzip,
        length,
    })
}

pub fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        411 => "Length Required",
        413 => "Content Too Large",
        414 => "URI Too Long",
        421 => "Misdirected Request",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        505 => "HTTP Version Not Supported",
        507 => "Insufficient Storage",
        _ => "Error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(head: &str) -> Result<Request, Refusal> {
        parse(head.as_bytes(), "gg")
    }

    #[test]
    fn a_plain_get_parses_with_its_query_and_gzip() {
        let r = req("GET /api/log?lines=5 HTTP/1.1\r\nHost: 10.10.10.8\r\nAccept-Encoding: br, gzip\r\n").unwrap();
        assert_eq!(r.method, Method::Get);
        assert_eq!(r.path, "/api/log");
        assert_eq!(r.query, "lines=5");
        assert!(r.accepts_gzip);
        let r =
            req("HEAD / HTTP/1.1\r\nHost: gg.local:80\r\nAccept-Encoding: gzip;q=0\r\n")
                .unwrap();
        assert_eq!(r.method, Method::Head);
        assert!(!r.accepts_gzip, "q=0 refuses gzip");
    }

    #[test]
    fn the_host_check_closes_dns_rebinding_before_the_path_is_read() {
        assert_eq!(
            req("GET /x HTTP/1.1\r\nHost: evil.example\r\n"),
            Err(Refusal(421))
        );
        assert_eq!(
            req("GET /../etc HTTP/1.1\r\nHost: evil.example\r\n"),
            Err(Refusal(421))
        );
        assert!(req("GET / HTTP/1.1\r\nHost: localhost:8080\r\n").is_ok());
        assert!(req("GET / HTTP/1.1\r\nHost: GG.LOCAL\r\n").is_ok());
        assert_eq!(
            req("GET / HTTP/1.1\r\n"),
            Err(Refusal(400)),
            "1.1 needs a Host"
        );
        assert!(
            req("GET / HTTP/1.0\r\n").is_ok(),
            "1.0 without a Host passes"
        );
        assert_eq!(
            req("GET / HTTP/1.1\r\nHost: gg.local\r\nHost: gg.local\r\n"),
            Err(Refusal(400))
        );
    }

    #[test]
    fn paths_outside_the_root_and_hidden_names_are_not_found() {
        let host = "\r\nHost: 1.2.3.4\r\n";
        for bad in [
            "/../x",
            "/a//b",
            "/a/./b",
            "/%2e%2e/x",
            "/.env",
            "/a/SECRET/b",
            "/a%5cb",
            "/a%00b",
            "/a%20b",
        ] {
            assert_eq!(
                req(&format!("GET {bad} HTTP/1.1{host}")),
                Err(Refusal(404)),
                "{bad}"
            );
        }
        assert!(req(&format!("GET /_next/static/a.js HTTP/1.1{host}")).is_ok());
        assert!(req(&format!("GET /docs/ HTTP/1.1{host}")).is_ok());
    }

    #[test]
    fn malformed_heads_are_refused_with_the_contracts_statuses() {
        let host = "Host: 1.2.3.4\r\n";
        assert_eq!(req(&format!("GET / HTTP/2.0\r\n{host}")), Err(Refusal(505)));
        assert_eq!(req(&format!("PUT / HTTP/1.1\r\n{host}")), Err(Refusal(405)));
        assert_eq!(
            req(&format!("POST / HTTP/1.1\r\n{host}")),
            Err(Refusal(405))
        );
        assert_eq!(
            req(&format!("BREW / HTTP/1.1\r\n{host}")),
            Err(Refusal(501))
        );
        assert_eq!(
            req(&format!(
                "GET / HTTP/1.1\r\n{host}Transfer-Encoding: chunked\r\n"
            )),
            Err(Refusal(501))
        );
        assert_eq!(
            req(&format!("GET http://x/ HTTP/1.1\r\n{host}")),
            Err(Refusal(400))
        );
        assert_eq!(
            req(&format!("GET /{} HTTP/1.1\r\n{host}", "a".repeat(130))),
            Err(Refusal(414))
        );
        assert_eq!(
            req("GET / HTTP/1.1\nHost: 1.2.3.4\n"),
            Err(Refusal(400)),
            "a bare LF"
        );
        assert_eq!(
            req(&format!("GET / HTTP/1.1\r\n{host}X-A : b\r\n")),
            Err(Refusal(400))
        );
        assert_eq!(
            req(&format!(
                "GET / HTTP/1.1\r\n{host}Content-Length: 1\r\nContent-Length: 2\r\n"
            )),
            Err(Refusal(400))
        );
        assert_eq!(
            req(&format!("GET / HTTP/1.1\r\n{host}Content-Length: 5\r\n")),
            Err(Refusal(413))
        );
        let many: String = (0..33).map(|i| format!("X-{i}: y\r\n")).collect();
        assert_eq!(
            req(&format!("GET / HTTP/1.1\r\n{host}{many}")),
            Err(Refusal(431))
        );
    }

    #[test]
    fn the_one_post_is_an_update_bundle_with_the_header_and_a_length() {
        let host = "Host: 10.10.10.8\r\n";
        let r = req(&format!(
            "POST /api/update HTTP/1.1\r\n{host}X-Vrx-Upload: 1\r\nContent-Length: 1048576\r\n"
        ))
        .unwrap();
        assert_eq!((r.method, r.length), (Method::Post, 1_048_576));
        assert_eq!(
            req(&format!(
                "POST /api/update HTTP/1.1\r\n{host}Content-Length: 5\r\n"
            )),
            Err(Refusal(403)),
            "a form post cannot set the header"
        );
        assert_eq!(
            req(&format!(
                "POST /api/update HTTP/1.1\r\n{host}X-Vrx-Upload: 1\r\n"
            )),
            Err(Refusal(411))
        );
        assert_eq!(
            req(&format!(
                "POST /api/log HTTP/1.1\r\n{host}X-Vrx-Upload: 1\r\nContent-Length: 5\r\n"
            )),
            Err(Refusal(405))
        );
        assert_eq!(
            req("POST /api/update HTTP/1.1\r\nHost: evil.example\r\nX-Vrx-Upload: 1\r\nContent-Length: 5\r\n"),
            Err(Refusal(421)),
            "the Host check still comes first"
        );
        assert_eq!(
            req(&format!(
                "POST /api/update HTTP/1.1\r\n{host}X-Vrx-Upload: 1\r\nContent-Length: 99999999999999999999999\r\n"
            )),
            Err(Refusal(413))
        );
        assert_eq!(
            req(&format!("OPTIONS /api/update HTTP/1.1\r\n{host}")),
            Err(Refusal(405)),
            "no preflight is ever answered"
        );
    }
}
