// A buffer queue between two applets (plan 0009 D10): N buffers handed
// over a channel once, then only which buffer moved (vrx_protocol::bufq
// has the wire). The buffers are memfds sealed against shrinking, so the
// consumer's mapping cannot lose its pages; a producer whose data comes from
// a driver (V4L2's EXPBUF, a DRM buffer) hands those dmabufs instead. The
// SDK never maps a buffer: an applet hands the descriptor to the kernel
// interface that takes one, or maps it with the crate it chooses.

#![cfg(target_os = "linux")]

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, IoSlice, IoSliceMut, Write};
use std::mem::MaybeUninit;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::net::UnixStream;

use rustix::fs::{fcntl_add_seals, ftruncate, memfd_create, MemfdFlags, SealFlags};
use rustix::net::{
    recvmsg, sendmsg, RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags,
    SendAncillaryBuffer, SendAncillaryMessage, SendFlags,
};
use vrx_protocol::bufq::{BufferFilled, BufferOffer, BufferReturned, MAX_BUFFERS};
pub use vrx_protocol::bufq::{BufferFormat, FOURCC_XRGB8888};

use crate::ipc::{Channel, IpcError};

fn io(channel: &str) -> impl Fn(std::io::Error) -> IpcError + '_ {
    move |source| IpcError::Channel {
        channel: channel.to_owned(),
        source,
    }
}

/// One side of a queue.
pub struct BufferQueue {
    name: String,
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    buffers: Vec<OwnedFd>,
    count: u32,
    size: u64,
    format: Option<BufferFormat>,
    /// producer: the buffers not with the consumer
    free: VecDeque<u32>,
    sequence: u64,
    dropped: u64,
}

impl BufferQueue {
    /// Producer: make `count` buffers of `size` bytes and hand them to the
    /// other end of `channel`, a fresh one with nothing read from it yet.
    pub fn offer(channel: Channel, count: u32, size: u64) -> Result<Self, IpcError> {
        Self::offer_format(channel, count, size, None)
    }

    /// [Self::offer] for a queue of pictures: the offer also says what a
    /// picture in a buffer looks like.
    pub fn offer_format(
        channel: Channel,
        count: u32,
        size: u64,
        format: Option<BufferFormat>,
    ) -> Result<Self, IpcError> {
        let name = channel.name().to_owned();
        if count == 0 || count > MAX_BUFFERS {
            return Err(IpcError::BadAnswer(format!(
                "a queue holds 1 to {MAX_BUFFERS} buffers, not {count}"
            )));
        }
        let mut buffers = Vec::new();
        for i in 0..count {
            let fd = memfd_create(
                format!("vrx-bufq-{i}"),
                MemfdFlags::CLOEXEC | MemfdFlags::ALLOW_SEALING,
            )
            .map_err(|e| io(&name)(e.into()))?;
            ftruncate(&fd, size).map_err(|e| io(&name)(e.into()))?;
            // the consumer maps it: it may not shrink, or grow, under them
            fcntl_add_seals(&fd, SealFlags::SHRINK | SealFlags::GROW | SealFlags::SEAL)
                .map_err(|e| io(&name)(e.into()))?;
            buffers.push(fd);
        }
        Self::send_offer(channel, buffers, size, format)
    }

    /// Producer: hand a driver's own buffers over `channel` instead of
    /// memfds (libcamera's frame buffers, a DRM buffer): `buffers` are
    /// dmabufs of `size` bytes each, `format` says what a picture in one
    /// looks like. The producer vouches that each is a dmabuf (or a memfd
    /// sealed against shrinking, plan 0009 D10): the offer rides the
    /// channel's own socket, so vrxhost never sees these descriptors.
    pub fn offer_dmabufs(
        channel: Channel,
        buffers: Vec<OwnedFd>,
        size: u64,
        format: Option<BufferFormat>,
    ) -> Result<Self, IpcError> {
        let count = u32::try_from(buffers.len()).unwrap_or(u32::MAX);
        if count == 0 || count > MAX_BUFFERS {
            return Err(IpcError::BadAnswer(format!(
                "a queue holds 1 to {MAX_BUFFERS} buffers, not {}",
                buffers.len()
            )));
        }
        if let Some(f) = format {
            let needed = u64::from(f.stride) * u64::from(f.height);
            if f.width == 0 || f.height == 0 || needed > size {
                return Err(IpcError::BadAnswer(format!(
                    "a {}x{} picture with stride {} does not fit {size} bytes",
                    f.width, f.height, f.stride
                )));
            }
        }
        Self::send_offer(channel, buffers, size, format)
    }

