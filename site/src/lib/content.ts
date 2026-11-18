const repo = 'https://github.com/ken-morel/weft';

export const site = {
	name: 'weft',
	tagline: 'Deployments for tiny Linux hosts',
	description:
		'Weft is a deployment and task orchestrator for Linux, written in Zig. One static binary is the CLI, the remote daemon, and the task supervisor.',
	repo,
	readme: `${repo}#readme`,
	license: `${repo}/blob/dev/LICENSE`,
	changelog: `${repo}/blob/dev/CHANGELOG.md`,
	styleguide: `${repo}/blob/dev/STYLEGUIDE.md`,
	releases: `${repo}/releases/tag/nightly`,
	maintainer: { name: 'Engon Ken Morel', url: 'https://github.com/ken-morel' },
	zigVersion: '0.18.0',
	inspiration: 'https://eza.rocks'
} as const;

export const nav = [
	{ href: '#try', label: 'Try it' },
	{ href: '#features', label: 'Features' },
	{ href: '#install', label: 'Install' },
	{ href: '#commands', label: 'Commands' },
	{ href: '#profiles', label: 'Profiles' }
] as const;

/* terminal lines: [text, tone] segments */
export type Tone =
	| 'blue'
	| 'yellow'
	| 'red'
	| 'green'
	| 'cyan'
	| 'purple'
	| 'dim'
	| 'faint'
	| 'bold'
	| '';
export type Segment = readonly [string, Tone];
export type Line = readonly Segment[];

const sep: Segment = [' │ ', 'dim'];
const out = (key: string, tone: Tone, text: string): Line => [[key, tone], sep, [text, '']];
const prompt = (cmd: string): Line => [
	['$ ', 'green'],
	[cmd, 'bold']
];

export const installCommand = `curl -fsSL ${repo}/releases/download/nightly/weft-linux-x86_64.tar.gz | sudo tar -xz -C /usr/local/bin`;

export const heroTiles = [
	{ label: 'kvm', note: 'VMs, bare metal' },
	{ label: 'lxc', note: 'containers' },
	{ label: 'vz', note: 'OpenVZ' },
	{ label: 'colab', note: 'notebooks' },
	{ label: 'action', note: 'GitHub CI' }
] as const;

export const heroBefore = [
	'scp ./app root@vps:/srv/app',
	'ssh root@vps systemctl stop app',
	'ssh root@vps "cd /srv && ./migrate"',
	'# failed? start over',
	'ssh root@vps systemctl start app'
] as const;

export const heroAfter: Line[] = [
	prompt('weft do prod:vps.server'),
	[['{', 'cyan'], [' prod:local.build', '']],
	[['}', 'green'], [' prod:local.build (8412ms, CPU: 7930ms)', '']],
	[['>', 'yellow'], [' build@vps(compressed)', '']],
	[['{', 'purple'], [' prod:vps.server', '']],
	out('prod:vps.server', 'purple', 'listening on :8080')
];

export const heroStickers = [
	{ text: 'Nix pkgs', tone: 'blue', tilt: -6 },
	{ text: 'Ed25519', tone: 'green', tilt: 5 },
	{ text: 'resume', tone: 'paper', tilt: -3 }
] as const;

/* playground */
export type Demo = {
	id: string;
	label: string;
	cmd: string;
	about: string;
	lines: Line[];
	footer?: Line[];
};

