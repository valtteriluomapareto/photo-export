// Shared by Astro and the built-site checker; keep one repository/base policy.
export function repositoryInfo(
	repository = process.env.GITHUB_REPOSITORY ||
		'valtteriluomapareto/photo-export',
) {
	const [owner, name] = repository.split('/');
	if (!owner || !name || repository.split('/').length !== 2) {
		throw new Error(
			`Invalid GITHUB_REPOSITORY value: "${repository}". Expected "owner/repo".`,
		);
	}
	return { base: `/${name}`, repoUrl: `https://github.com/${repository}` };
}
