//! FFI to libactuon_core: the judge code the client plays with.
use std::os::raw::c_char;

#[repr(C)]
struct VerifyInput {
    chart: *const u8,
    chart_len: usize,
    replay: *const u8,
    replay_len: usize,
    format: u8,
}

#[repr(C)]
#[derive(Default, Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
pub struct Verified {
    pub ok: bool,
    pub clear: u8,
    pub gauge_type: u8,
    pub ex_score: u32,
    pub max_combo: u32,
    pub miss: u32,
    pub total_notes: u32,
    pub counts: [u32; 6],
    pub gauge_value: f32,
}

extern "C" {
    fn actuon_verify(input: *const VerifyInput, out: *mut Verified) -> i32;
    fn actuon_check_chart(data: *const u8, len: usize, format: u8) -> i32;
    fn actuon_chart_hash(
        data: *const u8,
        len: usize,
        sha256_hex: *mut c_char,
        md5_hex: *mut c_char,
    );
}

/// Re-simulates a replay. Err carries the C API's negative code.
pub fn verify(chart: &[u8], replay: &[u8], format: u8) -> Result<Verified, i32> {
    let input = VerifyInput {
        chart: chart.as_ptr(),
        chart_len: chart.len(),
        replay: replay.as_ptr(),
        replay_len: replay.len(),
        format,
    };
    let mut out = Verified::default();
    // SAFETY: the pointers outlive the call and the callee only reads through them.
    let rc = unsafe { actuon_verify(&input, &mut out) };
    if rc == 0 {
        Ok(out)
    } else {
        Err(rc)
    }
}

/// Whether a file parses as a chart with notes to play. Err carries the C API's negative code.
pub fn check_chart(chart: &[u8], format: u8) -> Result<(), i32> {
    // SAFETY: the pointer outlives the call and the callee only reads through it.
    let rc = unsafe { actuon_check_chart(chart.as_ptr(), chart.len(), format) };
    if rc == 0 {
        Ok(())
    } else {
        Err(rc)
    }
}

pub fn chart_sha256(data: &[u8]) -> String {
    let mut sha = [0u8; 64];
    let mut md5 = [0u8; 32];
    // SAFETY: both buffers have the sizes the C API documents.
    unsafe {
        actuon_chart_hash(
            data.as_ptr(),
            data.len(),
            sha.as_mut_ptr().cast(),
            md5.as_mut_ptr().cast(),
        )
    };
    String::from_utf8_lossy(&sha).into_owned()
}