export const demos: Demo[] = [
	{
		id: 'do',
		label: 'do',
		cmd: 'weft do prod:vps.server',
		about: 'Build locally, ship the artifact, restart the server.',
		lines: [
			[['{', 'cyan'], [' prod:local.build', '']],
			out('prod:local.build', 'cyan', 'zig build -Doptimize=ReleaseSafe'),
			out('prod:local.build', 'cyan', 'Build Summary: 4/4 steps succeeded'),
			[['}', 'green'], [' prod:local.build (8412ms, CPU: 7930ms)', '']],
			[['>', 'yellow'], [' build@vps(compressed)', '']],
			[['{', 'purple'], [' prod:vps.server', '']],
			out('prod:vps.server', 'purple', 'starting shop server'),
			out('prod:vps.server', 'purple', 'listening on 0.0.0.0:8080')
		],
		footer: [[['! prod:vps.server (2140ms, CPU: 0.4% / 12ms, RAM: 18.2 MB)', 'purple']]]
	},
	{
		id: 'fail',
		label: 'do (fails)',
		cmd: 'weft do prod:vps.migrate',
		about: 'A step fails. Everything before it is already recorded.',
		lines: [
			[['{}', 'cyan'], [' prod:local.build', '']],
			[['>', 'yellow'], [' build@vps(compressed)', '']],
			[['{', 'blue'], [' prod:vps.migrate', '']],
			out('prod:vps.migrate', 'blue', 'applying 0007_orders.sql'),
			out('prod:vps.migrate', 'blue', 'error: relation "orders" already exists'),
			[['#.err', 'red'], [' prod:vps.migrate (1204ms, CPU: 96ms): exit code 1', '']]
		]
	},
	{
		id: 'resume',
		label: 'resume',
		cmd: 'weft resume',
		about: 'Retry from the failed step. Finished outputs are skipped.',
		lines: [
			[['{', 'blue'], [' prod:vps.migrate', '']],
			out('prod:vps.migrate', 'blue', 'applying 0007_orders.sql'),
			out('prod:vps.migrate', 'blue', 'ok'),
			[['}', 'green'], [' prod:vps.migrate (930ms, CPU: 210ms)', '']],
			[['{', 'purple'], [' prod:vps.server', '']],
			out('prod:vps.server', 'purple', 'listening on 0.0.0.0:8080')
		],
		footer: [[['! prod:vps.server (1730ms, CPU: 0.3% / 9ms, RAM: 18.0 MB)', 'purple']]]
	},
	{
		id: 'logs',
		label: 'task logs',
		cmd: 'weft task logs vps.server',
		about: 'Follow one step’s raw logs until it exits.',
		lines: [
			[['{', ''], [' vps.server', '']],
			[['starting shop server', '']],
			[['listening on 0.0.0.0:8080', '']],
			[['GET /health 200 0.4ms', '']],
			[['GET /orders 200 3.1ms', '']]
		]
	},
	{
		id: 'env',
		label: 'env',
		cmd: 'weft env prod:build -- zig version',
		about: 'Run any command inside a pipeline’s Nix environment.',
		lines: [[['0.18.0', '']]]
	}
];

export const facts = [
	{ value: '1', label: 'binary: CLI, daemon, and supervisor' },
	{ value: '0', label: 'container runtimes required' },
	{ value: '4', label: 'isolation profiles, VM to notebook' },
	{ value: 'MIT', label: 'licensed, written in Zig' }
] as const;

/* features bento */
export const features = [
	{
		title: 'no container runtime',
		body: 'Tasks run under a built-in supervisor with Linux namespaces and cgroups v2. No Docker daemon, no registry.',
		snippet: [[['pivot_root', 'cyan'], [' + ', 'dim'], ['cgroup v2', 'green']]] as Line[],
		wide: true
	},
	{
		title: 'nix without nix',
		body: 'Packages come straight from cache.nixos.org into a shared store. The host needs neither NixOS nor a Nix daemon.',
		snippet: [[['.pkgs', 'yellow'], [' = .{"…-zig-0.18.0"}', '']]] as Line[]
	},
	{
		title: 'hosts without a public IP',
		body: 'Reach a daemon over TCP, through a stdio script (!script), or a script that prints the address (~script).',
		snippet: [[['.{ "colab", ', ''], ['"!remote colab"', 'green'], [' }', '']]] as Line[]
	},
	{
		title: 'signed & sealed',
		body: 'Clients authenticate with Ed25519 keys. Sessions use X25519 key exchange and XChaCha20-Poly1305.',
		snippet: [[['$ ', 'green'], ['weft key', 'bold']]] as Line[]
	},
	{
		title: 'resumable',
		body: 'Artifacts move between remotes on their own. A failed deploy resumes at the step that broke.',
		snippet: [[['$ ', 'green'], ['weft resume', 'bold']]] as Line[]
	},
	{
		title: 'live monitor',
		body: 'Stream CPU, RAM, disk, network, and per-task usage from any daemon. Pipe it and get a plain table.',
		snippet: [[['$ ', 'green'], ['weft remote monitor vps', 'bold']]] as Line[],
		wide: true
	}
] as const;

export const deep = [
	{ term: '.sibling', desc: 'kill, ignore, fail, or skip when a previous run is still alive' },
	{ term: '.keep', desc: 'persistent caches that survive between deployments' },
	{ term: '.tune', desc: 'cpu, memory, private network, and io limits per pipeline' },
	{ term: 'weft cache', desc: 'pull and push caches between remotes' },
	{ term: 'weft artifact', desc: 'pull, push, or register build outputs by hand' },
	{ term: 'piped output', desc: 'redirect any live view and get append-only plain text' }
] as const;

