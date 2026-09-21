//! DuckDB-independent C ABI around Sassy. No database, file I/O, or thread pool.
use sassy::profiles::{Ascii, Dna, Iupac};
use sassy::{Match, Searcher, Strand};
use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::{ptr, slice};

pub const ABI_VERSION: u32 = 1;
const MAX_PATTERNS: usize = 4096;
const MAX_PATTERN_BYTES: usize = 4096;
const INVALID: i32 = 1;
const LIMIT: i32 = 2;
const PANIC: i32 = 3;

type Error = (i32, String);
thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SassySlice {
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SassyOptions {
    pub struct_size: u32,
    pub all_endpoints: u32,
    pub include_cigar: u32,
    pub reserved: u32,
    pub max_hits: u64,
    pub max_text_bytes: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SassyHit {
    pub pattern_idx: u64,
    pub text_start: u64,
    pub text_end: u64,
    pub pattern_start: u64,
    pub pattern_end: u64,
    pub cost: i32,
    /// 0: forward; 1: reverse complement. Coordinates refer to the original text.
    pub strand: u32,
    pub cigar_offset: u64,
    pub cigar_length: u64,
}

enum Engine {
    Ascii(Searcher<Ascii>),
    Dna(Searcher<Dna>),
    Iupac(Searcher<Iupac>),
}

pub struct SassySearcher {
    engine: Engine,
    alphabet: u32,
    poisoned: bool,
}

pub struct SassyResult {
    hits: Vec<SassyHit>,
    cigars: Vec<u8>,
}

fn invalid(message: &str) -> Error {
    (INVALID, message.to_owned())
}

fn guard(f: impl FnOnce() -> Result<(), Error>) -> i32 {
    LAST_ERROR.with(|e| *e.borrow_mut() = CString::new("").unwrap());
    let outcome = catch_unwind(AssertUnwindSafe(f));
    let (code, message) = match outcome {
        Ok(Ok(())) => return 0,
        Ok(Err(e)) => e,
        Err(_) => (PANIC, "Sassy panicked; destroy and recreate this searcher".to_owned()),
    };
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(message.replace('\0', "\\0")).unwrap();
    });
    code
}

/// Caller must provide a live allocation containing `len` bytes for nonempty slices.
unsafe fn bytes<'a>(s: SassySlice) -> Result<&'a [u8], Error> {
    if s.len == 0 {
        return Ok(&[]);
    }
    if s.data.is_null() || s.len > isize::MAX as usize {
        return Err(invalid("invalid pointer/length pair"));
    }
    Ok(unsafe { slice::from_raw_parts(s.data, s.len) })
}

fn validate_alphabet(seq: &[u8], alphabet: u32) -> Result<(), Error> {
    let valid = match alphabet {
        0 => seq.is_ascii(),
        1 => seq.iter().all(|b| b"ACGT".contains(b)),
        2 => seq.iter().all(|b| b"ACGTRYSWKMBDHVN".contains(b)),
        _ => false,
    };
    if !valid {
        return Err(invalid("invalid sequence alphabet: DNA/IUPAC require uppercase letters; ASCII requires bytes < 128"));
    }
    Ok(())
}

fn validate_options(opts: &SassyOptions) -> Result<(), Error> {
    if opts.struct_size as usize != std::mem::size_of::<SassyOptions>()
        || opts.reserved != 0
        || opts.all_endpoints > 1
        || opts.include_cigar > 1
        || opts.max_hits == 0
        || opts.max_text_bytes == 0
    {
        return Err(invalid("invalid options, structure size, flags, or zero resource limit"));
    }
    Ok(())
}