    fn send_offer(
        channel: Channel,
        buffers: Vec<OwnedFd>,
        size: u64,
        format: Option<BufferFormat>,
    ) -> Result<Self, IpcError> {
        let name = channel.name().to_owned();
        let count = buffers.len() as u32;
        let stream = channel.into_stream();
        let mut line = serde_json::to_vec(&BufferOffer {
            buffers: count,
            size,
            format,
        })
        .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        line.push(b'\n');
        let fds: Vec<BorrowedFd<'_>> = buffers.iter().map(AsFd::as_fd).collect();
        let mut space =
            [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(MAX_BUFFERS as usize))];
        let mut control = SendAncillaryBuffer::new(&mut space);
        control.push(SendAncillaryMessage::ScmRights(&fds));
        sendmsg(
            &stream,
            &[IoSlice::new(&line)],
            &mut control,
            SendFlags::empty(),
        )
        .map_err(|e| io(&name)(e.into()))?;
        let reader = BufReader::new(stream.try_clone().map_err(io(&name))?);
        let count = buffers.len() as u32;
        Ok(Self {
            name,
            count,
            writer: stream,
            reader,
            free: (0..count).collect(),
            buffers,
            size,
            format,
            sequence: 0,
            dropped: 0,
        })
    }

    /// Consumer: take the buffers a producer offered on `channel` (a channel
    /// delivery, nothing read from it yet).
    pub fn accept(channel: Channel) -> Result<Self, IpcError> {
        let name = channel.name().to_owned();
        let stream = channel.into_stream();
        // the offer line arrives with the descriptors; read only up to it
        let mut first = Vec::new();
        let mut buffers = Vec::new();
        loop {
            let mut byte = [0u8; 1];
            let mut space = [MaybeUninit::uninit();
                rustix::cmsg_space!(ScmRights(MAX_BUFFERS as usize))];
            let mut control = RecvAncillaryBuffer::new(&mut space);
            let got = recvmsg(
                &stream,
                &mut [IoSliceMut::new(&mut byte)],
                &mut control,
                RecvFlags::CMSG_CLOEXEC,
            )
            .map_err(|e| io(&name)(e.into()))?;
            for message in control.drain() {
                if let RecvAncillaryMessage::ScmRights(fds) = message {
                    buffers.extend(fds);
                }
            }
            if got.bytes == 0 {
                return Err(IpcError::BadAnswer(
                    "the producer closed before its offer".into(),
                ));
            }
            if byte[0] == b'\n' {
                break;
            }
            first.push(byte[0]);
        }
        let offer: BufferOffer = serde_json::from_slice(&first)
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        if buffers.len() != offer.buffers as usize {
            return Err(IpcError::BadAnswer(format!(
                "the offer names {} buffers, {} came with it",
                offer.buffers,
                buffers.len()
            )));
        }
        let reader = BufReader::new(stream.try_clone().map_err(io(&name))?);
        let count = buffers.len() as u32;
        Ok(Self {
            name,
            count,
            writer: stream,
            reader,
            buffers,
            size: offer.size,
            format: offer.format,
            free: VecDeque::new(),
            sequence: 0,
            dropped: 0,
        })
    }

    /// How many buffers, and each one's size in bytes.
    pub fn count(&self) -> usize {
        self.buffers.len()
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    /// What a picture in a buffer looks like, for a queue of pictures.
    pub fn format(&self) -> Option<BufferFormat> {
        self.format
    }

    /// Buffer `index`'s descriptor: hand it to a kernel interface, or map it.
    pub fn buffer(&self, index: u32) -> Option<BorrowedFd<'_>> {
        self.buffers.get(index as usize).map(AsFd::as_fd)
    }

    fn send(&mut self, record: &impl serde::Serialize) -> Result<(), IpcError> {
        let mut line =
            serde_json::to_vec(record).map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        line.push(b'\n');
        self.writer.write_all(&line).map_err(io(&self.name))
    }

    /// Producer: a buffer to fill, if the consumer has given one back; None
    /// is a frame to drop, which [dropped] counts.
    pub fn take_free(&mut self) -> Option<u32> {
        let index = self.free.pop_front();
        if index.is_none() {
            self.dropped += 1;
            self.sequence += 1;
        }
        index
    }

    /// Producer: buffer `index` holds `bytes`; the consumer gets it. The
    /// frame's sequence number comes back.
    pub fn queue(&mut self, index: u32, bytes: u64) -> Result<u64, IpcError> {
        self.sequence += 1;
        let sequence = self.sequence;
        self.send(&BufferFilled {
            index,
            bytes,
            sequence,
        })?;
        Ok(sequence)
    }

    /// Producer: collect a buffer the consumer gave back (blocks for one).
    pub fn reclaim(&mut self) -> Result<u32, IpcError> {
        let mut line = String::new();
        if self.reader.read_line(&mut line).map_err(io(&self.name))? == 0 {
            return Err(IpcError::BadAnswer("the consumer closed".into()));
        }
        let back: BufferReturned = serde_json::from_str(line.trim())
            .map_err(|e| IpcError::BadAnswer(e.to_string()))?;
        // CON-03 (review 2026-10-17): the peer's index is checked where
        // it ARRIVES — a returned index the queue does not have pushed a
        // slot the producer would hand out twice
        if back.index as usize >= self.count {
            return Err(IpcError::BadAnswer(format!(
                "the consumer returned buffer {}, the queue holds {}",
                back.index, self.count
            )));
        }
        self.free.push_back(back.index);
        Ok(back.index)
    }

    /// Producer: a second handle on the return path, for a thread of its
    /// own to block in while this one keeps queueing (a service that owns
    /// the queue and must not stop to wait for the consumer). Use it in
    /// place of [Self::reclaim], and hand what it returns to [Self::push_free].
    pub fn reclaimer(&self) -> Result<Reclaimer, IpcError> {
        let stream = self.writer.try_clone().map_err(io(&self.name))?;
        Ok(Reclaimer {
            name: self.name.clone(),
            reader: BufReader::new(stream),
        })
    }

    /// Producer: buffer `index` is free to fill again (a [Reclaimer] heard
    /// it come back). An index the queue does not have is refused.
    pub fn push_free(&mut self, index: u32) -> bool {
        if (index as usize) < self.buffers.len() && !self.free.contains(&index) {
            self.free.push_back(index);
            return true;
        }
        false
    }

    /// Consumer: the next filled buffer (blocks); None when the producer
    /// closed.
    pub fn next_filled(&mut self) -> Option<BufferFilled> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => serde_json::from_str(line.trim()).ok(),
        }
    }

    /// Consumer: buffer `index` is free again.
    pub fn give_back(&mut self, index: u32) -> Result<(), IpcError> {
        self.send(&BufferReturned { index })
    }

    /// Producer: frames dropped for want of a free buffer.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }
}

