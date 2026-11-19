import { execFileSync } from 'node:child_process';
import { chmod, copyFile, mkdir, mkdtemp, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = fileURLToPath(new URL('../', import.meta.url));
// 两个独立程序共用构建和安装流程，各自验证入口。
const products = {
  daemon: { executable: 'nerve', entry: 'dist/cli.js', check: 'check-package.mjs' },
  gateway: { executable: 'nerve-gateway', entry: 'dist/gateway/cli.js', check: 'check-gateway-package.mjs' },
};
const component = process.argv[2] ?? 'daemon';
if (!Object.hasOwn(products, component) || process.argv.length > 3) {
  throw new Error('用法为 npm run package -- [daemon|gateway]');
}
const product = products[component];
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
const name = `nerve-${component}-v${version}-${os}-${process.arch}`;
const releaseDir = join(root, 'release');
await mkdir(releaseDir, { recursive: true });
const staging = await mkdtemp(join(releaseDir, '.package-'));
const bundle = join(staging, name);
const executable = join(bundle, product.executable);
const archive = join(staging, name + '.tar.gz');

try {
  await mkdir(bundle);
  const entry = join(staging, 'cli.mjs');
  const bundleOptions = { absWorkingDir: root, bundle: true, platform: 'node', format: 'esm', target: 'node24' };

  // ws 的 CommonJS 模块依然要加载 Node 内置库。依赖本体随单文件程序打包。
  await build({
    ...bundleOptions, entryPoints: [product.entry], outfile: entry,
    banner: { js: 'import { createRequire as nerveCreateRequire } from "node:module"; const require = nerveCreateRequire(import.meta.url);' },
  });
  const assets = {};
  if (component === 'daemon') {
    const extension = join(staging, 'omp-extension.mjs');
    await build({ ...bundleOptions, entryPoints: ['adapters/omp/extension.ts'], outfile: extension });
    assets['omp-extension.mjs'] = extension;
  }
  const seaConfig = join(staging, 'sea.json');
  await writeFile(seaConfig, JSON.stringify({
    main: entry,
    mainFormat: 'module',
    output: executable,
    disableExperimentalSEAWarning: true,
    assets,
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
  // 随归档分发已打包依赖的许可证。werift 的 npm 归档缺少主许可证，使用匹配版本的上游文件。
  const licenseDir = join(bundle, 'licenses');
  await mkdir(licenseDir);
  const dependencies = component === 'gateway' ? ['ws'] :
    ['werift', 'mediabunny', 'buffer', 'base64-js', 'ieee754', 'multicast-dns', 'thunky', 'dns-packet',
      '@leichtgewicht/ip-codec'];
  for (const dependency of dependencies) {
    const source = dependency === 'werift' ? join(root, 'licenses', 'werift-LICENSE') :
      join(root, 'node_modules', dependency, 'LICENSE');
    await copyFile(source, join(licenseDir, dependency.replace('/', '-') + '-LICENSE'));
  }
  if (component === 'daemon') {
    const notice = 'THIRD_PARTY_LICENSES_LIBWEBRTC.txt';
    await copyFile(join(root, 'node_modules', 'werift', notice), join(licenseDir, notice));
  }

  execFileSync('tar', ['-czf', archive, '-C', staging, name], { stdio: 'inherit' });
  execFileSync(process.execPath, [join(root, 'scripts', product.check), archive], { stdio: 'inherit' });
  const output = join(releaseDir, basename(archive));
  await rename(archive, output);
  console.log(`已构建 ${output}`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
