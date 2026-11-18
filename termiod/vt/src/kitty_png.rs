//! The PNG decoder for Kitty graphics (`f=100`).
//!
//! libghostty-vt decodes no PNG itself; it calls a process-wide hook. The
//! decoded size decides how many cells the image covers and so where the
//! cursor lands after it, so a `vt_stream` client must accept the same PNGs
//! with the same sizes, or its screen drifts from this one. Two libraries can
//! never be lenient about the same damage, so neither decides: [`header`]
//! does, and the Mac client's `TermiodStreamTerminal.pngHeader` is the same
//! walk written in Swift. A PNG that passes it is accepted at its header
//! size; if the library then cannot decode the pixels, the image is stored
//! as zeros at that size, on both ends.
//!
//! The hook is installed through the raw `ghostty_sys_set`, once per process,
//! so the decoder sees the bytes and the size limits exactly as termiod checks
//! them, on whichever thread the terminal is written.

use std::io::Cursor;
use std::sync::Once;

use libghostty_vt::ffi;
use png::{ColorType, Decoder, Limits, Transformations};

/// The largest decoded image accepted, in RGBA bytes: the engine's default
/// Kitty storage limit, so no image this refuses would have fitted anyway.
pub const DECODED_LIMIT: usize = 10_000_000;

const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

static INSTALL: Once = Once::new();

pub(crate) fn install() {
    INSTALL.call_once(|| {
        let hook: ffi::SysDecodePngFn = Some(decode);
        let pointer = hook.map_or(std::ptr::null(), |function| function as *const std::ffi::c_void);
        // SAFETY: the option takes a function pointer with this signature.
        let result = unsafe { ffi::ghostty_sys_set(ffi::SysOption::DECODE_PNG, pointer) };
        if result != ffi::Result::SUCCESS {
            eprintln!("termiod-vt: PNG decoder not installed ({result})");
        }
    });
}

/// The size a PNG is accepted at, or `None` when it is refused: the
/// signature, then IHDR first with 13 bytes, then every chunk whole with a
/// matching CRC, up to an IEND with no body. Bytes after IEND are ignored.
/// Neither dimension may be 0 or past 2^31 - 1, and the decoded RGBA may not
/// pass [`DECODED_LIMIT`].
pub(crate) fn header(data: &[u8]) -> Option<(u32, u32)> {
    let mut rest = data.strip_prefix(&SIGNATURE)?;
    let mut size = None;
    loop {
        let length = u32::from_be_bytes(rest.get(..4)?.try_into().ok()?) as usize;
        let kind = rest.get(4..8)?;
        let body = rest.get(8..8 + length)?;
        let stored = u32::from_be_bytes(rest.get(8 + length..12 + length)?.try_into().ok()?);
        if crc32fast::hash(&rest[4..8 + length]) != stored {
            return None;
        }
        match (size, kind) {
            (None, b"IHDR") if length == 13 => {
                let width = u32::from_be_bytes(body[..4].try_into().ok()?);
                let height = u32::from_be_bytes(body[4..8].try_into().ok()?);
                if width == 0 || height == 0 || width > i32::MAX as u32 || height > i32::MAX as u32 {
                    return None;
                }
                let bytes = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
                if bytes > DECODED_LIMIT {
                    return None;
                }
                size = Some((width, height));
            }
            (None, _) => return None,
            (Some(_), b"IEND") => return (length == 0).then_some(size?),
            (Some(_), _) => {}
        }
        rest = &rest[12 + length..];
    }
}

/// RGBA pixels at the size [`header`] accepted.
pub(crate) fn rgba(data: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let (width, height) = header(data)?;
    let length = width as usize * height as usize * 4;
    let pixels = pixels(data, width, height).unwrap_or_else(|| vec![0; length]);
    Some((width, height, pixels))
}

fn pixels(data: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    let mut decoder = Decoder::new_with_limits(Cursor::new(data), Limits { bytes: DECODED_LIMIT * 2 });
    decoder.set_transformations(Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buffer).ok()?;
    if (frame.width, frame.height) != (width, height) {
        return None;
    }
    let channels = match frame.color_type {
        ColorType::Grayscale => 1,
        ColorType::GrayscaleAlpha => 2,
        ColorType::Rgb => 3,
        ColorType::Rgba => 4,
        ColorType::Indexed => return None,
    };
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for pixel in buffer[..frame.buffer_size()].chunks_exact(channels) {
        match *pixel {
            [gray] => rgba.extend_from_slice(&[gray, gray, gray, 255]),
            [gray, alpha] => rgba.extend_from_slice(&[gray, gray, gray, alpha]),
            [red, green, blue] => rgba.extend_from_slice(&[red, green, blue, 255]),
            [red, green, blue, alpha] => rgba.extend_from_slice(&[red, green, blue, alpha]),
            _ => return None,
        }
    }
    (rgba.len() == width as usize * height as usize * 4).then_some(rgba)
}

unsafe extern "C" fn decode(
    _userdata: *mut std::ffi::c_void,
    allocator: *const ffi::Allocator,
    data: *const u8,
    data_len: usize,
    out: *mut ffi::SysImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: the engine passes `data_len` readable bytes at `data`.
    let data = unsafe { std::slice::from_raw_parts(data, data_len) };
    let Some((width, height, rgba)) = rgba(data) else {
        return false;
    };
    // SAFETY: the engine owns this buffer once we return true, and frees it
    // with the same allocator.
    let buffer = unsafe { ffi::ghostty_alloc(allocator, rgba.len()) };
    if buffer.is_null() {
        return false;
    }
    // SAFETY: `buffer` holds `rgba.len()` bytes and `out` is the engine's.
    unsafe {
        std::ptr::copy_nonoverlapping(rgba.as_ptr(), buffer, rgba.len());
        *out = ffi::SysImage {
            width,
            height,
            data: buffer,
            data_len: rgba.len(),
        };
    }
    true
}
