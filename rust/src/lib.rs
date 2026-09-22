//! Native Sassy search engines and owned results behind the C backend table.
use sassy::profiles::{Ascii, Dna, Iupac, Profile};
use sassy::{Match, Searcher, Strand};
use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::{ptr, slice};

const BACKEND_TABLE_VERSION: u32 = 1;
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
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SassyCrisprOptions {
    pub struct_size: u32,
    pub pam_length: u32,
    pub allow_pam_edits: u32,
    pub include_cigar: u32,
    pub max_n_frac: f32,
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

#[repr(C)]
pub struct SassyCBackendTable {
    pub version: u32,
    pub struct_size: u32,
    pub last_error: extern "C" fn() -> *const c_char,
    pub searcher_new: unsafe extern "C" fn(u32, u32, *mut *mut SassySearcher) -> i32,
    pub searcher_free: unsafe extern "C" fn(*mut SassySearcher),
    pub search: unsafe extern "C" fn(
        *mut SassySearcher,
        SassySlice,
        SassySlice,
        u32,
        *const SassyOptions,
        *mut *mut SassyResult,
    ) -> i32,
    pub search_many: unsafe extern "C" fn(
        *mut SassySearcher,
        *const SassySlice,
        usize,
        SassySlice,
        u32,
        *const SassyOptions,
        *mut *mut SassyResult,
    ) -> i32,
    pub crispr_search_many: unsafe extern "C" fn(
        *mut SassySearcher,
        *const SassySlice,
        usize,
        SassySlice,
        u32,
        *const SassyCrisprOptions,
        *mut *mut SassyResult,
    ) -> i32,
    pub result_view: unsafe extern "C" fn(
        *const SassyResult,
        *mut *const SassyHit,
        *mut usize,
        *mut *const u8,
        *mut usize,
    ) -> i32,
    pub result_free: unsafe extern "C" fn(*mut SassyResult),
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
        Err(_) => (
            PANIC,
            "Sassy panicked; destroy and recreate this searcher".to_owned(),
        ),
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
        1 => Dna::valid_seq(seq),
        2 => Iupac::valid_seq(seq),
        _ => false,
    };
    if !valid {
        return Err(invalid("invalid sequence alphabet: DNA/IUPAC use Sassy profile validation; ASCII requires bytes < 128"));
    }
    Ok(())
}

fn validate_options(opts: &SassyOptions) -> Result<(), Error> {
    if opts.struct_size as usize != std::mem::size_of::<SassyOptions>()
        || opts.reserved != 0
        || opts.all_endpoints > 1
        || opts.include_cigar > 1
    {
        return Err(invalid("invalid options, structure size, or flags"));
    }
    Ok(())
}

/// Borrows caller-owned inputs for one synchronous FFI call.
unsafe fn search_inputs<'a>(
    searcher: *mut SassySearcher,
    patterns: *const SassySlice,
    n_patterns: usize,
    text: SassySlice,
    k: u32,
    opts: &SassyOptions,
) -> Result<(&'a mut SassySearcher, &'a [SassySlice], &'a [u8]), Error> {
    validate_options(opts)?;
    if searcher.is_null() || (n_patterns != 0 && patterns.is_null()) {
        return Err(invalid("NULL searcher or pattern array"));
    }
    if n_patterns > MAX_PATTERNS {
        return Err((
            LIMIT,
            "at most 4096 patterns are supported per call".to_owned(),
        ));
    }
    let state = unsafe { &mut *searcher };
    if state.poisoned {
        return Err(invalid("searcher was poisoned by a panic; recreate it"));
    }
    let text = unsafe { bytes(text)? };
    validate_alphabet(text, state.alphabet)?;
    let patterns = if n_patterns == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(patterns, n_patterns) }
    };
    // Validate the complete panel before searching; preserve every pattern index.
    for span in patterns {
        if span.len == 0 || span.len > MAX_PATTERN_BYTES || k as usize >= span.len {
            return Err(invalid("patterns must contain 1..4096 bytes and k must be smaller than every pattern length"));
        }
        validate_alphabet(unsafe { bytes(*span)? }, state.alphabet)?;
    }
    Ok((state, patterns, text))
}

