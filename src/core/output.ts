const CHUNK = 16 * 1024;

/**
 * Write to stdout without losing the tail.
 *
 * When stdout is a pipe (MCP clients, agents, `| jq`, the macOS app), Bun can
 * hand fd 1 to the kernel non-blocking: a single large write is only partially
 * accepted (the pipe buffer holds 64 KiB) and the remainder is dropped when the
 * process exits. `ram --json` lists every process, hundreds of KB, so its tail
 * vanished and consumers got invalid JSON. Write fixed-size chunks and wait for
 * each to be accepted before queueing the next.
 */
export async function writeOut(text: string): Promise<void> {
  const buf = Buffer.from(text);
  for (let at = 0; at < buf.length; at += CHUNK) {
    await writeChunk(buf.subarray(at, at + CHUNK));
  }
}

function writeChunk(chunk: Buffer): Promise<void> {
  return new Promise((resolve, reject) => {
    process.stdout.write(chunk, (err) => (err ? reject(err) : resolve()));
  });
}
