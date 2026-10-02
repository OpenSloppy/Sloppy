import { useEffect, useState } from "react";
import { requestPerformanceSnapshot } from "../../shared/api/requestPerformance";

export function RequestPerformanceSection() {
  const [snapshot, setSnapshot] = useState(requestPerformanceSnapshot);
  useEffect(() => {
    const timer = window.setInterval(() => setSnapshot(requestPerformanceSnapshot()), 2000);
    return () => window.clearInterval(timer);
  }, []);
  const durations = snapshot.samples.map((item) => item.durationMs).sort((a, b) => a - b);
  const p95 = durations[Math.max(0, Math.ceil(durations.length * 0.95) - 1)];
  const failed = snapshot.samples.filter((item) => item.outcome === "failed").length;
  const routes = new Map<string, { count: number; total: number; max: number; server: number | null }>();
  for (const sample of snapshot.samples) {
    const key = `${sample.method} ${sample.route}`;
    const entry = routes.get(key) || { count: 0, total: 0, max: 0, server: null };
    entry.count++;
    entry.total += sample.durationMs;
    entry.max = Math.max(entry.max, sample.durationMs);
    entry.server = sample.serverMs;
    routes.set(key, entry);
  }
  const slowest = [...routes.entries()].sort((a, b) => b[1].max - a[1].max).slice(0, 8);
  return <section className="overview-section performance-telemetry-section">
    <div className="overview-section-header"><h2>API performance</h2><span className="overview-section-period">This browser · last {durations.length} requests</span></div>
    <div className="performance-kpi-grid">
      <div><span>In flight / peak</span><strong>{snapshot.active} / {snapshot.peak}</strong></div>
      <div><span>Finished requests</span><strong>{snapshot.completed}</strong></div>
      <div><span>Duplicate reads shared</span><strong>{snapshot.coalesced}</strong></div>
      <div><span>Latency p95</span><strong>{p95 === undefined ? "—" : `${Math.round(p95)} ms`}</strong></div>
      <div><span>Failures in window</span><strong>{failed}</strong></div>
    </div>
    {slowest.length > 0 && <table className="request-performance-table">
      <thead><tr><th>Route</th><th>Requests</th><th>Average</th><th>Max</th><th>Latest server</th></tr></thead>
      <tbody>{slowest.map(([route, stats]) => <tr key={route}><td>{route}</td><td>{stats.count}</td><td>{Math.round(stats.total / stats.count)} ms</td><td>{Math.round(stats.max)} ms</td><td>{stats.server === null ? "—" : `${Math.round(stats.server)} ms`}</td></tr>)}</tbody>
    </table>}
  </section>;
}
