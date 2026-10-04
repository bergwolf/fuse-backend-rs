// Copyright 2026 Alibaba Cloud. All rights reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

//! Micro-benchmarks of the fusedev request dispatch path.
//!
//! Each iteration parses a FUSE request from a buffer with
//! `Reader::from_fuse_buffer()`, dispatches it through
//! `Server::handle_message()` to a file system that does no work, and encodes
//! the reply into an in-memory `Writer`. This isolates the per-request
//! framework overhead (decoding, dispatch, reply encoding and heap
//! allocations) from the kernel, the `/dev/fuse` syscalls and real file system
//! work.
//!
//! The `read_4k_file` and `write_4k_file` cases serve the data from a real
//! (page cached) file instead, through the same vectored file IO path as the
//! fusedev transport, so that allocations in the syscall wrappers are counted
//! too. Their timings include the `pread`/`pwrite` syscall.
//!
//! Before the timings, the number of heap allocations per request is printed
//! for each operation, counted by a global allocator wrapper.
//!
//! Run with: `cargo bench --bench dispatch_microbench` from this directory
//! (Linux only).

use std::alloc::{GlobalAlloc, Layout, System};
use std::ffi::CStr;
use std::fs::File;
use std::io;
use std::mem::{size_of, ManuallyDrop};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use criterion::{criterion_group, Criterion};

use fuse_backend_rs::abi::fuse_abi::{GetattrIn, InHeader, Opcode, ReadIn, WriteIn};
use fuse_backend_rs::api::filesystem::{
    Context, Entry, FileSystem, ZeroCopyReader, ZeroCopyWriter,
};
use fuse_backend_rs::api::server::Server;
use fuse_backend_rs::file_buf::FileVolatileSlice;
use fuse_backend_rs::file_traits::FileReadWriteVolatile;
use fuse_backend_rs::transport::{FuseBuf, FuseDevReaderExt, Reader, Writer};
use vmm_sys_util::tempfile::TempFile;

const DATA_SIZE: usize = 4096;

/// Requests with this file handle are served from the real backing file.
const FILE_HANDLE: u64 = 1;

/// Global allocator counting heap allocations.
struct CountingAlloc;

static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        System.alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        System.alloc_zeroed(layout)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

/// A data source/sink that transfers bytes without touching them or making
/// syscalls, standing in for the file behind a read/write request.
struct NullFile;

impl FileReadWriteVolatile for NullFile {
    fn read_volatile(&mut self, slice: FileVolatileSlice) -> io::Result<usize> {
        Ok(slice.len())
    }

    fn write_volatile(&mut self, slice: FileVolatileSlice) -> io::Result<usize> {
        Ok(slice.len())
    }

    fn read_at_volatile(&mut self, slice: FileVolatileSlice, _offset: u64) -> io::Result<usize> {
        Ok(slice.len())
    }

    fn read_vectored_at_volatile(
        &mut self,
        bufs: &[FileVolatileSlice],
        _offset: u64,
    ) -> io::Result<usize> {
        Ok(bufs.iter().map(|b| b.len()).sum())
    }

    fn write_at_volatile(&mut self, slice: FileVolatileSlice, _offset: u64) -> io::Result<usize> {
        Ok(slice.len())
    }

    fn write_vectored_at_volatile(
        &mut self,
        bufs: &[FileVolatileSlice],
        _offset: u64,
    ) -> io::Result<usize> {
        Ok(bufs.iter().map(|b| b.len()).sum())
    }
}

/// A file system that does no work, except for requests with `FILE_HANDLE`,
/// which transfer the data from/to a real file.
struct NoopFs {
    file: File,
}

impl NoopFs {
    /// Borrow the backing file as an owned `File` without `dup()`, the same
    /// way `PassthroughFs` does on its read/write path.
    fn backing_file(&self) -> ManuallyDrop<File> {
        // Safe because the returned `File` is never dropped, so it doesn't
        // close the fd, which `self.file` keeps open.
        ManuallyDrop::new(unsafe { File::from_raw_fd(self.file.as_raw_fd()) })
    }
}

