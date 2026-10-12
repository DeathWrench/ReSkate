//! By hand: runs a program and says how much sound came of its output.
//! cargo run --release --example decode -- <program> <argument>...
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

static FRAMES: AtomicU64 = AtomicU64::new(0);
static RATE: AtomicU64 = AtomicU64::new(0);
static DONE: AtomicBool = AtomicBool::new(false);

extern "C" fn sound(_samples: *const f32, frames: u32, rate: u32) {
    FRAMES.fetch_add(u64::from(frames), Ordering::Relaxed);
    RATE.store(u64::from(rate), Ordering::Relaxed);
}
extern "C" fn ended(stream: u64, how: *const c_char) {
    println!("stream {stream}: {}", unsafe { CStr::from_ptr(how) }.to_string_lossy());
    DONE.store(true, Ordering::Relaxed);
}

fn main() {
    let mut arguments = std::env::args().skip(1);
    let program = CString::new(arguments.next().expect("a program")).unwrap();
    let rest = CString::new(arguments.collect::<Vec<_>>().join("\n")).unwrap();
    let stream = reskate_spotify::stream::reskate_stream_play(program.as_ptr(), rest.as_ptr(), sound, ended);
    println!("began stream {stream}");
    while !DONE.load(Ordering::Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let (frames, rate) = (FRAMES.load(Ordering::Relaxed), RATE.load(Ordering::Relaxed));
    println!("{frames} frames at {rate} Hz: {:.1} s", frames as f64 / rate.max(1) as f64);
}
