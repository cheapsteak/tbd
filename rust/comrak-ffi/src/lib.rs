use std::ffi::{c_char, CStr, CString};

/// Render markdown to HTML in comrak's safe mode: raw HTML is clobbered to
/// `<!-- raw HTML omitted -->` and unsafe URL schemes are emptied.
///
/// Returns a NUL-terminated UTF-8 buffer the caller owns and must release with
/// `tbd_markdown_free`. Returns null if `input` is null or not valid UTF-8.
#[no_mangle]
pub extern "C" fn tbd_markdown_to_html(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    let src = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let mut opts = comrak::Options::default();
    opts.extension.table = true;
    opts.extension.strikethrough = true;
    opts.extension.tasklist = true;
    opts.extension.autolink = true;
    opts.extension.tagfilter = true;
    opts.extension.footnotes = true;
    opts.extension.alerts = true;
    // opts.render.unsafe_ is left false. That is the safe mode the spec
    // depends on; enabling it would require an allowlist sanitizer.
    let html = comrak::markdown_to_html(src, &opts);
    match CString::new(html) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Release a buffer returned by `tbd_markdown_to_html`.
#[no_mangle]
pub extern "C" fn tbd_markdown_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)) };
    }
}
