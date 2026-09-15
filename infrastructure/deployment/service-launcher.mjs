// Start services with OS plumbing only. Application configuration belongs exclusively
// to the current env file, not PM2's cached environment from an earlier deployment.
import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function serviceEnvironment(source) {
  const env = {};
  for (const key of ['PATH','HOME','USER','LOGNAME','SHELL','TMPDIR','TEMP','TMP','LANG','LC_ALL','TZ','SYSTEMROOT','WINDIR']) {
    if (source[key] !== undefined) env[key] = source[key];
  }
  return env;
}
export function launchService(name, { root = resolve(dirname(fileURLToPath(import.meta.url)), '../..'), envFile = resolve(root, '.env') } = {}) {
  const entry = {
    api: 'backend/api/dist/index.js', websocket: 'backend/websocket/dist/index.js',
    workers: 'backend/workers/dist/index.js', games: 'backend/games/dist/index.js',
    migrate: 'infrastructure/deployment/migrate.mjs',
  }[name];
  if (!entry) throw new Error('Unknown service');
  const child = spawn(process.execPath, [`--env-file=${envFile}`, resolve(root, entry)], {
    cwd: root, env: serviceEnvironment(process.env), stdio: 'inherit', shell: false,
  });
  for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => child.kill(signal));
  child.on('error', () => { console.error('Service could not start.'); process.exitCode = 1; });
  child.on('exit', (code, signal) => { process.exitCode = code ?? (signal ? 1 : 0); });
  return child;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  launchService(process.argv[2], {
    ...(process.env.VOIID_APP_DIR ? {root:process.env.VOIID_APP_DIR} : {}),
    ...(process.env.VOIID_ENV_FILE ? {envFile:process.env.VOIID_ENV_FILE} : {}),
  });
}
