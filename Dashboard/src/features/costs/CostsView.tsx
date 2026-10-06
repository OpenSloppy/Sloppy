import { UsageBreakdownView } from "../usage/UsageBreakdownView";
import type { UsageBreakdown, UsageQuery } from "../usage/usageModel";
import { useEffect, useMemo, useState } from "react";
import {
  COSTS_PERIODS,
  costsPeriodRange,
  formatSpendingUSD,
  normalizeSpendingUsage,
  spendingBuckets,
  type CostsPeriod,
  type SpendingDay
} from "./costsModel";
import "./costs.css";

interface CostsViewProps {
  coreApi: {
    fetchUsageBreakdown: (query?: UsageQuery) => Promise<UsageBreakdown>;
    fetchSemanticDecisionSpending: (query: { from: string; to: string }) => Promise<Record<string, unknown>>;
  };
  onOpenSemanticSettings: () => void;
}

type ChartMetric = "cost" | "requests";

export function CostsView({ coreApi, onOpenSemanticSettings }: CostsViewProps) {
  const [period, setPeriod] = useState<CostsPeriod>("30d");
  const [metric, setMetric] = useState<ChartMetric>("cost");
  const [revision, setRevision] = useState(0);
  const [data, setData] = useState<Record<string, unknown> | null>(null);
  const [asOf, setAsOf] = useState(() => new Date());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    const now = new Date();
    setLoading(true);
    setError("");
    setData(null);
    coreApi.fetchSemanticDecisionSpending(costsPeriodRange(period, now))
      .then((result) => {
        if (cancelled) return;
        setData(result);
        setAsOf(now);
      })
      .catch((cause: unknown) => {
        if (cancelled) return;
        setError(cause instanceof Error ? cause.message : "Spending data is unavailable.");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, [coreApi, period, revision]);

  const total = normalizeSpendingUsage(data?.total);
  const days = useMemo(() => Array.isArray(data?.days)
    ? data.days.filter((item): item is SpendingDay => Boolean(item && typeof item === "object" && typeof item.day === "string"))
    : [], [data]);
  const buckets = useMemo(() => spendingBuckets(days, period, asOf), [days, period, asOf]);
  const maxValue = Math.max(0, ...buckets.map((bucket) => metric === "cost" ? bucket.usage.totalCostUSD : bucket.usage.requestCount));
  const reportedCost = Math.max(0, total.totalCostUSD - total.estimatedCostUSD);
  const averageCost = total.requestCount > 0 ? total.totalCostUSD / total.requestCount : 0;
  const periodLabel = COSTS_PERIODS.find((item) => item.id === period)?.label || "30 days";

  return (
    <main className="costs-page">
      <header className="costs-page-header">
        <div>
          <span className="costs-eyebrow">USAGE / SPENDING</span>
          <h1>Costs</h1>
          <p>Routing routing spend across your Sloppy runtime.</p>
        </div>
        <button type="button" className="costs-refresh" disabled={loading} onClick={() => setRevision((value) => value + 1)}>
          <span className="material-symbols-rounded" aria-hidden="true">refresh</span>
          Refresh
        </button>
      </header>

      <div className="costs-period-row">
        <div className="costs-periods" aria-label="Spending period">
          {COSTS_PERIODS.map((item) => (
            <button key={item.id} type="button" className={period === item.id ? "active" : ""}
              aria-pressed={period === item.id} onClick={() => setPeriod(item.id)}>{item.label}</button>
          ))}
        </div>
        <span className="costs-period-caption">UTC · Last {periodLabel.toLowerCase()}</span>
      </div>

      {error ? <div className="costs-message" role="alert">{error} <button type="button" onClick={() => setRevision((value) => value + 1)}>Retry</button></div> : null}
      {loading && !data ? <p className="costs-message" role="status">Loading Routing spending…</p> : null}

      <UsageBreakdownView coreApi={coreApi} {...costsPeriodRange(period, asOf)} revision={revision} />

      {!error && data ? <>
        <section className="costs-metrics" aria-label="Routing spending summary" aria-busy={loading}>
          <div className="costs-metric costs-metric--primary"><span>Total Routing spend</span><strong>{formatSpendingUSD(total.totalCostUSD)}</strong><small>Provider reported + estimated</small></div>
          <div className="costs-metric"><span>Provider reported</span><strong>{formatSpendingUSD(reportedCost)}</strong><small>Exact cost from the provider</small></div>
          <div className="costs-metric"><span>Estimated</span><strong>{formatSpendingUSD(total.estimatedCostUSD)}</strong><small>Fallback token pricing</small></div>
          <div className="costs-metric"><span>Decisions</span><strong>{total.requestCount.toLocaleString()}</strong><small>{formatSpendingUSD(averageCost)} per decision</small></div>
        </section>

        <section className="costs-chart-section" aria-label="Routing spending over time">
          <div className="costs-section-heading">
            <div><h2>Routing over time</h2><p>Routing decisions recorded in the selected period.</p></div>
            <div className="costs-chart-modes" aria-label="Chart metric">
              <button type="button" className={metric === "cost" ? "active" : ""} aria-pressed={metric === "cost"} onClick={() => setMetric("cost")}>Spend</button>
              <button type="button" className={metric === "requests" ? "active" : ""} aria-pressed={metric === "requests"} onClick={() => setMetric("requests")}>Decisions</button>
            </div>
          </div>
          {total.requestCount === 0 ? <p className="costs-empty">No routing decisions recorded in this period.</p> : null}
          <div className={`costs-chart costs-chart--${period}`} role="img" aria-label={`Routing ${metric === "cost" ? "spend" : "decisions"} by ${period === "12m" ? "month" : period === "90d" ? "week" : "day"}`}>
            {buckets.map((bucket, index) => {
              const value = metric === "cost" ? bucket.usage.totalCostUSD : bucket.usage.requestCount;
              const height = maxValue > 0 && value > 0 ? Math.max(2, (value / maxValue) * 100) : 0;
              const estimatedShare = metric === "cost" && value > 0 ? bucket.usage.estimatedCostUSD / value * 100 : 0;
              const title = `${bucket.label}: ${formatSpendingUSD(bucket.usage.totalCostUSD)} · ${bucket.usage.requestCount} decisions`;
              return <div className="costs-chart-column" key={bucket.key} title={title}>
                <div className="costs-chart-track">
                  {height > 0 ? <div className="costs-chart-bar" style={{ height: `${height}%` }}>
                    {metric === "cost" && estimatedShare > 0 ? <span className="costs-chart-estimated" style={{ height: `${estimatedShare}%` }} /> : null}
                  </div> : null}
                </div>
                <span className="costs-chart-label">{period === "30d" && index % 5 !== 0 && index !== buckets.length - 1 ? "" : bucket.label}</span>
              </div>;
            })}
          </div>
          {metric === "cost" ? <div className="costs-chart-legend"><span><i /> Provider reported</span><span><i /> Estimated</span></div> : null}
        </section>

        <section className="costs-details" aria-label="Routing usage details">
          <div className="costs-section-heading"><div><h2>Period breakdown</h2><p>USD charges and token use from routing decisions.</p></div></div>
          <div className="costs-table-wrap">
            <table className="costs-table">
              <thead><tr><th scope="col">Period</th><th scope="col">Spend</th><th scope="col">Provider reported</th><th scope="col">Estimated</th><th scope="col">Decisions</th><th scope="col">Input tokens</th><th scope="col">Output tokens</th></tr></thead>
              <tbody>{[...buckets].reverse().map((bucket) => <tr key={bucket.key}>
                <th scope="row">{bucket.label}</th>
                <td>{formatSpendingUSD(bucket.usage.totalCostUSD)}</td>
                <td>{formatSpendingUSD(Math.max(0, bucket.usage.totalCostUSD - bucket.usage.estimatedCostUSD))}</td>
                <td>{formatSpendingUSD(bucket.usage.estimatedCostUSD)}</td>
                <td>{bucket.usage.requestCount.toLocaleString()}</td>
                <td>{bucket.usage.inputTokens.toLocaleString()}</td>
                <td>{bucket.usage.outputTokens.toLocaleString()}</td>
              </tr>)}</tbody>
            </table>
          </div>
        </section>

        <aside className="costs-footnote">
          <div><strong>What is included</strong><p>Semantic decision requests from Jev and Laya. Self-hosted Laya calls are recorded at $0; hosting costs are not included. Historical calls made before usage recording cannot appear in period charts. Executor model charges are not yet recorded per call.</p></div>
          <button type="button" onClick={onOpenSemanticSettings}>Semantic decision settings <span className="material-symbols-rounded" aria-hidden="true">arrow_forward</span></button>
        </aside>
      </> : null}
    </main>
  );
}
