//! Sound that is not Spotify's: a program is run and what it writes to its output (an M4A,
//! MP3 or Ogg file, as it comes) is decoded and handed to the game. ReSkate's YouTube Music
//! runs yt-dlp this way (Extension/Music/youtube_music.cpp).

use std::ffi::{c_char, CStr, CString};
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSourceStream, ReadOnlySource};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// The sound: frames of two floats, at `rate` Hz. It returns when the game has room for more.
pub type Sound = extern "C" fn(samples: *const f32, frames: u32, rate: u32);
/// How a stream came to its end: "ended", or "failed <why>".
pub type Ended = extern "C" fn(stream: u64, how: *const c_char);

/// The stream that is wanted: one that is not it stops at its next piece of sound.
static WANTED: AtomicU64 = AtomicU64::new(0);

fn decode(source: impl Read + Send + Sync + 'static, stream: u64, sound: Sound) -> Result<(), String> {
    let media = MediaSourceStream::new(Box::new(ReadOnlySource::new(source)), Default::default());
    let probed = symphonia::default::get_probe()
        .format(&Hint::new(), media, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|error| format!("it is no sound this can read ({error})"))?;
    let mut format = probed.format;
    let track = format.tracks().iter().find(|track| track.codec_params.codec != CODEC_TYPE_NULL).ok_or("it has no sound in it")?;
    let track_id = track.id;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|error| format!("its sound is of a kind this cannot decode ({error})"))?;
    let mut stereo: Vec<f32> = Vec::new();
    let mut samples: Option<SampleBuffer<f32>> = None;
    loop {
        if WANTED.load(Ordering::Relaxed) != stream {
            return Ok(());
        }
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            // (The end of what the program wrote.)
            Err(symphonia::core::errors::Error::IoError(_)) => return Ok(()),
            Err(error) => return Err(error.to_string()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            // (A piece that cannot be decoded is passed over.)
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue,
            Err(error) => return Err(error.to_string()),
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count().max(1);
        let buffer = samples.get_or_insert_with(|| SampleBuffer::<f32>::new(decoded.capacity() as u64, spec));
        buffer.copy_interleaved_ref(decoded);
        let interleaved = buffer.samples();
        let frames = interleaved.len() / channels;
        stereo.clear();
        for frame in 0..frames {
            let left = interleaved[frame * channels];
            stereo.push(left);
            stereo.push(if channels > 1 { interleaved[frame * channels + 1] } else { left });
        }
        if frames > 0 {
            sound(stereo.as_ptr(), frames as u32, spec.rate);
        }
    }
}

fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: the game passes a string that ends in a zero and outlives the call.
    unsafe { CStr::from_ptr(pointer) }.to_str().ok().map(str::to_string)
}

/// Runs `program` with `arguments` (one to a line) and plays what it writes, in the place of
/// any stream before it. Returns the stream's number (0 when it could not be begun), which
/// `ended` is told with when it is over.
#[no_mangle]
pub extern "C" fn reskate_stream_play(program: *const c_char, arguments: *const c_char, sound: Sound, ended: Ended) -> u64 {
    let (Some(program), Some(arguments)) = (text(program), text(arguments)) else { return 0 };
    let stream = WANTED.fetch_add(1, Ordering::Relaxed) + 1;
    let begun = std::thread::Builder::new().name("ReSkate stream".to_string()).spawn(move || {
        let outcome = std::panic::catch_unwind(move || {
            let mut command = Command::new(&program);
            command.args(arguments.lines().filter(|line| !line.is_empty())).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
            }
            let mut child = command.spawn().map_err(|error| format!("{program} could not be run ({error})"))?;
            let output = child.stdout.take().ok_or("it has no output")?;
            let result = decode(output, stream, sound);
            let _ = child.kill();
            let _ = child.wait();
            result
        });
        let how = match outcome {
            Ok(Ok(())) => "ended".to_string(),
            Ok(Err(why)) => format!("failed {why}"),
            Err(_) => "failed on a fault of its own".to_string(),
        };
        if let Ok(how) = CString::new(how.replace('\0', " ")) {
            ended(stream, how.as_ptr());
        }
    });
    if begun.is_ok() {
        stream
    } else {
        0
    }
}

/// Stops the stream that is playing, if any.
#[no_mangle]
pub extern "C" fn reskate_stream_stop() {
    WANTED.fetch_add(1, Ordering::Relaxed);
}
