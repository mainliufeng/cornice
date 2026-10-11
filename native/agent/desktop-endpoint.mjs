import { createHash } from 'node:crypto';
import { isAbsolute, join } from 'node:path';

// Same UTF-8 identity and Linux local-socket bound as DesktopEndpoint.hpp.
// Runtime data/logs retain the original compositor instance directory.
export function desktopSocketPath(runtime, instance) {
  if (typeof instance !== 'string' || instance === '.' || instance === '..' || !/^[A-Za-z0-9_.-]{1,128}$/.test(instance))
    throw new Error('Explicit compositor instance required');
  if (typeof runtime !== 'string' || !runtime || !isAbsolute(runtime) || runtime.includes('\0'))
    throw new Error('Absolute XDG_RUNTIME_DIR required');
  const identity = createHash('sha256').update(instance, 'utf8').digest('hex').slice(0, 32);
  const socket = join(runtime, 'cornice', 'ipc-' + identity, 'desktop.sock');
  if (Buffer.byteLength(socket, 'utf8') > 107)
    throw new Error(`Local socket path exceeds 107 encoded bytes (${Buffer.byteLength(socket, 'utf8')}); shorten XDG_RUNTIME_DIR`);
  return socket;
}