fn append_matches(result: &mut SassyResult, matches: Vec<Match>, pattern_idx: usize, opts: &SassyOptions) -> Result<(), Error> {
    let new_len = result.hits.len().checked_add(matches.len())
        .ok_or_else(|| (LIMIT, "hit count overflow".to_owned()))?;
    if new_len as u64 > opts.max_hits {
        return Err((LIMIT, "max_hits exceeded; result is not truncated".to_owned()));
    }
    result.hits.try_reserve(matches.len())
        .map_err(|_| (LIMIT, "could not reserve hit output".to_owned()))?;
    for m in matches {
        let offset = result.cigars.len();
        if opts.include_cigar != 0 {
            let cigar = m.cigar.to_string();
            result.cigars.try_reserve(cigar.len())
                .map_err(|_| (LIMIT, "could not reserve CIGAR output".to_owned()))?;
            result.cigars.extend_from_slice(cigar.as_bytes());
        }
        result.hits.push(SassyHit {
            pattern_idx: pattern_idx as u64,
            text_start: m.text_start as u64,
            text_end: m.text_end as u64,
            pattern_start: m.pattern_start as u64,
            pattern_end: m.pattern_end as u64,
            cost: m.cost,
            strand: match m.strand { Strand::Fwd => 0, Strand::Rc => 1 },
            cigar_offset: offset as u64,
            cigar_length: (result.cigars.len() - offset) as u64,
        });
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn sassy_c_abi_version() -> u32 { ABI_VERSION }

/// Borrowed thread-local string, valid until the next fallible FFI call on this thread.
#[no_mangle]
pub extern "C" fn sassy_c_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// # Safety
/// `out` must point to a writable pointer slot. Searchers are thread-confined.
#[no_mangle]
pub unsafe extern "C" fn sassy_c_searcher_new(alphabet: u32, reverse_complement: u32, out: *mut *mut SassySearcher) -> i32 {
    guard(|| {
        if out.is_null() { return Err(invalid("out searcher is NULL")); }
        unsafe { *out = ptr::null_mut(); }
        if reverse_complement > 1 || (alphabet == 0 && reverse_complement != 0) {
            return Err(invalid("invalid reverse-complement flag; ASCII requires rc=false"));
        }
        let rc = reverse_complement != 0;
        let engine = match alphabet {
            0 => Engine::Ascii(Searcher::<Ascii>::new(false, None)),
            1 => Engine::Dna(Searcher::<Dna>::new(rc, None)),
            2 => Engine::Iupac(Searcher::<Iupac>::new(rc, None)),
            _ => return Err(invalid("alphabet must be ASCII=0, DNA=1, or IUPAC=2")),
        };
        unsafe { *out = Box::into_raw(Box::new(SassySearcher { engine, alphabet, poisoned: false })); }
        Ok(())
    })
}

/// # Safety
/// `searcher` must be NULL or an owned pointer returned by `sassy_c_searcher_new`.
#[no_mangle]
pub unsafe extern "C" fn sassy_c_searcher_free(searcher: *mut SassySearcher) {
    if !searcher.is_null() { unsafe { drop(Box::from_raw(searcher)); } }
}

/// Searches a pattern panel against ONE complete text record. Input bytes are borrowed
/// only for this call. The caller owns the returned result. This deliberately does not
/// collect a relation of texts in Rust. `max_hits` limits output, not upstream scratch.
///
/// # Safety
/// All pointers must obey the ownership and lifetime rules in include/sassy_c.h.
#[no_mangle]
pub unsafe extern "C" fn sassy_c_search_many(
    searcher: *mut SassySearcher,
    patterns: *const SassySlice,
    n_patterns: usize,
    text: SassySlice,
    k: u32,
    options: *const SassyOptions,
    out: *mut *mut SassyResult,
) -> i32 {
    guard(|| {
        if out.is_null() { return Err(invalid("out result is NULL")); }
        unsafe { *out = ptr::null_mut(); }
        if searcher.is_null() || options.is_null() {
            return Err(invalid("searcher or options is NULL"));
        }
        let opts = unsafe { &*options };
        validate_options(opts)?;
        if n_patterns > MAX_PATTERNS {
            return Err((LIMIT, "at most 4096 patterns are supported per call".to_owned()));
        }
        if n_patterns != 0 && patterns.is_null() {
            return Err(invalid("patterns is NULL with a nonzero count"));
        }
        if text.len as u64 > opts.max_text_bytes {
            return Err((LIMIT, "max_text_bytes exceeded before invoking Sassy".to_owned()));
        }
        let state = unsafe { &mut *searcher };
        if state.poisoned { return Err(invalid("searcher was poisoned by a panic; recreate it")); }
        let text = unsafe { bytes(text)? };
        validate_alphabet(text, state.alphabet)?;
        let patterns = if n_patterns == 0 { &[][..] } else {
            unsafe { slice::from_raw_parts(patterns, n_patterns) }
        };
        // Validate every pattern before doing any search; pattern IDs are never silently dropped.
        for p in patterns {
            if p.len == 0 || p.len > MAX_PATTERN_BYTES || k as usize >= p.len {
                return Err(invalid("patterns must contain 1..4096 bytes and k must be smaller than every pattern length"));
            }
            validate_alphabet(unsafe { bytes(*p)? }, state.alphabet)?;
        }
        let mut result = SassyResult { hits: Vec::new(), cigars: Vec::new() };
        if !text.is_empty() {
            for (i, p) in patterns.iter().enumerate() {
                let pattern = unsafe { bytes(*p)? };
                // An unwinding kernel must not leave a reusable, apparently healthy searcher.
                state.poisoned = true;
                let matches = match &mut state.engine {
                    Engine::Ascii(s) => if opts.all_endpoints != 0 { s.search_all(pattern, text, k as usize) } else { s.search(pattern, text, k as usize) },
                    Engine::Dna(s) => if opts.all_endpoints != 0 { s.search_all(pattern, text, k as usize) } else { s.search(pattern, text, k as usize) },
                    Engine::Iupac(s) => if opts.all_endpoints != 0 { s.search_all(pattern, text, k as usize) } else { s.search(pattern, text, k as usize) },
                };
                state.poisoned = false;
                append_matches(&mut result, matches, i, opts)?;
            }
        }
        unsafe { *out = Box::into_raw(Box::new(result)); }
        Ok(())
    })
}

/// # Safety
/// Same requirements as `sassy_c_search_many`, with one pattern span.
#[no_mangle]
pub unsafe extern "C" fn sassy_c_search(
    searcher: *mut SassySearcher, pattern: SassySlice, text: SassySlice,
    k: u32, options: *const SassyOptions, out: *mut *mut SassyResult,
) -> i32 {
    unsafe { sassy_c_search_many(searcher, &pattern, 1, text, k, options, out) }
}

/// # Safety
/// `result` must be live; all output slots must be writable. Views die with the result.
#[no_mangle]
pub unsafe extern "C" fn sassy_c_result_view(
    result: *const SassyResult, hits: *mut *const SassyHit, count: *mut usize,
    cigars: *mut *const u8, cigar_bytes: *mut usize,
) -> i32 {
    guard(|| {
        if hits.is_null() || count.is_null() || cigars.is_null() || cigar_bytes.is_null() {
            return Err(invalid("result view output slot is NULL"));
        }
        unsafe { *hits = ptr::null(); *count = 0; *cigars = ptr::null(); *cigar_bytes = 0; }
        if result.is_null() { return Err(invalid("result is NULL")); }
        let r = unsafe { &*result };
        unsafe {
            *count = r.hits.len();
            *cigar_bytes = r.cigars.len();
            if !r.hits.is_empty() { *hits = r.hits.as_ptr(); }
            if !r.cigars.is_empty() { *cigars = r.cigars.as_ptr(); }
        }
        Ok(())
    })
}

/// # Safety
/// `result` must be NULL or an owned pointer returned by this library. Free exactly once.
#[no_mangle]
pub unsafe extern "C" fn sassy_c_result_free(result: *mut SassyResult) {
    if !result.is_null() { unsafe { drop(Box::from_raw(result)); } }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn span(s: &[u8]) -> SassySlice { SassySlice { data: s.as_ptr(), len: s.len() } }
    fn options() -> SassyOptions {
        SassyOptions { struct_size: std::mem::size_of::<SassyOptions>() as u32,
            all_endpoints: 0, include_cigar: 1, reserved: 0, max_hits: 1000, max_text_bytes: 1 << 20 }
    }
    unsafe fn run(alphabet: u32, rc: u32, patterns: &[&[u8]], text: &[u8], k: u32, opts: SassyOptions) -> (i32, Vec<SassyHit>, Vec<u8>) {
        let mut s = ptr::null_mut();
        assert_eq!(unsafe { sassy_c_searcher_new(alphabet, rc, &mut s) }, 0);
        let p: Vec<_> = patterns.iter().map(|p| span(p)).collect();
        let mut result = ptr::null_mut();
        let code = unsafe { sassy_c_search_many(s, p.as_ptr(), p.len(), span(text), k, &opts, &mut result) };
        let (mut hits, mut cigars) = (Vec::new(), Vec::new());
        if code == 0 {
            let (mut h, mut n, mut c, mut nc) = (ptr::null(), 0, ptr::null(), 0);
            assert_eq!(unsafe { sassy_c_result_view(result, &mut h, &mut n, &mut c, &mut nc) }, 0);
            if n != 0 { hits.extend_from_slice(unsafe { slice::from_raw_parts(h, n) }); }
            if nc != 0 { cigars.extend_from_slice(unsafe { slice::from_raw_parts(c, nc) }); }
        } else { assert!(result.is_null()); }
        unsafe { sassy_c_result_free(result); sassy_c_searcher_free(s); }
        (code, hits, cigars)
    }
    #[test]
    fn exact_and_panel_ids() {
        let (code, hits, cigars) = unsafe { run(1, 0, &[b"ACGA", b"TTGC"], b"GGACGACCCTTGC", 0, options()) };
        assert_eq!(code, 0); assert_eq!(hits.len(), 2);
        assert_eq!((hits[0].pattern_idx, hits[0].text_start, hits[0].text_end), (0, 2, 6));
        assert_eq!(hits[1].pattern_idx, 1); assert_eq!(&cigars[0..2], b"4=");
    }
    #[test]
    fn reverse_complement_coordinates() {
        let (_, hits, _) = unsafe { run(1, 1, &[b"ACGA"], b"TTTCGTTT", 0, options()) };
        assert!(hits.iter().any(|m| (m.text_start, m.text_end, m.strand) == (2, 6, 1)));
    }
    #[test]
    fn no_hit_empty_text_and_empty_panel() {
        assert!(unsafe { run(1, 0, &[b"ACGA"], b"TTTT", 0, options()) }.1.is_empty());
        assert!(unsafe { run(1, 0, &[b"ACGA"], b"", 0, options()) }.1.is_empty());
        assert!(unsafe { run(1, 0, &[], b"ACGA", 0, options()) }.1.is_empty());
    }
    #[test]
    fn invalid_inputs_are_errors_not_panics() {
        assert_eq!(unsafe { run(1, 0, &[b"ACGA"], b"NNNN", 0, options()) }.0, INVALID);
        assert_eq!(unsafe { run(1, 0, &[b""], b"ACGA", 0, options()) }.0, INVALID);
        assert_eq!(unsafe { run(1, 0, &[b"ACGA"], b"ACGA", 4, options()) }.0, INVALID);
        let mut s = ptr::null_mut();
        assert_eq!(unsafe { sassy_c_searcher_new(99, 0, &mut s) }, INVALID);
        assert!(s.is_null());
        assert_eq!(unsafe { sassy_c_searcher_new(0, 1, &mut s) }, INVALID);
        assert_eq!(unsafe { sassy_c_searcher_new(1, 0, ptr::null_mut()) }, INVALID);
    }
    #[test]
    fn limits_fail_without_partial_results() {
        let mut opts = options(); opts.max_text_bytes = 3;
        assert_eq!(unsafe { run(1, 0, &[b"ACGA"], b"ACGA", 0, opts) }.0, LIMIT);
        opts = options(); opts.max_hits = 1; opts.all_endpoints = 1;
        assert_eq!(unsafe { run(1, 0, &[b"A"], b"AAAA", 0, opts) }.0, LIMIT);
    }
    #[test]
    fn iupac_and_no_cigar() {
        let mut opts = options(); opts.include_cigar = 0;
        let (code, hits, cigar) = unsafe { run(2, 0, &[b"ACGN"], b"TTACGATT", 0, opts) };
        assert_eq!(code, 0); assert!(!hits.is_empty()); assert!(cigar.is_empty());
        assert!(hits.iter().all(|h| h.cigar_length == 0));
    }
    #[test]
    fn all_endpoints_contains_more_than_local_minima() {
        let (_, normal, _) = unsafe { run(0, 0, &[b"ABC"], b"XXXABCXXX", 1, options()) };
        let mut opts = options(); opts.all_endpoints = 1;
        let (_, all, _) = unsafe { run(0, 0, &[b"ABC"], b"XXXABCXXX", 1, opts) };
        assert_eq!(normal.len(), 1); assert_eq!(all.len(), 3);
    }
    #[test]
    fn ffi_layout() {
        assert_eq!(std::mem::size_of::<SassyHit>(), 64);
        assert_eq!(std::mem::size_of::<SassyOptions>(), 32);
    }
}
