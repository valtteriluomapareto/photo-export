// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Derived from the GitHub Actions context so that renaming the repository
// automatically updates the Pages base path and GitHub links on next deploy.
// Falls back to the current slug for local builds.
const FALLBACK_REPOSITORY = 'valtteriluomapareto/photo-export';
const repository = process.env.GITHUB_REPOSITORY || FALLBACK_REPOSITORY;
const [repoOwner, repoName] = repository.split('/');
if (!repoOwner || !repoName || repository.split('/').length !== 2) {
	throw new Error(
		`Invalid GITHUB_REPOSITORY value: "${repository}". Expected "owner/repo".`,
	);
}
const repoUrl = `https://github.com/${repository}`;

// https://astro.build/config
export default defineConfig({
	site: 'https://valtteriluomapareto.github.io',
	base: `/${repoName}`,
	integrations: [
		starlight({
			title: 'Photo Export',
			description:
				'Free macOS app to export and back up your iCloud and Apple Photos library to any drive, organized by year and month.',
			logo: {
				light: './src/assets/photo-export-logo-light.svg',
				dark: './src/assets/photo-export-logo-dark.svg',
			},
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: repoUrl,
				},
			],
			editLink: {
				baseUrl: `${repoUrl}/edit/main/website/src/content/docs/`,
			},
			sidebar: [
				{ label: 'Getting Started', slug: 'getting-started' },
				{
					label: 'Export iCloud Photos to External Drive',
					slug: 'export-icloud-photos',
				},
				{ label: 'Auto Export', slug: 'auto-export' },
				{ label: 'Features', slug: 'features' },
				{ label: 'Architecture', slug: 'architecture' },
				{ label: 'Ideas', slug: 'roadmap' },
			],
		}),
	],
});