fn attr() -> libc::stat64 {
    // Safe because stat64 is plain old data.
    let mut st: libc::stat64 = unsafe { std::mem::zeroed() };
    st.st_ino = 2;
    st.st_mode = libc::S_IFREG | 0o644;
    st.st_nlink = 1;
    st.st_size = 1 << 20;
    st
}

impl FileSystem for NoopFs {
    type Inode = u64;
    type Handle = u64;

    fn lookup(&self, _ctx: &Context, _parent: u64, _name: &CStr) -> io::Result<Entry> {
        Ok(Entry {
            inode: 2,
            generation: 0,
            attr: attr(),
            attr_flags: 0,
            attr_timeout: Duration::from_secs(1),
            entry_timeout: Duration::from_secs(1),
        })
    }

    fn getattr(
        &self,
        _ctx: &Context,
        _inode: u64,
        _handle: Option<u64>,
    ) -> io::Result<(libc::stat64, Duration)> {
        Ok((attr(), Duration::from_secs(1)))
    }

    fn read(
        &self,
        _ctx: &Context,
        _inode: u64,
        handle: u64,
        w: &mut dyn ZeroCopyWriter,
        size: u32,
        offset: u64,
        _lock_owner: Option<u64>,
        _flags: u32,
    ) -> io::Result<usize> {
        if handle == FILE_HANDLE {
            w.write_from(&mut *self.backing_file(), size as usize, offset)
        } else {
            w.write_from(&mut NullFile, size as usize, offset)
        }
    }

    fn write(
        &self,
        _ctx: &Context,
        _inode: u64,
        handle: u64,
        r: &mut dyn ZeroCopyReader,
        size: u32,
        offset: u64,
        _lock_owner: Option<u64>,
        _delayed_write: bool,
        _flags: u32,
        _fuse_flags: u32,
    ) -> io::Result<usize> {
        if handle == FILE_HANDLE {
            r.read_to(&mut *self.backing_file(), size as usize, offset)
        } else {
            r.read_to(&mut NullFile, size as usize, offset)
        }
    }
}

/// A `Writer` encoding replies into a memory buffer, without sending them.
struct MemWriter<'a> {
    buf: &'a mut [u8],
    pos: usize,
}

impl io::Write for MemWriter<'_> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let len = std::cmp::min(data.len(), self.available_bytes());
        self.buf[self.pos..self.pos + len].copy_from_slice(&data[..len]);
        self.pos += len;
        Ok(len)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Writer for MemWriter<'_> {
    fn write_from_at<F: FileReadWriteVolatile>(
        &mut self,
        mut src: F,
        count: usize,
        off: u64,
    ) -> io::Result<usize> {
        let count = std::cmp::min(count, self.available_bytes());
        // Safe because the slice is within `self.buf`, which outlives it.
        let slice =
            unsafe { FileVolatileSlice::from_mut_slice(&mut self.buf[self.pos..self.pos + count]) };
        // Go through the vectored variant, like `FuseDevWriter::write_from_at()`.
        let cnt = src.read_vectored_at_volatile(std::slice::from_ref(&slice), off)?;
        self.pos += cnt;
        Ok(cnt)
    }

    fn split_at(&mut self, offset: usize) -> fuse_backend_rs::transport::Result<Self> {
        let buf = std::mem::take(&mut self.buf);
        let (head, tail) = buf.split_at_mut(self.pos + offset);
        self.buf = head;
        Ok(MemWriter { buf: tail, pos: 0 })
    }

    fn available_bytes(&self) -> usize {
        self.buf.len() - self.pos
    }

    fn bytes_written(&self) -> usize {
        self.pos
    }

    fn commit(&mut self, other: Option<&Self>) -> io::Result<usize> {
        Ok(self.pos + other.map(|w| w.pos).unwrap_or(0))
    }
}

