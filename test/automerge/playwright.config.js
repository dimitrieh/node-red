const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
    testDir: '.',
    testMatch: '*.test.js',
    timeout: 90000,
    expect: {
        timeout: 10000
    },
    use: {
        baseURL: process.env.NODE_RED_URL || 'http://localhost:1880',
        headless: true,
        viewport: { width: 1280, height: 720 }
    },
    projects: [
        {
            name: 'chromium',
            use: { browserName: 'chromium' }
        }
    ]
});
