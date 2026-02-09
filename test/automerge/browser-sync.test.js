/**
 * Automerge Browser Sync Tests
 *
 * Tests collaborative editing features by running two browser contexts
 * (simulating two users) against a live Node-RED instance.
 *
 * Prerequisites:
 *   - Node-RED running on localhost:1880 with collaborativeEditing: true
 *   - Playwright installed (npx playwright install chromium)
 *
 * Run:
 *   npx playwright test test/automerge/browser-sync.test.js --config test/automerge/playwright.config.js
 */

const { test, expect } = require('@playwright/test');

const BASE_URL = process.env.NODE_RED_URL || 'http://localhost:1880';
const LOAD_TIMEOUT = 15000;
const SYNC_WAIT = 6000;

/**
 * Wait for the Node-RED editor to fully load with Automerge ready
 */
async function waitForEditor(page) {
    await page.goto(BASE_URL);
    // First wait for the RED object and basic editor readiness
    await page.waitForFunction(() => {
        return typeof RED !== 'undefined' &&
               RED.nodes &&
               RED.view &&
               RED.workspaces;
    }, { timeout: LOAD_TIMEOUT });

    // Then wait for Automerge to initialize (may take longer due to WASM + WebSocket)
    await page.waitForFunction(() => {
        return RED.automerge &&
               RED.automerge.isEnabled() &&
               RED.automerge.getDocument() !== null;
    }, { timeout: 30000 });

    // Extra wait for sync to stabilize
    await page.waitForTimeout(2000);
}

/**
 * Get node/workspace/subflow IDs from the Automerge document
 */
async function getDocState(page) {
    return page.evaluate(() => {
        const doc = RED.automerge.getDocument();
        if (!doc) return { nodes: [], workspaces: [], subflows: [], groups: [] };
        const state = JSON.parse(JSON.stringify(doc));
        return {
            nodes: Object.keys(state.nodes || {}),
            workspaces: Object.keys(state.workspaces || {}),
            subflows: Object.keys(state.subflows || {}),
            groups: Object.keys(state.groups || {}),
            workspaceOrder: state.workspaceOrder || []
        };
    });
}

/**
 * Get a specific node's data from the Automerge document
 */
async function getDocNode(page, nodeId) {
    return page.evaluate((id) => {
        const doc = RED.automerge.getDocument();
        if (!doc) return null;
        const state = JSON.parse(JSON.stringify(doc));
        return state.nodes[id] || state.workspaces[id] || state.subflows[id] || state.groups[id] || null;
    }, nodeId);
}

