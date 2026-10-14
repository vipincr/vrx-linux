// The Linux half of camerad (plan 0018 D7, D8, D12): what needs descriptors
// and processes. A photos client is a thread that reads one request, hands
// it to the engine and writes the answer, with the JPEG as a memfd sealed
// against shrink, grow and write riding on the response line. A frames
// claimant is the buffer queue of plan 0009 D10, offered once and then only
// indices. The engine sees neither: it holds a FrameSink and a reply channel.

use std::io::Write;
use std::os::fd::{AsFd, OwnedFd};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Sender};

use rustix::fs::{fcntl_add_seals, memfd_create, MemfdFlags, SealFlags};
use vrx::bufq::{BufferFormat, BufferQueue, FOURCC_XRGB8888};
use vrx::ipc::Channel;

use crate::engine::{Done, Format, FrameSink, Input, Notify};
use crate::protocol::{photo_intent, Refusal, Request, Response};

/// A JPEG as a memfd no reader can change or shrink: write it, then seal.
pub fn memfd_jpeg(jpeg: &[u8]) -> std::io::Result<OwnedFd> {
    let fd = memfd_create(
        "camerad-photo",
        MemfdFlags::CLOEXEC | MemfdFlags::ALLOW_SEALING,
    )?;
    let mut file = std::fs::File::from(fd);
    file.write_all(jpeg)?;
    let fd = OwnedFd::from(file);
    fcntl_add_seals(
        &fd,
        SealFlags::SHRINK | SealFlags::GROW | SealFlags::WRITE | SealFlags::SEAL,
    )?;
    Ok(fd)
}

fn request_id(r: &Request) -> Option<u64> {
    match r {
        Request::Capture { id, .. } => Some(*id),
        Request::List { id } | Request::Select { id, .. } => *id,
    }
}

/// Serve one `camerad.photos` client until it closes. Requests are answered
/// strictly one at a time and in order, which is the one-capture-in-flight
/// rule per client; the engine bounds how many clients there are.
pub fn serve_photos(mut photos: Channel, tx: Sender<Input>) {
    let (join_tx, join_rx) = channel();
    if tx.send(Input::Join { reply: join_tx }).is_err() {
        return;
    }
    let room = join_rx.recv().unwrap_or(false);
    while let Some(record) = photos.next_record() {
        let sent = match serde_json::from_value::<Request>(record) {
            Err(_) => write(
                &mut photos,
                &Response::refused(None, Refusal::Failed),
                None,
            ),
            Ok(request) if !room => {
                let id = request_id(&request);
                write(&mut photos, &Response::refused(id, Refusal::Busy), None)
            }
            Ok(request) => {
                let (reply, answer) = channel_pair();
                if tx.send(Input::Photos { request, reply }).is_err() {
                    break;
                }
                match answer.recv() {
                    Ok(Done { response, jpeg }) => write(&mut photos, &response, jpeg),
                    Err(_) => break,
                }
            }
        };
        if let Err(why) = sent {
            crate::log(&format!("photos client: {why}"));
            break;
        }
    }
    if room {
        let _ = tx.send(Input::Leave);
    }
}

fn channel_pair() -> (Sender<Done>, std::sync::mpsc::Receiver<Done>) {
    channel()
}

fn write(
    channel: &mut Channel,
    response: &Response,
    jpeg: Option<Vec<u8>>,
) -> Result<(), String> {
    let record = serde_json::to_value(response).map_err(|e| e.to_string())?;
    match jpeg {
        Some(bytes) => {
            let fd = memfd_jpeg(&bytes).map_err(|e| e.to_string())?;
            channel
                .write_with_fd(record, fd.as_fd())
                .map_err(|e| e.to_string())
        }
        None => channel.write(record).map_err(|e| e.to_string()),
    }
}

/// The frames claimant: a channel until the engine offers, a queue after.
pub struct QueueSink {
    channel: Option<Channel>,
    queue: Option<BufferQueue>,
    size: u64,
}

impl QueueSink {
    pub fn new(channel: Channel) -> Self {
        Self {
            channel: Some(channel),
            queue: None,
            size: 0,
        }
    }

    /// After the offer: a thread hears what the consumer gives back and
    /// when it closes, and tells the engine.
    fn listen(&self, notify: Notify) -> Result<(), String> {
        let queue = self.queue.as_ref().ok_or("no queue")?;
        let mut reclaimer = queue.reclaimer().map_err(|e| e.to_string())?;
        std::thread::spawn(move || {
            while let Some(slot) = reclaimer.next_returned() {
                if notify
                    .tx
                    .send(Input::Returned {
                        claim: notify.claim,
                        slot,
                    })
                    .is_err()
                {
                    return;
                }
            }
            let _ = notify.tx.send(Input::ViewerGone {
                claim: notify.claim,
            });
        });
        Ok(())
    }
}

fn wire_format(f: Format) -> BufferFormat {
    BufferFormat {
        fourcc: FOURCC_XRGB8888,
        width: f.width,
        height: f.height,
        stride: f.stride,
        modifier: 0,
    }
}

impl FrameSink for QueueSink {
    fn refuse(mut self: Box<Self>, why: Refusal) {
        if let Some(mut channel) = self.channel.take() {
            let _ =
                channel.write_bare_line(&serde_json::json!({ "error": why.as_str() }));
        }
    }

    fn offer_copy(
        &mut self,
        count: u32,
        size: u64,
        format: Format,
        notify: Notify,
    ) -> Result<(), String> {
        let channel = self.channel.take().ok_or("already offered")?;
        let queue =
            BufferQueue::offer_format(channel, count, size, Some(wire_format(format)))
                .map_err(|e| e.to_string())?;
        self.size = size;
        self.queue = Some(queue);
        self.listen(notify)
    }

