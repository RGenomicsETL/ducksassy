import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';

const manifest = JSON.parse(readFileSync(new URL('../../functions.yaml', import.meta.url), 'utf8'));
const variants = (process.env.DUCKSASSY_WASM_PLATFORMS || 'wasm_mvp,wasm_eh').split(',');
for (const variant of variants) {
    test(`${variant}: stable native SQL catalog and search`, async ({ page }, testInfo) => {
        const messages: string[] = [];
        page.on('console', message => messages.push(message.text()));
        page.on('pageerror', error => messages.push(error.message));
        await page.goto('/');
        await page.waitForFunction(() => typeof (window as any).startDucksassy === 'function');
        const query = (sql: string) => page.evaluate(sql => (window as any).sql(sql), sql);
        try {
            const host = await page.evaluate(variant => (window as any).startDucksassy(variant), variant);
            console.log(variant, host);
            expect(host.platform[0].platform).toBe(variant);
            expect(host.version[0].library_version).toBe('v1.5.5');
            const catalog = await query(`SELECT DISTINCT function_name AS name, function_type AS kind
                FROM duckdb_functions() WHERE function_name LIKE 'sassy\\_%' ESCAPE '\\' ORDER BY 1`);
            expect(catalog).toEqual(manifest.functions.map(({ name, kind }) => ({ name, kind }))
                .sort((a, b) => a.name.localeCompare(b.name)));
            expect(await query(`SELECT count(*)::INTEGER AS n FROM duckdb_functions()
                WHERE function_name LIKE '__sassy%' OR (function_name LIKE 'sassy%' AND function_type LIKE '%macro%')`))
                .toEqual([{ n: 0 }]);
            await query(manifest.community_extension.docs.hello_world_lines
                .filter(line => !line.startsWith('LOAD ')).join('\n'));
            for (const entry of manifest.functions) {
                for (const example of entry.examples) await query(example);
            }
            // Both string types exercise all eight scalar families, including trailing defaults.
            for (const type of ['VARCHAR', 'BLOB']) {
                const pattern = `'ACGT'::${type}`, text = `'TTACGTTT'::${type}`;
                expect(await query(`SELECT
                    len(sassy_matches(${pattern}, ${text}, 0, 'dna', false))::INTEGER AS hits,
                    len(sassy_matches_many([${pattern}], ${text}, 0, 'dna', false))::INTEGER AS panel_hits,
                    sassy_count(${pattern}, ${text}, 0, 'dna', false)::INTEGER AS n,
                    sassy_count_many([${pattern}], ${text}, 0, 'dna', false)::INTEGER AS panel_n,
                    sassy_contains(${pattern}, ${text}, 0) AS found,
                    sassy_contains_many([${pattern}], ${text}, 0) AS panel_found,
                    len(sassy_crispr_matches('ACGTNGG'::${type}, 'TTACGTAGGTT'::${type}, 0))::INTEGER AS crispr,
                    len(sassy_crispr_matches_many(['ACGTNGG'::${type}], 'TTACGTAGGTT'::${type}, 0))::INTEGER AS panel_crispr`))
                    .toEqual([{ hits: 1, panel_hits: 1, n: 1, panel_n: 1, found: true, panel_found: true, crispr: 1, panel_crispr: 1 }]);
            }
            expect(await query(`SELECT hit.text_start::INTEGER AS start, hit.text_end::INTEGER AS stop,
                    hit.strand, hit.cigar, hit.cigar_ops
                FROM (SELECT unnest(sassy_matches('ACGA', 'TTCGTT', 0, 'dna', true, false, 'both')) AS hit)`))
                .toEqual([{ start: 1, stop: 5, strand: '-', cigar: '4=', cigar_ops: [71] }]);
            expect(await query(`SELECT sassy_count(NULL, 'ACGT', 0) AS n,
                sassy_contains('ACGT', NULL, 0) AS found, sassy_matches(NULL, 'ACGT', 0) AS hits`))
                .toEqual([{ n: null, found: null, hits: null }]);
            await expect(query(`SELECT sassy_matches('ACGT', 'ACGT', -1)`)).rejects.toThrow();
            await expect(query(`SELECT sassy_matches('ACGT', 'ACGT', 0, 'bad')`)).rejects.toThrow();
            expect(await query(`SELECT sum(sassy_count('ACGT', CASE WHEN i%2=0 THEN 'ACGT' ELSE 'TTTT' END,
                0, 'dna', false))::INTEGER AS n FROM range(5000) t(i)`)).toEqual([{ n: 2500 }]);
            expect(await query(`SELECT len(sassy_matches('ACGT', repeat('ACGT', 600), 0, 'dna', false))::INTEGER AS n`))
                .toEqual([{ n: 600 }]);
            expect(await query(`SELECT text_start::INTEGER AS start FROM sassy_grep('error', 'error: ' || repeat('ready ', 10000), 0) LIMIT 1`))
                .toEqual([{ start: 0 }]);
            const backend = await query('SELECT * FROM sassy_backend_info() ORDER BY name');
            const expectedBackend = variant === 'wasm_threads' ? 'wasm128' : 'scalar';
            expect(backend.filter(row => row.compiled).map(row => row.name)).toEqual([expectedBackend]);
            expect(backend.filter(row => row.selected).map(row => row.name)).toEqual([expectedBackend]);
            expect(backend.find(row => row.name === expectedBackend).supported).toBe(true);
        } finally {
            await testInfo.attach('browser-console', { body: messages.join('\n'), contentType: 'text/plain' });
            await page.evaluate(async () => { if ((window as any).closeDucksassy) await (window as any).closeDucksassy(); });
        }
    });

    test(`${variant}: distribution requires working Rust panic recovery`, async ({ page }, testInfo) => {
        const messages: string[] = [];
        page.on('console', message => { if (messages.length < 64) messages.push(message.text()); });
        await page.goto('/');
        await page.waitForFunction(() => typeof (window as any).startDucksassy === 'function');
        await page.evaluate(variant => (window as any).startDucksassy(variant), variant);
        await page.evaluate(variant => (window as any).sql(
            `LOAD '${location.origin}/extensions/${variant}/panicprobe.duckdb_extension'`), variant);
        // Capture only the panic call's failure. Setup/LOAD failures must fail the test.
        const result = await page.evaluate(async () => {
            try {
                return { rows: await (window as any).sql('SELECT panicprobe() AS caught'), error: null };
            } catch (error) {
                return { rows: null, error: String(error) };
            }
        });
        await testInfo.attach('panic-console', { body: messages.join('\n'), contentType: 'text/plain' });
        if (result.error) {
            await testInfo.attach('panic-recovery-blocker', { body: result.error, contentType: 'text/plain' });
            console.log(`${variant} excluded: ${result.error}`);
            expect(manifest.community_extension.extension.excluded_platforms.split(';')).toContain(variant);
            expect(result.error).toContain(variant === 'wasm_mvp'
                ? '_setThrew is not defined' : 'Maximum call stack size exceeded');
        } else {
            expect(result.rows).toEqual([{ caught: 1 }]);
        }
        // A failed unwind invalidates the worker; page teardown terminates it.
    });
}
