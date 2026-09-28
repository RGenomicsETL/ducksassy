import { defineConfig } from '@playwright/test';

const port = process.env.DUCKSASSY_WASM_PORT || '8765';
export default defineConfig({
    testDir: '.',
    testMatch: '*.spec.ts',
    timeout: 120_000,
    workers: 1,
    reporter: 'list',
    use: { baseURL: `http://127.0.0.1:${port}`, headless: true, browserName: 'chromium' },
    webServer: {
        command: 'node server.mjs',
        url: `http://127.0.0.1:${port}`,
        reuseExistingServer: false,
        timeout: 60_000,
    },
});