fn append_matches(
    result: &mut SassyResult,
    matches: Vec<Match>,
    pattern_idx: usize,
    opts: &SassyOptions,
) -> Result<(), Error> {
    result
        .hits
        .try_reserve(matches.len())
        .map_err(|_| (LIMIT, "could not reserve hit output".to_owned()))?;
    for m in matches {
        let offset = result.cigars.len();
        if opts.include_cigar != 0 {
            let cigar = m.cigar.to_string();
            result
                .cigars
                .try_reserve(cigar.len())
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
            strand: match m.strand {
                Strand::Fwd => 0,
                Strand::Rc => 1,
            },
            cigar_offset: offset as u64,
            cigar_length: (result.cigars.len() - offset) as u64,
        });
    }
    Ok(())
}

/// Borrowed thread-local string, valid until the next fallible FFI call on this thread.
extern "C" fn backend_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// # Safety
/// `out` must point to a writable pointer slot. Searchers are thread-confined.
unsafe extern "C" fn sassy_c_searcher_new(
    alphabet: u32,
    reverse_complement: u32,
    out: *mut *mut SassySearcher,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return Err(invalid("out searcher is NULL"));
        }
        unsafe {
            *out = ptr::null_mut();
        }
        if reverse_complement > 1 || (alphabet == 0 && reverse_complement != 0) {
            return Err(invalid(
                "invalid reverse-complement flag; ASCII requires rc=false",
            ));
        }
        let rc = reverse_complement != 0;
        let engine = match alphabet {
            0 => Engine::Ascii(Searcher::<Ascii>::new(false, None)),
            1 => Engine::Dna(Searcher::<Dna>::new(rc, None)),
            2 => Engine::Iupac(Searcher::<Iupac>::new(rc, None)),
            _ => return Err(invalid("alphabet must be ASCII=0, DNA=1, or IUPAC=2")),
        };
        unsafe {
            *out = Box::into_raw(Box::new(SassySearcher {
                engine,
                alphabet,
                poisoned: false,
            }));
        }
        Ok(())
    })
}

/// # Safety
/// `searcher` must be NULL or an owned pointer returned by `sassy_c_searcher_new`.
unsafe extern "C" fn sassy_c_searcher_free(searcher: *mut SassySearcher) {
    if !searcher.is_null() {
        unsafe {
            drop(Box::from_raw(searcher));
        }
    }
}

/// Searches a pattern panel against ONE complete text record. Input bytes are borrowed
/// only for this call. The caller owns the returned result. This deliberately does not
/// collect a relation of texts in Rust.
///
/// # Safety
/// All pointers must obey the ownership and lifetime rules in include/sassy_c.h.
unsafe extern "C" fn sassy_c_search_many(
    searcher: *mut SassySearcher,
    patterns: *const SassySlice,
    n_patterns: usize,
    text: SassySlice,
    k: u32,
    options: *const SassyOptions,
    out: *mut *mut SassyResult,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return Err(invalid("out result is NULL"));
        }
        unsafe {
            *out = ptr::null_mut();
        }
        if options.is_null() {
            return Err(invalid("options are NULL"));
        }
        let opts = unsafe { &*options };
        let (state, patterns, text) =
            unsafe { search_inputs(searcher, patterns, n_patterns, text, k, opts)? };
        let mut result = SassyResult {
            hits: Vec::new(),
            cigars: Vec::new(),
        };
        if !text.is_empty() {
            for (i, p) in patterns.iter().enumerate() {
                let pattern = unsafe { bytes(*p)? };
                // An unwinding kernel must not leave a reusable, apparently healthy searcher.
                state.poisoned = true;
                let matches = match &mut state.engine {
                    Engine::Ascii(s) => {
                        if opts.all_endpoints != 0 {
                            s.search_all(pattern, text, k as usize)
                        } else {
                            s.search(pattern, text, k as usize)
                        }
                    }
                    Engine::Dna(s) => {
                        if opts.all_endpoints != 0 {
                            s.search_all(pattern, text, k as usize)
                        } else {
                            s.search(pattern, text, k as usize)
                        }
                    }
                    Engine::Iupac(s) => {
                        if opts.all_endpoints != 0 {
                            s.search_all(pattern, text, k as usize)
                        } else {
                            s.search(pattern, text, k as usize)
                        }
                    }
                };
                state.poisoned = false;
                append_matches(&mut result, matches, i, opts)?;
            }
        }
        unsafe {
            *out = Box::into_raw(Box::new(result));
        }
        Ok(())
    })
}