test.describe('Automerge Collaborative Editing Sync', () => {
    let contextA;
    let contextB;
    let pageA;
    let pageB;

    test.beforeAll(async ({ browser }) => {
        contextA = await browser.newContext();
        contextB = await browser.newContext();
        pageA = await contextA.newPage();
        pageB = await contextB.newPage();

        await waitForEditor(pageA);
        await waitForEditor(pageB);
    });

    test.afterAll(async () => {
        await contextA?.close();
        await contextB?.close();
    });

    test('both tabs have Automerge enabled and a document loaded', async () => {
        const enabledA = await pageA.evaluate(() => RED.automerge.isEnabled());
        const enabledB = await pageB.evaluate(() => RED.automerge.isEnabled());
        expect(enabledA).toBe(true);
        expect(enabledB).toBe(true);

        const hasDocA = await pageA.evaluate(() => RED.automerge.getDocument() !== null);
        const hasDocB = await pageB.evaluate(() => RED.automerge.getDocument() !== null);
        expect(hasDocA).toBe(true);
        expect(hasDocB).toBe(true);
    });

    test('node add syncs between tabs via Automerge', async () => {
        const nodeId = await pageA.evaluate(() => {
            const id = RED.nodes.id();
            const ws = RED.nodes.getWorkspaceOrder()[0];
            RED.automerge.addNode({
                id: id,
                type: 'inject',
                name: 'test-sync-node',
                x: 200,
                y: 200,
                z: ws,
                wires: [[]]
            });
            return id;
        });

        // Verify in A first
        const nodeInA = await getDocNode(pageA, nodeId);
        expect(nodeInA).not.toBeNull();

        // Poll for sync with retries instead of fixed wait
        let nodeInB = null;
        for (let attempt = 0; attempt < 10; attempt++) {
            await pageB.waitForTimeout(1000);
            nodeInB = await getDocNode(pageB, nodeId);
            if (nodeInB) break;
        }

        expect(nodeInB).not.toBeNull();
        expect(nodeInB.name).toBe('test-sync-node');
        expect(nodeInB.type).toBe('inject');

        // Cleanup
        await pageA.evaluate((id) => {
            RED.automerge.removeNode(id, 'inject');
        }, nodeId);
        await pageA.waitForTimeout(SYNC_WAIT);
    });

    test('node property update syncs between tabs', async () => {
        const nodeId = await pageA.evaluate(() => {
            const id = RED.nodes.id();
            const ws = RED.nodes.getWorkspaceOrder()[0];
            RED.automerge.addNode({
                id: id,
                type: 'debug',
                name: 'update-test',
                x: 150,
                y: 150,
                z: ws,
                wires: []
            });
            return id;
        });

        await pageB.waitForTimeout(SYNC_WAIT);

        let nodeInB = await getDocNode(pageB, nodeId);
        expect(nodeInB).not.toBeNull();
        expect(nodeInB.name).toBe('update-test');

        await pageA.evaluate((id) => {
            RED.automerge.updateNode(id, { name: 'renamed-node' });
        }, nodeId);

        await pageB.waitForTimeout(SYNC_WAIT);

        nodeInB = await getDocNode(pageB, nodeId);
        expect(nodeInB.name).toBe('renamed-node');

        // Cleanup
        await pageA.evaluate((id) => {
            RED.automerge.removeNode(id, 'debug');
        }, nodeId);
        await pageA.waitForTimeout(SYNC_WAIT);
    });

    test('node position update syncs between tabs', async () => {
        const nodeId = await pageA.evaluate(() => {
            const id = RED.nodes.id();
            const ws = RED.nodes.getWorkspaceOrder()[0];
            RED.automerge.addNode({
                id: id,
                type: 'debug',
                name: 'drag-test',
                x: 100,
                y: 100,
                z: ws,
                wires: []
            });
            return id;
        });

        await pageB.waitForTimeout(SYNC_WAIT);

        await pageA.evaluate((id) => {
            RED.automerge.batchPositionUpdate([{id: id, x: 350, y: 250}]);
        }, nodeId);

        await pageB.waitForTimeout(SYNC_WAIT);

        const nodeInB = await getDocNode(pageB, nodeId);
        expect(nodeInB).not.toBeNull();
        expect(nodeInB.x).toBe(350);
        expect(nodeInB.y).toBe(250);

        // Cleanup
        await pageA.evaluate((id) => {
            RED.automerge.removeNode(id, 'debug');
        }, nodeId);
        await pageA.waitForTimeout(SYNC_WAIT);
    });

    test('workspace add/update/delete syncs between tabs', async () => {
        const wsId = await pageA.evaluate(() => {
            const id = RED.nodes.id();
            RED.automerge.addNode({
                type: 'tab',
                id: id,
                label: 'Sync Test Tab',
                disabled: false,
                info: ''
            });
            return id;
        });

        await pageB.waitForTimeout(SYNC_WAIT);

        const wsInB = await getDocNode(pageB, wsId);
        expect(wsInB).not.toBeNull();
        expect(wsInB.label).toBe('Sync Test Tab');
        expect(wsInB.disabled).toBe(false);

        await pageA.evaluate((id) => {
            RED.automerge.updateNode(id, { disabled: true });
        }, wsId);

        await pageB.waitForTimeout(SYNC_WAIT);

        const wsUpdated = await getDocNode(pageB, wsId);
        expect(wsUpdated.disabled).toBe(true);

        await pageA.evaluate((id) => {
            RED.automerge.removeNode(id, 'tab');
        }, wsId);

        await pageB.waitForTimeout(SYNC_WAIT);

        const wsDeleted = await getDocNode(pageB, wsId);
        expect(wsDeleted).toBeNull();
    });

    test('concurrent edits from both tabs merge correctly', async () => {
        const [nodeIdA, nodeIdB] = await Promise.all([
            pageA.evaluate(() => {
                const id = RED.nodes.id();
                const ws = RED.nodes.getWorkspaceOrder()[0];
                RED.automerge.addNode({
                    id: id, type: 'inject', name: 'concurrent-A',
                    x: 100, y: 300, z: ws, wires: [[]]
                });
                return id;
            }),
            pageB.evaluate(() => {
                const id = RED.nodes.id();
                const ws = RED.nodes.getWorkspaceOrder()[0];
                RED.automerge.addNode({
                    id: id, type: 'debug', name: 'concurrent-B',
                    x: 300, y: 300, z: ws, wires: []
                });
                return id;
            })
        ]);

        await pageA.waitForTimeout(SYNC_WAIT);
        await pageB.waitForTimeout(SYNC_WAIT);

        const nodeAinA = await getDocNode(pageA, nodeIdA);
        const nodeBinA = await getDocNode(pageA, nodeIdB);
        const nodeAinB = await getDocNode(pageB, nodeIdA);
        const nodeBinB = await getDocNode(pageB, nodeIdB);

        expect(nodeAinA).not.toBeNull();
        expect(nodeBinA).not.toBeNull();
        expect(nodeAinB).not.toBeNull();
        expect(nodeBinB).not.toBeNull();
        expect(nodeAinA.name).toBe('concurrent-A');
        expect(nodeBinB.name).toBe('concurrent-B');

        // Cleanup
        await pageA.evaluate((ids) => {
            ids.forEach(id => RED.automerge.removeNode(id));
        }, [nodeIdA, nodeIdB]);
        await pageA.waitForTimeout(SYNC_WAIT);
    });

    test('subflow add/delete syncs between tabs', async () => {
        const subflowId = await pageA.evaluate(() => {
            const id = RED.nodes.id();
            RED.automerge.addNode({
                type: 'subflow',
                id: id,
                name: 'Sync Test Subflow',
                info: '',
                in: [],
                out: []
            });
            return id;
        });

        await pageB.waitForTimeout(SYNC_WAIT);

        const sfInB = await getDocNode(pageB, subflowId);
        expect(sfInB).not.toBeNull();
        expect(sfInB.name).toBe('Sync Test Subflow');

        await pageA.evaluate((id) => {
            RED.automerge.removeNode(id, 'subflow');
        }, subflowId);

        await pageB.waitForTimeout(SYNC_WAIT);

        const sfDeleted = await getDocNode(pageB, subflowId);
        expect(sfDeleted).toBeNull();
    });

    test('workspace order sync between tabs', async () => {
        // Add two workspaces in tab A and immediately set order
        const result = await pageA.evaluate(() => {
            const id1 = RED.nodes.id();
            const id2 = RED.nodes.id();
            RED.automerge.addNode({ type: 'tab', id: id1, label: 'Order Test 1', disabled: false });
            RED.automerge.addNode({ type: 'tab', id: id2, label: 'Order Test 2', disabled: false });

            // Get existing workspaceOrder, append ws2 before ws1
            const doc = RED.automerge.getDocument();
            const current = JSON.parse(JSON.stringify(doc.workspaceOrder || []));
            // Filter out ws1/ws2 if already present, then append ws2 before ws1
            const base = current.filter(id => id !== id1 && id !== id2);
            RED.automerge.setWorkspaceOrder([...base, id2, id1]);

            return { ws1: id1, ws2: id2 };
        });

        const { ws1, ws2 } = result;

        // Poll for sync
        let orderB = [];
        for (let attempt = 0; attempt < 10; attempt++) {
            await pageB.waitForTimeout(1000);
            orderB = await pageB.evaluate(() => {
                const doc = RED.automerge.getDocument();
                return JSON.parse(JSON.stringify(doc.workspaceOrder || []));
            });
            if (orderB.includes(ws1) && orderB.includes(ws2)) break;
        }

        const idx1 = orderB.indexOf(ws1);
        const idx2 = orderB.indexOf(ws2);
        expect(idx1).toBeGreaterThan(-1);
        expect(idx2).toBeGreaterThan(-1);
        expect(idx2).toBeLessThan(idx1);

        // Cleanup
        await pageA.evaluate((ids) => {
            ids.forEach(id => RED.automerge.removeNode(id, 'tab'));
        }, [ws1, ws2]);
        await pageA.waitForTimeout(SYNC_WAIT);
    });

    test('node removal syncs between tabs', async () => {
        const nodeId = await pageA.evaluate(() => {
            const id = RED.nodes.id();
            const ws = RED.nodes.getWorkspaceOrder()[0];
            RED.automerge.addNode({
                id: id, type: 'inject', name: 'remove-test',
                x: 400, y: 400, z: ws, wires: [[]]
            });
            return id;
        });

        await pageB.waitForTimeout(SYNC_WAIT);

        let nodeInB = await getDocNode(pageB, nodeId);
        expect(nodeInB).not.toBeNull();

        await pageA.evaluate((id) => {
            RED.automerge.removeNode(id, 'inject');
        }, nodeId);

        await pageB.waitForTimeout(SYNC_WAIT);

        nodeInB = await getDocNode(pageB, nodeId);
        expect(nodeInB).toBeNull();
    });
});
