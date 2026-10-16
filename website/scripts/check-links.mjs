import { preview } from 'astro';
import { LinkChecker, LinkState } from 'linkinator';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { repositoryInfo } from '../site-config.mjs';

export async function checkBuiltSite({
	root = new URL('../', import.meta.url),
	base = repositoryInfo().base,
	port = 0,
	startupTimeoutMs = 15_000,
	startPreview = preview,
	log = console.log,
} = {}) {
	let timedOut = false;
	let timer;
	const startup = Promise.resolve().then(() =>
		startPreview({
			root: root instanceof URL ? fileURLToPath(root) : root,
			base,
			server: { host: '127.0.0.1', port },
			vite: { preview: { strictPort: true } },
			logLevel: 'silent',
		}),
	);
	// A timeout must not leave a server that finishes starting later. Handle
	// late rejection too, without waiting forever for a stuck startup promise.
	startup
		.then(
			async (server) => {
				if (timedOut) await server.stop();
			},
			() => {},
		)
		.catch((error) => log(`Late preview cleanup failed: ${error.message}`));
	let server;
	try {
		server = await Promise.race([
			startup,
			new Promise((_, reject) => {
				timer = setTimeout(() => {
					timedOut = true;
					reject(new Error('Preview startup timed out'));
				}, startupTimeoutMs);
			}),
		]);
	} finally {
		clearTimeout(timer);
	}
	const origin = `http://127.0.0.1:${server.port}`;
	const url = `${origin}/${base.replace(/^\/+|\/+$/g, '')}/`;
	try {
		const checker = new LinkChecker();
		checker.on('link', (link) => {
			if (link.state === LinkState.BROKEN) {
				log(
					`Broken local link: ${link.url} (${link.status ?? 'request failed'}) from ${link.parent ?? url}`,
				);
			}
		});
		const results = await checker.check({
			path: url,
			recurse: true,
			checkCss: true,
			checkFragments: false,
			timeout: 5_000,
			concurrency: 10,
			linksToSkip: async (link) => new URL(link).origin !== origin,
		});
		const broken = results.links.filter(
			(link) => link.state === LinkState.BROKEN,
		);
		if (!results.passed) throw new Error(`${broken.length} broken local links`);
		log(
			`Local link check passed (${results.links.length} discovered links): ${url}`,
		);
		return { url, results };
	} finally {
		await server.stop();
	}
}

if (
	process.argv[1] &&
	import.meta.url === pathToFileURL(process.argv[1]).href
) {
	checkBuiltSite().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
}