/// # Safety
/// Same requirements as `sassy_c_search_many`, with one pattern span.
unsafe extern "C" fn sassy_c_search(
    searcher: *mut SassySearcher,
    pattern: SassySlice,
    text: SassySlice,
    k: u32,
    options: *const SassyOptions,
    out: *mut *mut SassyResult,
) -> i32 {
    unsafe { sassy_c_search_many(searcher, &pattern, 1, text, k, options, out) }
}

/// CRISPR endpoint and N-content filtering follows Sassy 0.2.6 bin/crispr.rs
/// (fc1d4fb222018e6e805ff83fbb0b68a9ab95c20f), by Rick Beeloo and
/// Ragnar Groot Koerkamp. See third_party/sassy/LICENSE.
///
/// # Safety
/// Inputs obey `sassy_c_search_many`'s borrowing rules. `options` and `out`
/// point to readable options and a writable result slot. The searcher is IUPAC.
unsafe extern "C" fn sassy_c_crispr_search_many(
    searcher: *mut SassySearcher,
    guides: *const SassySlice,
    guide_count: usize,
    text: SassySlice,
    k: u32,
    options: *const SassyCrisprOptions,
    out: *mut *mut SassyResult,
) -> i32 {
    guard(|| {
        if out.is_null() {
            return Err(invalid("out result is NULL"));
        }
        unsafe {
            *out = ptr::null_mut();
        }
        if options.is_null() {
            return Err(invalid("CRISPR options are NULL"));
        }
        let opts = unsafe { &*options };
        if opts.struct_size as usize != std::mem::size_of::<SassyCrisprOptions>()
            || opts.pam_length == 0
            || opts.allow_pam_edits > 1
            || !(0.0..=1.0).contains(&opts.max_n_frac)
        {
            return Err(invalid("invalid CRISPR options, PAM length, or N fraction"));
        }
        let common = SassyOptions {
            struct_size: std::mem::size_of::<SassyOptions>() as u32,
            all_endpoints: 1,
            include_cigar: opts.include_cigar,
            reserved: 0,
        };
        let (state, guides, text) =
            unsafe { search_inputs(searcher, guides, guide_count, text, k, &common)? };
        let Engine::Iupac(engine) = &mut state.engine else {
            return Err(invalid("CRISPR search requires an IUPAC searcher"));
        };
        let pam_length = opts.pam_length as usize;
        let mut pam = &[][..];
        for (index, span) in guides.iter().enumerate() {
            let guide = unsafe { bytes(*span)? };
            if pam_length > guide.len() {
                return Err(invalid("PAM length exceeds guide length"));
            }
            let suffix = &guide[guide.len() - pam_length..];
            if index == 0 {
                pam = suffix;
            } else if suffix != pam {
                return Err(invalid("guide panel must have identical PAM suffixes"));
            }
        }
        let pam_complement = Iupac::complement(pam);
        let mut result = SassyResult {
            hits: Vec::new(),
            cigars: Vec::new(),
        };
        for (index, span) in guides.iter().enumerate() {
            if text.is_empty() {
                break;
            }
            let guide = unsafe { bytes(*span)? };
            engine.set_max_n_frac(opts.max_n_frac);
            state.poisoned = true;
            let matches = if opts.allow_pam_edits != 0 {
                engine.search_all(guide, text, k as usize)
            } else {
                engine.search_with_fn(guide, text, k as usize, true, |_, prefix, strand| {
                    if prefix.len() < pam_length {
                        return false;
                    }
                    let expected = match strand {
                        Strand::Fwd => pam,
                        Strand::Rc => pam_complement.as_slice(),
                    };
                    prefix[prefix.len() - pam_length..]
                        .iter()
                        .zip(expected)
                        .all(|(&actual, &base)| Iupac::is_match(actual, base))
                })
            };
            state.poisoned = false;
            engine.set_max_n_frac(1.0);
            append_matches(&mut result, matches, index, &common)?;
        }
        unsafe {
            *out = Box::into_raw(Box::new(result));
        }
        Ok(())
    })
}

