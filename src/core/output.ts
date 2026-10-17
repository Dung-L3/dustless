const CHUNK = 16 * 1024;

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