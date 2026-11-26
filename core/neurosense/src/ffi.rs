use std::ffi::{CStr, CString, c_char};
use std::ptr;

use crate::{MotionWindow, score_window};

/// # Safety
/// A non-null input must point to a readable, NUL-terminated UTF-8 JSON string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn neurosense_score_json_v1(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return ptr::null_mut();
    }
    std::panic::catch_unwind(|| {
        // The caller owns the input and keeps it alive until this call returns.
        let input = unsafe { CStr::from_ptr(input) };
        let window: MotionWindow = serde_json::from_slice(input.to_bytes()).ok()?;
        let payload = serde_json::to_vec(&score_window(&window)).ok()?;
        CString::new(payload).ok().map(CString::into_raw)
    })
    .ok()
    .flatten()
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// A non-null pointer must be an unchanged result of neurosense_score_json_v1.
/// Free each result once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn neurosense_free_json_v1(output: *mut c_char) {
    if !output.is_null() {
        drop(unsafe { CString::from_raw(output) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_interface_distinguishes_unusable_windows_from_invalid_json() {
        let malformed = c"{";
        assert!(unsafe { neurosense_score_json_v1(malformed.as_ptr()) }.is_null());

        let empty = c"{\"sample_rate_hz\":50,\"accel\":[],\"classifier\":\"model\"}";
        let output = unsafe { neurosense_score_json_v1(empty.as_ptr()) };
        assert!(!output.is_null());
        let response = unsafe { CStr::from_ptr(output) }.to_bytes().to_vec();
        unsafe { neurosense_free_json_v1(output) };
        let result: serde_json::Value = serde_json::from_slice(&response).unwrap();
        assert_eq!(result["status"], "insufficient_data");
        assert_eq!(result["classifier_status"], "model_unavailable");
        assert!(result["tremor_score"].is_null());
    }
}