/// # Safety
/// `result` must be live; all output slots must be writable. Views die with the result.
unsafe extern "C" fn sassy_c_result_view(
    result: *const SassyResult,
    hits: *mut *const SassyHit,
    count: *mut usize,
    cigars: *mut *const u8,
    cigar_bytes: *mut usize,
) -> i32 {
    guard(|| {
        if hits.is_null() || count.is_null() || cigars.is_null() || cigar_bytes.is_null() {
            return Err(invalid("result view output slot is NULL"));
        }
        unsafe {
            *hits = ptr::null();
            *count = 0;
            *cigars = ptr::null();
            *cigar_bytes = 0;
        }
        if result.is_null() {
            return Err(invalid("result is NULL"));
        }
        let r = unsafe { &*result };
        unsafe {
            *count = r.hits.len();
            *cigar_bytes = r.cigars.len();
            if !r.hits.is_empty() {
                *hits = r.hits.as_ptr();
            }
            if !r.cigars.is_empty() {
                *cigars = r.cigars.as_ptr();
            }
        }
        Ok(())
    })
}

/// # Safety
/// `result` must be NULL or an owned pointer returned by this library. Free exactly once.
unsafe extern "C" fn sassy_c_result_free(result: *mut SassyResult) {
    if !result.is_null() {
        unsafe {
            drop(Box::from_raw(result));
        }
    }
}

static BACKEND_TABLE: SassyCBackendTable = SassyCBackendTable {
    version: BACKEND_TABLE_VERSION,
    struct_size: std::mem::size_of::<SassyCBackendTable>() as u32,
    last_error: backend_last_error,
    searcher_new: sassy_c_searcher_new,
    searcher_free: sassy_c_searcher_free,
    search: sassy_c_search,
    search_many: sassy_c_search_many,
    crispr_search_many: sassy_c_crispr_search_many,
    result_view: sassy_c_result_view,
    result_free: sassy_c_result_free,
};

#[cfg(feature = "backend-scalar")]
#[unsafe(no_mangle)]
pub extern "C" fn sassy_c_backend_scalar_get_table() -> *const SassyCBackendTable {
    &BACKEND_TABLE
}

#[cfg(feature = "backend-avx2")]
#[unsafe(no_mangle)]
pub extern "C" fn sassy_c_backend_avx2_get_table() -> *const SassyCBackendTable {
    &BACKEND_TABLE
}

#[cfg(feature = "backend-avx512")]
#[unsafe(no_mangle)]
pub extern "C" fn sassy_c_backend_avx512_get_table() -> *const SassyCBackendTable {
    &BACKEND_TABLE
}

#[cfg(feature = "backend-neon")]
#[unsafe(no_mangle)]
pub extern "C" fn sassy_c_backend_neon_get_table() -> *const SassyCBackendTable {
    &BACKEND_TABLE
}

