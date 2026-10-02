export interface RequestSample {
  route: string;
  method: string;
  status: number;
  durationMs: number;
  serverMs: number | null;
  outcome: "completed" | "failed" | "aborted";
}

const samples: RequestSample[] = [];
let active = 0;
let peak = 0;
let completed = 0;
let coalesced = 0;
const pendingReads = new Map<string, Promise<unknown>>();

export function requestPerformanceSnapshot() {
  return { active, peak, completed, coalesced, samples: [...samples] };
}

/** Share only in-flight reads, with an exact destination/credential key. No response cache. */
export function coalesceRead<T>(key: string | null, perform: () => Promise<T>): Promise<T> {
  const pending = key ? pendingReads.get(key) : undefined;
  if (pending) {
    coalesced++;
    return pending as Promise<T>;
  }
  const result = perform();
  if (key) {
    pendingReads.set(key, result);
    const cleanup = () => { if (pendingReads.get(key) === result) pendingReads.delete(key); };
    result.then(cleanup, cleanup);
  }
  return result;
}

export function beginRequest(method: string) {
  const started = performance.now();
  active++;
  peak = Math.max(peak, active);
  let finished = false;
  return (response: Response | null, outcome: RequestSample["outcome"]) => {
    if (finished) return;
    finished = true;
    active--;
    completed++;
    const serverTiming = response?.headers.get("server-timing")?.match(/(?:^|,)\s*core;dur=([\d.]+)/);
    samples.push({
      // Use the server's route template, never URLs, query strings, credentials or bodies.
      route: response?.headers.get("x-sloppy-route") || "unmatched",
      method,
      status: response?.status ?? 0,
      durationMs: performance.now() - started,
      serverMs: serverTiming ? Number(serverTiming[1]) : null,
      outcome
    });
    if (samples.length > 240) samples.shift();
  };
}
