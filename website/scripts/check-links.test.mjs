import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { preview } from 'astro';
import { checkBuiltSite } from './check-links.mjs';
import { repositoryInfo } from '../site-config.mjs';

async function fixture(t, html) {
	const directory = await mkdtemp(join(tmpdir(), 'photo-export-links-'));
	t.after(() => rm(directory, { recursive: true, force: true }));
	await mkdir(join(directory, 'dist/next'), { recursive: true });
	await writeFile(join(directory, 'dist/index.html'), html);
	await writeFile(
		join(directory, 'dist/next/index.html'),
		'<p id="valid">Next</p>',
	);
	await writeFile(
		join(directory, 'dist/picture.svg'),
		'<svg xmlns="http://www.w3.org/2000/svg"/>',
	);
	return {
		root: pathToFileURL(directory + '/'),
		base: '/fixture/',
		log: () => {},
	};
}

async function assertClosed(url) {
	await assert.rejects(
		fetch(url, { signal: AbortSignal.timeout(1000) }),
		/fetch failed/,
	);
}

test('valid pages/assets pass at the deployed base; external hosts and fragments are skipped', async (t) => {
	const options = await fixture(
		t,
		'<a href="/fixture/next/#missing-fragment">Next</a><img src="/fixture/picture.svg"><a href="https://external.invalid/">External</a><a href="mailto:test@example.com">Mail</a>',
	);
	const { url, results } = await checkBuiltSite(options);
	assert.equal(results.passed, true);
	assert.ok(results.links.some((link) => link.url.includes('/fixture/next/')));
	assert.ok(
		results.links.some(
			(link) =>
				link.url.includes('external.invalid') && link.state === 'SKIPPED',
		),
	);
	await assertClosed(url);
});

test('missing local pages and assets report their referring page and stop preview', async (t) => {
	const options = await fixture(
		t,
		'<a href="/fixture/missing/">Missing</a><img src="/fixture/missing.svg">',
	);
	let owned;
	const log = [];
	await assert.rejects(
		checkBuiltSite({
			...options,
			log: (line) => log.push(line),
			startPreview: async (config) => {
				owned = await preview(config);
				return owned;
			},
		}),
		/2 broken local links/,
	);
	assert.ok(
		log.some(
			(line) =>
				line.includes('/fixture/missing/') &&
				line.includes('from http://127.0.0.1:'),
		),
	);
	assert.ok(
		log.some(
			(line) =>
				line.includes('/fixture/missing.svg') &&
				line.includes('from http://127.0.0.1:'),
		),
	);
	await assertClosed(`http://127.0.0.1:${owned.port}/fixture/`);
});

test('strict binding rejects an occupied port without stopping the existing server', async (t) => {
	const server = createServer((_, response) =>
		response.end('unrelated server'),
	);
	await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
	t.after(() => new Promise((resolve) => server.close(resolve)));
	const port = server.address().port;
	const options = await fixture(t, '<p>Ready</p>');
	await assert.rejects(checkBuiltSite({ ...options, port }), /already in use/);
	assert.equal(
		await (await fetch(`http://127.0.0.1:${port}/`)).text(),
		'unrelated server',
	);
});

test('startup errors retain their actual cause', async (t) => {
	const options = await fixture(t, '<p>Ready</p>');
	await assert.rejects(
		checkBuiltSite({
			...options,
			startPreview: async () => {
				throw new Error('fixture startup failure');
			},
		}),
		/fixture startup failure/,
	);
});

test('startup timeout returns promptly and closes a server that resolves late', async (t) => {
	const options = await fixture(t, '<p>Ready</p>');
	const owned = await preview({
		root: options.root,
		base: options.base,
		server: { host: '127.0.0.1', port: 0 },
		logLevel: 'silent',
	});
	t.after(() => owned.stop());
	let release;
	const startup = new Promise((resolve) => {
		release = resolve;
	});
	await assert.rejects(
		checkBuiltSite({
			...options,
			startupTimeoutMs: 20,
			startPreview: () => startup,
		}),
		/Preview startup timed out/,
	);
	release(owned);
	for (let attempt = 0; attempt < 20; attempt++) {
		try {
			await fetch(`http://127.0.0.1:${owned.port}/fixture/`);
		} catch {
			return;
		}
		await delay(10);
	}
	assert.fail('late preview server was not closed');
});

test('startup rejection after timeout is handled', async (t) => {
	const options = await fixture(t, '<p>Ready</p>');
	let rejectStartup;
	const startup = new Promise((_, reject) => {
		rejectStartup = reject;
	});
	await assert.rejects(
		checkBuiltSite({
			...options,
			startupTimeoutMs: 20,
			startPreview: () => startup,
		}),
		/Preview startup timed out/,
	);
	rejectStartup(new Error('late fixture rejection'));
	await delay(0);
});

test('repository base derivation stays shared and validates repository identity', () => {
	assert.deepEqual(repositoryInfo('owner/renamed'), {
		base: '/renamed',
		repoUrl: 'https://github.com/owner/renamed',
	});
	assert.throws(() => repositoryInfo('invalid'), /Invalid GITHUB_REPOSITORY/);
});