/* install picker */
export const installs = [
	{
		id: 'binary',
		label: 'Prebuilt binary',
		note: 'Linux x86_64 nightly',
		code: `curl -fsSL "${repo}/releases/download/nightly/weft-linux-x86_64.tar.gz" \\
  | sudo tar -xz -C /usr/local/bin
sudo chmod +x /usr/local/bin/weft
weft version`
	},
	{
		id: 'remote',
		label: 'Onto a server',
		note: 'over SSH, from your machine',
		code: `# copies weft, installs the daemon, authorizes your key
weft remote install root@203.0.113.10 kvm-small`
	},
	{
		id: 'action',
		label: 'GitHub Action',
		note: 'deploy from CI',
		code: `- uses: ken-morel/weft@nightly
  with:
    version: nightly`
	},
	{
		id: 'source',
		label: 'From source',
		note: `Zig ${site.zigVersion}+`,
		code: `git clone ${repo}.git
cd weft
zig build -Doptimize=ReleaseSafe`
	}
] as const;

/* command reference */
export const reference = [
	{
		id: 'remote',
		label: 'remote',
		items: [
			{ term: 'remote install <host> [profile]', desc: 'scp weft to a host, install the daemon, authorize your key' },
			{ term: 'remote register <host> [pubkey]', desc: 'authorize another client key on a remote' },
			{ term: 'remote monitor [remote]', desc: 'live CPU, memory, disk, network, and task usage' },
			{ term: 'daemon install [profile]', desc: 'install the daemon under systemd, openrc, or runit' },
			{ term: 'daemon register <key>', desc: 'add a key and reload without restarting' },
			{ term: 'daemon run', desc: 'run the daemon in the foreground' }
		]
	},
	{
		id: 'pipelines',
		label: 'pipelines',
		items: [
			{ term: 'do [mode:][remote.]pipeline …', desc: 'resolve the graph and run pipelines across remotes' },
			{ term: 'resume [deployment]', desc: 'retry failed or interrupted steps' },
			{ term: 'env [mode:]name[,name] [-- cmd]', desc: 'shell or command inside a pipeline environment' },
			{ term: 'task spawn <target>', desc: 'run one step without its upstream' },
			{ term: 'task kill <target>', desc: 'stop a running step' },
			{ term: 'task logs <target>', desc: 'follow a step’s logs until it exits' }
		]
	},
	{
		id: 'data',
		label: 'artifacts & cache',
		items: [
			{ term: 'artifact pull|push <name> [remote]', desc: 'move build outputs between machines' },
			{ term: 'artifact register <name>', desc: 'record an artifact and print its path' },
			{ term: 'artifact path <name>', desc: 'print where an artifact lives' },
			{ term: 'cache pull|push <remote[.cache]>', desc: 'sync persistent caches' },
			{ term: 'cache path <remote[.cache]>', desc: 'print a local cache path' }
		]
	},
	{
		id: 'misc',
		label: 'nix & misc',
		items: [
			{ term: 'nix search <query>', desc: 'search the Nix package index' },
			{ term: 'nix query <name>', desc: 'list versions and store paths' },
			{ term: 'nix info <pkg>', desc: 'print .narinfo metadata as YAML' },
			{ term: 'check', desc: 'validate weft/weft.zon' },
			{ term: 'key', desc: 'print this client’s public key' },
			{ term: 'decode [file]', desc: 'print a zoto binary file as Zig literals' },
			{ term: 'version', desc: 'build version and wire protocol hash' }
		]
	}
] as const;

/* daemon profiles */
export const isolations = [
	{ id: 'kvm', label: 'kvm', note: 'VMs and bare metal', flags: { cgroups: true, mount: true, pid: true, net: true } },
	{ id: 'lxc', label: 'lxc', note: 'LXC containers', flags: { cgroups: false, mount: true, pid: true, net: true } },
	{ id: 'vz', label: 'vz', note: 'OpenVZ / Virtuozzo', flags: { cgroups: false, mount: false, pid: false, net: false } },
	{ id: 'colab', label: 'colab', note: 'notebooks', flags: { cgroups: false, mount: false, pid: false, net: false } }
] as const;

export const scales = [
	{ id: 'tiny', label: 'tiny', note: '1 worker', max_workers: 1, compress: false, decompress: false },
	{ id: 'small', label: 'small', note: '4 workers', max_workers: 4, compress: false, decompress: true },
	{ id: 'large', label: 'large', note: '16 workers', max_workers: 16, compress: true, decompress: true }
] as const;

/* coming from */
export const migration = {
	from: 'deploy.sh',
	removed: [
		'docker build -t shop . && docker push registry/shop',
		'ssh vps "docker pull registry/shop && docker restart shop"'
	],
	added: [
		'.{ .name = "build", .in = .{"-"}, .on = .{"local"} },',
		'.{ .name = "server", .in = .{"build"}, .sibling = .{ .then = .kill } },'
	],
	note: 'then: weft do prod:vps.server'
} as const;
