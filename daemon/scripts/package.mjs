import { execFileSync } from 'node:child_process';
import { chmod, copyFile, mkdir, mkdtemp, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
const osNames = { darwin: 'macos', linux: 'linux' };
const os = osNames[process.platform];
if (!os || !['x64', 'arm64'].includes(process.arch)) {
  throw new Error('请在 Linux、WSL 或 macOS 的 x64／arm64 环境打包');
}
if (Number(process.versions.node.split('.')[0]) < 26) {
  throw new Error('打包需要 Node.js 26 或更高版本');
}

// 归档名称统一使用 package.json 的版本和实际构建架构。
const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
const name = `nerve-daemon-v${version}-${os}-${process.arch}`;
const releaseDir = join(root, 'release');
await mkdir(releaseDir, { recursive: true });
const staging = await mkdtemp(join(releaseDir, '.package-'));
const bundle = join(staging, name);
const executable = join(bundle, 'nerve');
const archive = join(staging, name + '.tar.gz');

try {
  await mkdir(bundle);
  const entry = join(staging, 'cli.mjs');
  const extension = join(staging, 'omp-extension.mjs');
  const bundleOptions = { absWorkingDir: root, bundle: true, platform: 'node', format: 'esm', target: 'node24' };

  // 合并本地模块，运行时只使用 Node 内置模块。OMP 扩展作为资源嵌入。
  await Promise.all([
    build({ ...bundleOptions, entryPoints: ['dist/cli.js'], outfile: entry }),
    build({ ...bundleOptions, entryPoints: ['adapters/omp/extension.ts'], outfile: extension }),
  ]);
  const seaConfig = join(staging, 'sea.json');
  await writeFile(seaConfig, JSON.stringify({
    main: entry,
    mainFormat: 'module',
    output: executable,
    disableExperimentalSEAWarning: true,
    assets: { 'omp-extension.mjs': extension },
  }));
  execFileSync(process.execPath, ['--build-sea', seaConfig], { stdio: 'inherit' });
  await chmod(executable, 0o755);
  if (process.platform === 'darwin') {
    // 注入脚本后重新签名，使 macOS 可以加载修改后的 Mach-O。
    execFileSync('codesign', ['--force', '--sign', '-', executable], { stdio: 'inherit' });
  }
  const installer = join(bundle, 'install.sh');
  await copyFile(join(root, 'scripts', 'install.sh'), installer);
  await chmod(installer, 0o755);
  const nodeBinary = await realpath(process.execPath);
  await copyFile(join(dirname(nodeBinary), '..', 'LICENSE'), join(bundle, 'Node.js-LICENSE'));

  execFileSync('tar', ['-czf', archive, '-C', staging, name], { stdio: 'inherit' });
  execFileSync(process.execPath, [join(root, 'scripts', 'check-package.mjs'), archive], { stdio: 'inherit' });
  const output = join(releaseDir, basename(archive));
  await rename(archive, output);
  console.log(`已构建 ${output}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