/// The return path of a producer's queue, readable from another thread.
pub struct Reclaimer {
    name: String,
    reader: BufReader<UnixStream>,
}

impl Reclaimer {
    /// Block for the next buffer the consumer gave back; None when it
    /// closed (or sent something that is no return record).
    pub fn next_returned(&mut self) -> Option<u32> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => serde_json::from_str::<BufferReturned>(line.trim())
                .ok()
                .map(|r| r.index),
        }
    }

    /// The channel's name, for logs.
    pub fn name(&self) -> &str {
        &self.name
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Channel, Channel) {
        let (a, b) = UnixStream::pair().unwrap();
        (
            Channel::from_stream("cam.frames".into(), a).unwrap(),
            Channel::from_stream("cam.frames".into(), b).unwrap(),
        )
    }

    #[test]
    fn buffers_go_over_once_then_only_indices_and_a_full_queue_drops() {
        let (p, c) = pair();
        let mut producer = BufferQueue::offer(p, 2, 4096).unwrap();
        let mut consumer = BufferQueue::accept(c).unwrap();
        assert_eq!((consumer.count(), consumer.size()), (2, 4096));
        // the consumer's descriptor is the same memory, sealed
        let seals = rustix::fs::fcntl_get_seals(consumer.buffer(0).unwrap()).unwrap();
        assert!(seals.contains(SealFlags::SHRINK));
        let a = producer.take_free().unwrap();
        let b = producer.take_free().unwrap();
        assert_eq!(
            producer.take_free(),
            None,
            "both are with the consumer: a frame drops"
        );
        assert_eq!(producer.dropped(), 1);
        producer.queue(a, 100).unwrap();
        let seq_b = producer.queue(b, 200).unwrap();
        let first = consumer.next_filled().unwrap();
        assert_eq!((first.index, first.bytes), (a, 100));
        let second = consumer.next_filled().unwrap();
        assert_eq!((second.index, second.sequence), (b, seq_b));
        // frame 1 was dropped (no free buffer): the consumer sees it as a gap
        assert_eq!((first.sequence, second.sequence), (2, 3));
        consumer.give_back(first.index).unwrap();
        assert_eq!(producer.reclaim().unwrap(), a);
        assert_eq!(producer.take_free(), Some(a));
    }

    #[test]
    fn driver_buffers_go_over_with_their_format_and_a_lying_format_is_refused() {
        let sealed = || {
            let fd = memfd_create("t", MemfdFlags::ALLOW_SEALING).unwrap();
            ftruncate(&fd, 4096).unwrap();
            fcntl_add_seals(&fd, SealFlags::SHRINK | SealFlags::GROW).unwrap();
            fd
        };
        let format = BufferFormat {
            fourcc: FOURCC_XRGB8888,
            width: 32,
            height: 32,
            stride: 128,
            modifier: 0,
        };
        let (p, c) = pair();
        let mut producer =
            BufferQueue::offer_dmabufs(p, vec![sealed(), sealed()], 4096, Some(format))
                .unwrap();
        let consumer = BufferQueue::accept(c).unwrap();
        assert_eq!(consumer.format(), Some(format));
        assert_eq!((consumer.count(), consumer.size()), (2, 4096));
        assert_eq!(producer.take_free(), Some(0));
        // a picture that needs more than the buffer holds
        let (p, _c) = pair();
        let too_big = BufferFormat {
            height: 64,
            ..format
        };
        assert!(
            BufferQueue::offer_dmabufs(p, vec![sealed()], 4096, Some(too_big)).is_err()
        );
        let (p, _c) = pair();
        assert!(BufferQueue::offer_dmabufs(p, Vec::new(), 4096, None).is_err());
        // memfds made by `offer` carry no format
        let (p, c) = pair();
        let _producer = BufferQueue::offer(p, 1, 64).unwrap();
        assert_eq!(BufferQueue::accept(c).unwrap().format(), None);
    }

    #[test]
    fn a_reclaimer_hears_returns_while_the_producer_keeps_queueing() {
        let (p, c) = pair();
        let mut producer = BufferQueue::offer(p, 2, 64).unwrap();
        let mut consumer = BufferQueue::accept(c).unwrap();
        let mut reclaimer = producer.reclaimer().unwrap();
        let a = producer.take_free().unwrap();
        producer.queue(a, 10).unwrap();
        let filled = consumer.next_filled().unwrap();
        consumer.give_back(filled.index).unwrap();
        let back = std::thread::spawn(move || reclaimer.next_returned())
            .join()
            .unwrap()
            .unwrap();
        assert_eq!(back, a);
        assert!(producer.push_free(back));
        assert!(!producer.push_free(back), "already free");
        assert!(!producer.push_free(9), "not a buffer of this queue");
        // `a` went to the back of the line behind the buffer never used
        assert_eq!(producer.take_free(), Some(1));
        assert_eq!(producer.take_free(), Some(a));
    }

    #[test]
    fn an_offer_that_lies_about_its_buffers_is_refused() {
        let (p, c) = pair();
        let mut stream = p.into_stream();
        stream.write_all(b"{\"buffers\":2,\"size\":64}\n").unwrap();
        assert!(BufferQueue::accept(c).is_err());
    }
}