#[cfg(test)]
mod tests {
    use super::*;
    fn span(s: &[u8]) -> SassySlice {
        SassySlice {
            data: s.as_ptr(),
            len: s.len(),
        }
    }
    fn options() -> SassyOptions {
        SassyOptions {
            struct_size: std::mem::size_of::<SassyOptions>() as u32,
            all_endpoints: 0,
            include_cigar: 1,
            reserved: 0,
        }
    }
    unsafe fn run(
        alphabet: u32,
        rc: u32,
        patterns: &[&[u8]],
        text: &[u8],
        k: u32,
        opts: SassyOptions,
    ) -> (i32, Vec<SassyHit>, Vec<u8>) {
        let mut s = ptr::null_mut();
        assert_eq!(unsafe { sassy_c_searcher_new(alphabet, rc, &mut s) }, 0);
        let p: Vec<_> = patterns.iter().map(|p| span(p)).collect();
        let mut result = ptr::null_mut();
        let code = unsafe {
            sassy_c_search_many(s, p.as_ptr(), p.len(), span(text), k, &opts, &mut result)
        };
        let snapshot = unsafe { result_snapshot(code, result) };
        unsafe {
            sassy_c_searcher_free(s);
        }
        snapshot
    }
    unsafe fn result_snapshot(
        code: i32,
        result: *mut SassyResult,
    ) -> (i32, Vec<SassyHit>, Vec<u8>) {
        let (mut hits, mut cigars) = (Vec::new(), Vec::new());
        if code == 0 {
            let (mut h, mut n, mut c, mut nc) = (ptr::null(), 0, ptr::null(), 0);
            assert_eq!(
                unsafe { sassy_c_result_view(result, &mut h, &mut n, &mut c, &mut nc) },
                0
            );
            if n != 0 {
                hits.extend_from_slice(unsafe { slice::from_raw_parts(h, n) });
            }
            if nc != 0 {
                cigars.extend_from_slice(unsafe { slice::from_raw_parts(c, nc) });
            }
        } else {
            assert!(result.is_null());
        }
        unsafe {
            sassy_c_result_free(result);
        }
        (code, hits, cigars)
    }
    fn crispr_options() -> SassyCrisprOptions {
        SassyCrisprOptions {
            struct_size: std::mem::size_of::<SassyCrisprOptions>() as u32,
            pam_length: 3,
            allow_pam_edits: 0,
            include_cigar: 1,
            max_n_frac: 0.2,
        }
    }
    fn run_crispr(
        rc: u32,
        guides: &[&[u8]],
        text: &[u8],
        k: u32,
        opts: SassyCrisprOptions,
    ) -> (i32, Vec<SassyHit>, Vec<u8>) {
        let mut searcher = ptr::null_mut();
        assert_eq!(unsafe { sassy_c_searcher_new(2, rc, &mut searcher) }, 0);
        let guides: Vec<_> = guides.iter().map(|guide| span(guide)).collect();
        let mut result = ptr::null_mut();
        let code = unsafe {
            sassy_c_crispr_search_many(
                searcher,
                guides.as_ptr(),
                guides.len(),
                span(text),
                k,
                &opts,
                &mut result,
            )
        };
        let snapshot = unsafe { result_snapshot(code, result) };
        unsafe {
            sassy_c_searcher_free(searcher);
        }
        snapshot
    }
    #[test]
    fn exact_and_panel_ids() {
        let (code, hits, cigars) =
            unsafe { run(1, 0, &[b"ACGA", b"TTGC"], b"GGACGACCCTTGC", 0, options()) };
        assert_eq!(code, 0);
        assert_eq!(hits.len(), 2);
        assert_eq!(
            (hits[0].pattern_idx, hits[0].text_start, hits[0].text_end),
            (0, 2, 6)
        );
        assert_eq!(hits[1].pattern_idx, 1);
        assert_eq!(&cigars[0..2], b"4=");
    }
    #[test]
    fn reverse_complement_coordinates() {
        let (_, hits, _) = unsafe { run(1, 1, &[b"ACGA"], b"TTTCGTTT", 0, options()) };
        assert!(hits
            .iter()
            .any(|m| (m.text_start, m.text_end, m.strand) == (2, 6, 1)));
    }
    #[test]
    fn no_hit_empty_text_and_empty_panel() {
        assert!(unsafe { run(1, 0, &[b"ACGA"], b"TTTT", 0, options()) }
            .1
            .is_empty());
        assert!(unsafe { run(1, 0, &[b"ACGA"], b"", 0, options()) }
            .1
            .is_empty());
        assert!(unsafe { run(1, 0, &[], b"ACGA", 0, options()) }
            .1
            .is_empty());
    }
    #[test]
    fn invalid_inputs_are_errors_not_panics() {
        assert_eq!(
            unsafe { run(1, 0, &[b"ACGA"], b"NNNN", 0, options()) }.0,
            INVALID
        );
        assert_eq!(
            unsafe { run(1, 0, &[b""], b"ACGA", 0, options()) }.0,
            INVALID
        );
        assert_eq!(
            unsafe { run(1, 0, &[b"ACGA"], b"ACGA", 4, options()) }.0,
            INVALID
        );
        let mut s = ptr::null_mut();
        assert_eq!(unsafe { sassy_c_searcher_new(99, 0, &mut s) }, INVALID);
        assert!(s.is_null());
        assert_eq!(unsafe { sassy_c_searcher_new(0, 1, &mut s) }, INVALID);
        assert_eq!(
            unsafe { sassy_c_searcher_new(1, 0, ptr::null_mut()) },
            INVALID
        );
    }
    #[test]
    fn iupac_and_no_cigar() {
        let mut opts = options();
        opts.include_cigar = 0;
        let (code, hits, cigar) = unsafe { run(2, 0, &[b"ACGN"], b"TTACGATT", 0, opts) };
        assert_eq!(code, 0);
        assert!(!hits.is_empty());
        assert!(cigar.is_empty());
        assert!(hits.iter().all(|h| h.cigar_length == 0));
    }
    #[test]
    fn all_endpoints_contains_more_than_local_minima() {
        let (_, normal, _) = unsafe { run(0, 0, &[b"ABC"], b"XXXABCXXX", 1, options()) };
        let mut opts = options();
        opts.all_endpoints = 1;
        let (_, all, _) = unsafe { run(0, 0, &[b"ABC"], b"XXXABCXXX", 1, opts) };
        assert_eq!(normal.len(), 1);
        assert_eq!(all.len(), 3);
    }
    #[test]
    fn soft_masked_nucleotides() {
        for alphabet in [1, 2] {
            let (code, hits, _) =
                unsafe { run(alphabet, 0, &[b"aCGa"], b"TTacGAtt", 0, options()) };
            assert_eq!(code, 0);
            assert_eq!(hits.len(), 1);
            assert_eq!((hits[0].text_start, hits[0].text_end), (2, 6));
        }
    }
    #[test]
    fn crispr_strands_and_duplicate_guides() {
        let (code, hits, cigar) = run_crispr(
            0,
            &[b"ACGTNGG", b"ACGTNGG"],
            b"ttacgtaggaa",
            0,
            crispr_options(),
        );
        assert_eq!(code, 0);
        assert_eq!(hits.len(), 2);
        assert_eq!((hits[0].pattern_idx, hits[1].pattern_idx), (0, 1));
        assert_eq!(
            (hits[0].text_start, hits[0].text_end, hits[0].strand),
            (2, 9, 0)
        );
        assert_eq!(cigar, b"7=7=");
        let (code, hits, _) = run_crispr(1, &[b"ACGTNGG"], b"TTCCTACGTAA", 0, crispr_options());
        assert_eq!(code, 0);
        assert_eq!(hits.len(), 1);
        assert_eq!(
            (hits[0].text_start, hits[0].text_end, hits[0].strand),
            (2, 9, 1)
        );
    }
    #[test]
    fn crispr_pam_and_indels() {
        let (_, hits, _) = run_crispr(0, &[b"ACGTNGG"], b"ACGTAAG", 1, crispr_options());
        assert!(hits.is_empty());
        let mut opts = crispr_options();
        opts.allow_pam_edits = 1;
        let (code, hits, _) = run_crispr(0, &[b"ACGTNGG"], b"ACGTAAG", 1, opts);
        assert_eq!(code, 0);
        assert!(hits
            .iter()
            .any(|hit| (hit.text_start, hit.text_end, hit.cost) == (0, 7, 1)));
        for text in [b"ACAGTAGG".as_slice(), b"AGTAGG".as_slice()] {
            let (code, hits, _) = run_crispr(0, &[b"ACGTNGG"], text, 1, crispr_options());
            assert_eq!(code, 0);
            assert!(hits
                .iter()
                .any(|hit| (hit.text_start, hit.text_end, hit.cost) == (0, text.len() as u64, 1)));
        }
    }
    #[test]
    fn crispr_n_fraction() {
        let mut opts = crispr_options();
        opts.max_n_frac = 0.0;
        let (code, hits, _) = run_crispr(0, &[b"ACGTNGG"], b"ACGTNGGACGTnGG", 0, opts);
        assert_eq!(code, 0);
        assert!(hits.is_empty());
        opts.max_n_frac = 1.0 / 7.0;
        assert_eq!(run_crispr(0, &[b"ACGTNGG"], b"ACGTnGG", 0, opts).1.len(), 1);
        assert_eq!(
            run_crispr(0, &[b"ACGTNGG", b"ACGTNGG"], b"ACGTAGG", 0, opts)
                .1
                .len(),
            2
        );
    }
    #[test]
    fn crispr_n_filter_does_not_leak_to_ordinary_search() {
        let mut searcher = ptr::null_mut();
        assert_eq!(unsafe { sassy_c_searcher_new(2, 0, &mut searcher) }, 0);

        let mut crispr_opts = crispr_options();
        crispr_opts.max_n_frac = 0.0;
        let guide = [span(b"ACGTNGG")];
        let mut crispr_result = ptr::null_mut();
        let crispr_code = unsafe {
            sassy_c_crispr_search_many(
                searcher,
                guide.as_ptr(),
                guide.len(),
                span(b"ACGTNGG"),
                0,
                &crispr_opts,
                &mut crispr_result,
            )
        };
        let (code, hits, _) = unsafe { result_snapshot(crispr_code, crispr_result) };
        assert_eq!(code, 0);
        assert!(hits.is_empty());

        let mut ordinary_result = ptr::null_mut();
        let ordinary_code = unsafe {
            sassy_c_search(
                searcher,
                span(b"ACGTNGG"),
                span(b"ACGTNGG"),
                0,
                &options(),
                &mut ordinary_result,
            )
        };
        let (_, hits, _) = unsafe { result_snapshot(ordinary_code, ordinary_result) };
        unsafe {
            sassy_c_searcher_free(searcher);
        }
        assert_eq!(ordinary_code, 0);
        assert_eq!(hits.len(), 1);
    }
    #[test]
    fn crispr_empty_and_short_targets() {
        assert!(run_crispr(1, &[b"ACGTNGG"], b"", 0, crispr_options())
            .1
            .is_empty());
        assert!(run_crispr(1, &[], b"ACGTAGG", 0, crispr_options())
            .1
            .is_empty());
        let (code, hits, _) = run_crispr(1, &[b"ANNN"], b"A", 3, crispr_options());
        assert_eq!(code, 0);
        assert!(hits.is_empty());
    }
    #[test]
    fn crispr_invalid_options_have_no_partial_output() {
        let mut opts = crispr_options();
        opts.pam_length = 0;
        assert_eq!(run_crispr(0, &[b"ACGTNGG"], b"ACGTAGG", 0, opts).0, INVALID);
        opts.pam_length = 8;
        assert_eq!(run_crispr(0, &[b"ACGTNGG"], b"ACGTAGG", 0, opts).0, INVALID);
        for value in [-1.0, 2.0, f32::NAN, f32::INFINITY] {
            opts = crispr_options();
            opts.max_n_frac = value;
            assert_eq!(run_crispr(0, &[b"ACGTNGG"], b"ACGTAGG", 0, opts).0, INVALID);
        }
        assert_eq!(
            run_crispr(
                0,
                &[b"ACGTNGG", b"ACGTNGA"],
                b"ACGTAGG",
                0,
                crispr_options()
            )
            .0,
            INVALID
        );
    }
    #[test]
    fn ffi_layout() {
        assert_eq!(std::mem::size_of::<SassyHit>(), 64);
        assert_eq!(std::mem::size_of::<SassyOptions>(), 16);
        assert_eq!(std::mem::size_of::<SassyCrisprOptions>(), 20);
        assert_eq!(std::mem::offset_of!(SassyCrisprOptions, max_n_frac), 16);
    }
}
