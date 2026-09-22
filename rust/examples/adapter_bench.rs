//! Compare direct Sassy calls with the Rust C ABI backend on identical resident inputs.
use sassy::profiles::{Ascii, Dna};
use sassy::{Searcher, Strand};
use sassy_c::{SassyCBackendTable, SassyHit, SassyOptions, SassySearcher, SassySlice};
use std::error::Error;
use std::ffi::CStr;
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::ptr;
use std::time::Instant;

struct Input {
    pattern: Vec<u8>,
    text: Vec<u8>,
}

#[derive(Debug, Default, PartialEq)]
struct Summary {
    hits: usize,
    cost: i64,
    cigar_bytes: usize,
}

enum Engine {
    Dna(Searcher<Dna>),
    Ascii(Searcher<Ascii>),
    Backend {
        table: &'static SassyCBackendTable,
        searcher: *mut SassySearcher,
    },
}

fn span(bytes: &[u8]) -> SassySlice {
    SassySlice { data: bytes.as_ptr(), len: bytes.len() }
}

fn check_status(table: &SassyCBackendTable, status: i32) -> Result<(), Box<dyn Error>> {
    if status == 0 {
        return Ok(());
    }
    let message = unsafe { CStr::from_ptr((table.last_error)()) };
    Err(message.to_string_lossy().into_owned().into())
}

fn record_hit(
    row: usize,
    hit: &SassyHit,
    cigar: &[u8],
    summary: &mut Summary,
    output: &mut Option<BufWriter<File>>,
) -> Result<(), Box<dyn Error>> {
    summary.hits += 1;
    summary.cost += i64::from(hit.cost);
    summary.cigar_bytes += cigar.len();
    if let Some(writer) = output {
        writeln!(writer, "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                 row, hit.pattern_idx, hit.text_start, hit.text_end,
                 hit.pattern_start, hit.pattern_end, hit.cost,
                 if hit.strand == 0 { "+" } else { "-" }, std::str::from_utf8(cigar)?)?;
    }
    Ok(())
}

impl Engine {
    fn new(mode: &str, alphabet: &str) -> Result<Self, Box<dyn Error>> {
        if mode == "upstream" {
            return Ok(match alphabet {
                "dna" => Self::Dna(Searcher::new(true, None)),
                "ascii" => Self::Ascii(Searcher::new(false, None)),
                _ => return Err("alphabet must be dna or ascii".into()),
            });
        }
        if mode != "ffi" {
            return Err("mode must be upstream or ffi".into());
        }
        #[cfg(feature = "backend-avx2")]
        let table = unsafe { &*sassy_c::sassy_c_backend_avx2_get_table() };
        #[cfg(not(feature = "backend-avx2"))]
        let table = unsafe { &*sassy_c::sassy_c_backend_scalar_get_table() };
        let (profile, rc) = match alphabet {
            "dna" => (1, 1),
            "ascii" => (0, 0),
            _ => return Err("alphabet must be dna or ascii".into()),
        };
        let mut searcher = ptr::null_mut();
        check_status(table, unsafe { (table.searcher_new)(profile, rc, &mut searcher) })?;
        Ok(Self::Backend { table, searcher })
    }

    fn run(
        &mut self,
        inputs: &[Input],
        k: u32,
        output: &mut Option<BufWriter<File>>,
    ) -> Result<Summary, Box<dyn Error>> {
        let mut summary = Summary::default();
        let options = SassyOptions {
            struct_size: std::mem::size_of::<SassyOptions>() as u32,
            all_endpoints: 0,
            include_cigar: 1,
            reserved: 0,
        };
        for (row, input) in inputs.iter().enumerate() {
            if let Self::Backend { table, searcher } = self {
                let mut result = ptr::null_mut();
                check_status(table, unsafe {
                    (table.search)(*searcher, span(&input.pattern), span(&input.text),
                                   k, &options, &mut result)
                })?;
                let (mut hits, mut count, mut cigars, mut cigar_bytes) =
                    (ptr::null(), 0, ptr::null(), 0);
                let status = unsafe {
                    (table.result_view)(result, &mut hits, &mut count, &mut cigars, &mut cigar_bytes)
                };
                let consumed = (|| {
                    check_status(table, status)?;
                    for index in 0..count {
                        let hit = unsafe { &*hits.add(index) };
                        let start = hit.cigar_offset as usize;
                        let length = hit.cigar_length as usize;
                        if start > cigar_bytes || length > cigar_bytes - start {
                            return Err("CIGAR outside result buffer".into());
                        }
                        let cigar = if length == 0 { &[] } else {
                            unsafe { std::slice::from_raw_parts(cigars.add(start), length) }
                        };
                        record_hit(row, hit, cigar, &mut summary, output)?;
                    }
                    Ok::<(), Box<dyn Error>>(())
                })();
                unsafe { (table.result_free)(result) };
                consumed?;
                continue;
            }
            let matches = match self {
                Self::Dna(searcher) => searcher.search(&input.pattern, &input.text[..], k as usize),
                Self::Ascii(searcher) => searcher.search(&input.pattern, &input.text[..], k as usize),
                Self::Backend { .. } => unreachable!(),
            };
            for matched in matches {
                let cigar = matched.cigar.to_string();
                let hit = SassyHit {
                    pattern_idx: 0,
                    text_start: matched.text_start as u64,
                    text_end: matched.text_end as u64,
                    pattern_start: matched.pattern_start as u64,
                    pattern_end: matched.pattern_end as u64,
                    cost: matched.cost,
                    strand: u32::from(matched.strand == Strand::Rc),
                    cigar_offset: 0,
                    cigar_length: cigar.len() as u64,
                };
                record_hit(row, &hit, cigar.as_bytes(), &mut summary, output)?;
            }
        }
        Ok(summary)
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        if let Self::Backend { table, searcher } = self {
            unsafe { (table.searcher_free)(*searcher) };
        }
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 7 {
        return Err("usage: adapter_bench INPUT.tsv dna|ascii upstream|ffi K REPETITIONS HITS.tsv".into());
    }
    let mut inputs = Vec::new();
    for line in BufReader::new(File::open(&args[1])?).lines() {
        let line = line?;
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() != 3 || fields[0].parse::<usize>()? != inputs.len() {
            return Err("expected consecutive row_id, pattern, text columns".into());
        }
        inputs.push(Input { pattern: fields[1].as_bytes().to_vec(), text: fields[2].as_bytes().to_vec() });
    }
    let k = args[4].parse()?;
    let repetitions = args[5].parse::<usize>()?;
    let mut engine = Engine::new(&args[3], &args[2])?;
    let mut output = Some(BufWriter::new(File::create(&args[6])?));
    writeln!(output.as_mut().unwrap(), "row_id\tpattern_idx\ttext_start\ttext_end\tpattern_start\tpattern_end\tcost\tstrand\tcigar")?;
    let expected = engine.run(&inputs, k, &mut output)?;
    output.as_mut().unwrap().flush()?;
    output = None;
    println!("iteration\telapsed_seconds\thits\tcost_sum\tcigar_bytes");
    for iteration in 1..=repetitions {
        let start = Instant::now();
        let observed = engine.run(&inputs, k, &mut output)?;
        let elapsed = start.elapsed().as_secs_f64();
        if observed != expected {
            return Err("timed result differs from warm-up".into());
        }
        println!("{}\t{:.9}\t{}\t{}\t{}", iteration, elapsed,
                 observed.hits, observed.cost, observed.cigar_bytes);
    }
    Ok(())
}