    fn offer_dmabufs(
        &mut self,
        fds: Vec<OwnedFd>,
        size: u64,
        format: Format,
        notify: Notify,
    ) -> Result<(), String> {
        let channel = self.channel.take().ok_or("already offered")?;
        let queue =
            BufferQueue::offer_dmabufs(channel, fds, size, Some(wire_format(format)))
                .map_err(|e| e.to_string())?;
        self.size = size;
        self.queue = Some(queue);
        self.listen(notify)
    }

    fn take_free(&mut self) -> Option<u32> {
        self.queue.as_mut()?.take_free()
    }

    fn write_slot(&mut self, slot: u32, pixels: &[u8]) -> Result<(), String> {
        let queue = self.queue.as_ref().ok_or("no queue")?;
        let fd = queue.buffer(slot).ok_or("no such buffer")?;
        let mut done = 0;
        while done < pixels.len() {
            let n = rustix::io::pwrite(fd, &pixels[done..], done as u64)
                .map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("short write".into());
            }
            done += n;
        }
        Ok(())
    }

    fn queue(&mut self, slot: u32, bytes: u64) -> Result<(), String> {
        let size = self.size;
        let queue = self.queue.as_mut().ok_or("no queue")?;
        let bytes = if bytes == 0 { size } else { bytes };
        queue
            .queue(slot, bytes)
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    fn push_free(&mut self, slot: u32) {
        if let Some(queue) = self.queue.as_mut() {
            queue.push_free(slot);
        }
    }
}

/// A logind sleep inhibitor held while a capture is in flight (plan 0018
/// D12): `systemd-inhibit` running `cat`, which ends when its stdin closes.
/// Best effort: no logind, no hold, and the capture goes on.
pub fn inhibit() -> Option<Box<dyn Send>> {
    let child = Command::new("systemd-inhibit")
        .args([
            "--what=sleep",
            "--who=camerad",
            "--why=taking a photo",
            "--mode=block",
            "cat",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    Some(Box::new(Hold(child)))
}

struct Hold(Child);

impl Drop for Hold {
    fn drop(&mut self) {
        drop(self.0.stdin.take());
        let _ = self.0.wait();
    }
}

/// `sys.camera.photo` for a stored photo.
pub fn announce(name: &str) {
    if let Err(e) = vrx::ipc::intent_send("sys.camera.photo", photo_intent(name)) {
        crate::log(&format!("sys.camera.photo: {e}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::unix::net::UnixStream;

    #[test]
    fn a_photo_memfd_is_sealed_against_every_change() {
        let fd = memfd_jpeg(&[0xff, 0xd8, 1, 2, 0xff, 0xd9]).unwrap();
        let seals = rustix::fs::fcntl_get_seals(&fd).unwrap();
        for s in [SealFlags::SHRINK, SealFlags::GROW, SealFlags::WRITE] {
            assert!(seals.contains(s));
        }
        let mut text = Vec::new();
        std::fs::File::from(fd)
            .read_to_end(&mut text)
            .unwrap_or_default();
    }

    #[test]
    fn a_client_is_served_in_order_and_a_fifth_is_told_busy() {
        // an engine stand-in that admits two clients and answers every
        // capture with a photo carrying the request's id
        let (tx, rx) = channel::<Input>();
        let engine = std::thread::spawn(move || {
            let mut joined = 0;
            while let Ok(input) = rx.recv() {
                match input {
                    Input::Join { reply } => {
                        joined += 1;
                        let _ = reply.send(joined <= 1);
                    }
                    Input::Photos { request, reply } => {
                        let id = request_id(&request).unwrap_or(0);
                        let _ = reply.send(Done {
                            response: Response::photo(id, 3, 2, 2, None),
                            jpeg: Some(vec![0xff, 0xd8, 0xff, 0xd9]),
                        });
                    }
                    Input::Leave => {}
                    _ => {}
                }
            }
        });
        let pair = || {
            let (a, b) = UnixStream::pair().unwrap();
            (
                Channel::from_stream("camerad.photos".into(), a).unwrap(),
                Channel::from_stream("camerad.photos".into(), b).unwrap(),
            )
        };
        let (server, mut client) = pair();
        let t = tx.clone();
        let serving = std::thread::spawn(move || serve_photos(server, t));
        client
            .write(serde_json::json!({"op":"capture","id":1}))
            .unwrap();
        client
            .write(serde_json::json!({"op":"capture","id":2,"fd":false}))
            .unwrap();
        let (first, fd) = client.next_record_with_fd().unwrap();
        assert_eq!(first["id"], 1);
        assert!(fd.is_some(), "the JPEG rides as a memfd");
        let (second, _) = client.next_record_with_fd().unwrap();
        assert_eq!(second["id"], 2, "answered in order");
        // a second client gets no room: every request is busy
        let (server2, mut client2) = pair();
        let t = tx.clone();
        let serving2 = std::thread::spawn(move || serve_photos(server2, t));
        client2
            .write(serde_json::json!({"op":"capture","id":9}))
            .unwrap();
        let (busy, fd) = client2.next_record_with_fd().unwrap();
        assert_eq!(
            (busy["ok"].as_bool(), busy["error"].as_str()),
            (Some(false), Some("busy"))
        );
        assert!(fd.is_none());
        // garbage is `failed`, not a hang
        client2
            .write(serde_json::json!({"op":"selfdestruct"}))
            .unwrap();
        let (bad, _) = client2.next_record_with_fd().unwrap();
        assert_eq!(bad["error"], "failed");
        drop(client);
        drop(client2);
        serving.join().unwrap();
        serving2.join().unwrap();
        drop(tx);
        engine.join().unwrap();
    }
}
