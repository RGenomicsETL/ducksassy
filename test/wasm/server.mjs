import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { build } from 'esbuild';

const root = resolve(import.meta.dirname, '../..');
const dist = resolve(import.meta.dirname, 'node_modules/@duckdb/duckdb-wasm/dist');
const stage = resolve(root, '.deps-port/wasm-http');
const artifacts = resolve(process.env.DUCKSASSY_WASM_ARTIFACT_DIR || `${root}/.deps-port/artifacts`);
await mkdir(stage, { recursive: true });
await build({
    entryPoints: [resolve(dist, 'duckdb-browser.mjs')],
    outfile: resolve(stage, 'duckdb-browser.mjs'),
    bundle: true, format: 'esm', platform: 'browser',
});

const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.wasm': 'application/wasm' };
const server = createServer(async (request, response) => {
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    response.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    const path = new URL(request.url, 'http://localhost').pathname;
    let base, relative;
    if (path.startsWith('/dist/')) {
        base = dist; relative = path.slice(6);
    } else if (path.startsWith('/extensions/')) {
        base = artifacts; relative = path.slice(12);
        if (relative.endsWith('.duckdb_extension')) relative += '.wasm';
    } else if (path === '/duckdb-browser.mjs') {
        base = stage; relative = 'duckdb-browser.mjs';
    } else if (path === '/') {
        base = import.meta.dirname; relative = 'index.html';
    } else {
        response.writeHead(404).end(); return;
    }
    const file = resolve(base, relative);
    if (!file.startsWith(base + sep)) {
        response.writeHead(403).end(); return;
    }
    try {
        const data = await readFile(file);
        response.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream' });
        response.end(data);
    } catch (error) {
        console.error(file, error.message);
        response.writeHead(404).end();
    }
});
server.listen(Number(process.env.DUCKSASSY_WASM_PORT || 8765), '127.0.0.1');