fn as_bytes<T>(val: &T) -> &[u8] {
    // Safe because the FUSE ABI structs are plain old data.
    unsafe { std::slice::from_raw_parts(val as *const T as *const u8, size_of::<T>()) }
}

/// Build a request: the header, the opcode-specific argument and the payload.
fn request<T>(opcode: Opcode, arg: &T, payload: &[u8]) -> Vec<u8> {
    let len = size_of::<InHeader>() + size_of::<T>() + payload.len();
    let header = InHeader {
        len: len as u32,
        opcode: opcode as u32,
        unique: 1,
        nodeid: 1,
        ..Default::default()
    };
    let mut buf = Vec::with_capacity(len);
    buf.extend_from_slice(as_bytes(&header));
    buf.extend_from_slice(as_bytes(arg));
    buf.extend_from_slice(payload);
    buf
}

fn requests() -> Vec<(&'static str, Vec<u8>)> {
    let read_in = ReadIn {
        size: DATA_SIZE as u32,
        ..Default::default()
    };
    let write_in = WriteIn {
        size: DATA_SIZE as u32,
        ..Default::default()
    };
    let read_file_in = ReadIn {
        fh: FILE_HANDLE,
        ..read_in
    };
    let write_file_in = WriteIn {
        fh: FILE_HANDLE,
        ..write_in
    };
    vec![
        (
            "getattr",
            request(Opcode::Getattr, &GetattrIn::default(), &[]),
        ),
        ("lookup", request(Opcode::Lookup, &(), b"benchfile\0")),
        ("read_4k", request(Opcode::Read, &read_in, &[])),
        (
            "write_4k",
            request(Opcode::Write, &write_in, &[0xa5u8; DATA_SIZE]),
        ),
        ("read_4k_file", request(Opcode::Read, &read_file_in, &[])),
        (
            "write_4k_file",
            request(Opcode::Write, &write_file_in, &[0xa5u8; DATA_SIZE]),
        ),
    ]
}

/// Serve requests from a request buffer, encoding the replies into a buffer.
struct Dispatcher {
    server: Server<NoopFs>,
    reply: Vec<u8>,
}

impl Dispatcher {
    fn new() -> Self {
        // The temporary file is unlinked when `TempFile` is dropped, the
        // open `File` stays usable.
        let file = TempFile::new().unwrap().into_file();
        file.set_len(DATA_SIZE as u64).unwrap();
        Dispatcher {
            server: Server::new(NoopFs { file }),
            reply: vec![0u8; DATA_SIZE + 4096],
        }
    }

    fn dispatch(&mut self, req: &mut [u8]) -> usize {
        let reader = Reader::<()>::from_fuse_buffer(FuseBuf::new(req)).unwrap();
        let writer = MemWriter {
            buf: &mut self.reply,
            pos: 0,
        };
        self.server
            .handle_message(reader, writer, None, None)
            .unwrap()
    }
}

fn print_allocations() {
    const ITERATIONS: u64 = 10_000;
    let mut dispatcher = Dispatcher::new();
    println!("heap allocations per request:");
    for (name, mut req) in requests() {
        // Warm up.
        dispatcher.dispatch(&mut req);
        let before = ALLOCATIONS.load(Ordering::Relaxed);
        for _ in 0..ITERATIONS {
            dispatcher.dispatch(&mut req);
        }
        let allocs = ALLOCATIONS.load(Ordering::Relaxed) - before;
        println!("  {:<14} {:.2}", name, allocs as f64 / ITERATIONS as f64);
    }
}

fn bench_dispatch(c: &mut Criterion) {
    let mut dispatcher = Dispatcher::new();
    let mut group = c.benchmark_group("dispatch");
    for (name, mut req) in requests() {
        group.bench_function(name, |b| b.iter(|| dispatcher.dispatch(&mut req)));
    }
    group.finish();
}

criterion_group!(benches, bench_dispatch);

fn main() {
    print_allocations();
    benches();
    Criterion::default().configure_from_args().final_summary();
}
