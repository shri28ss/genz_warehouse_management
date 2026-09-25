import { useEffect, useMemo, useState } from 'react'
import Layout from '../components/Layout'
import { supabase } from '../lib/supabaseClient'
import ExportButton from '../components/ExportButton'

export default function ClientDashboard() {
  const [stock, setStock] = useState([])
  const [loadingStock, setLoadingStock] = useState(true)

  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().slice(0, 10))
  const [dispatchSummary, setDispatchSummary] = useState([])
  const [loadingDispatch, setLoadingDispatch] = useState(true)

  useEffect(() => {
    async function loadStock() {
      setLoadingStock(true)
      const { data } = await supabase
        .from('stock_levels')
        .select('sku_id, quantity, skus(sku_code, size_ml, products(name))')
        .order('sku_id')
      setStock(data || [])
      setLoadingStock(false)
    }
    loadStock()
  }, [])

  useEffect(() => {
    async function loadDispatch() {
      setLoadingDispatch(true)
      const { data } = await supabase
        .from('scan_fail_summary')
        .select('sku_code, product_name, total_orders, total_units')
        .eq('order_date', selectedDate)
      setDispatchSummary(data || [])
      setLoadingDispatch(false)
    }
    loadDispatch()
  }, [selectedDate])

  const totalStock = useMemo(() => stock.reduce((sum, r) => sum + r.quantity, 0), [stock])
  const totalMl = useMemo(
    () => stock.reduce((sum, r) => sum + r.quantity * (r.skus?.size_ml || 0), 0),
    [stock]
  )
  const totalLitres = totalMl / 1000
  const totalDispatchedToday = useMemo(
    () => dispatchSummary.reduce((sum, r) => sum + r.total_units, 0),
    [dispatchSummary]
  )

  return (
    <Layout title="Client Dashboard">
      <div className="inline-form" style={{ marginBottom: 16 }}>
        <label htmlFor="client-date-filter" style={{ fontSize: '0.9rem', color: '#6b7280' }}>
          Viewing data for
        </label>
        <input
          id="client-date-filter"
          type="date"
          value={selectedDate}
          onChange={(e) => setSelectedDate(e.target.value)}
        />
      </div>

      <div className="stat-tile-row">
        <div className="stat-tile">
          <span className="stat-tile-label">Total stock on hand</span>
          <span className="stat-tile-value">{totalStock.toLocaleString()}</span>
        </div>
        <div className="stat-tile">
          <span className="stat-tile-label">Total volume available</span>
          <span className="stat-tile-value">{totalLitres.toLocaleString(undefined, { maximumFractionDigits: 2 })} L</span>
        </div>
        <div className="stat-tile">
          <span className="stat-tile-label">Total volume available (ml)</span>
          <span className="stat-tile-value">{totalMl.toLocaleString()} ml</span>
        </div>
        <div className="stat-tile">
          <span className="stat-tile-label">Units dispatched — {selectedDate}</span>
          <span className="stat-tile-value">{totalDispatchedToday.toLocaleString()}</span>
        </div>
        <div className="stat-tile">
          <span className="stat-tile-label">SKUs tracked</span>
          <span className="stat-tile-value">{stock.length}</span>
        </div>
      </div>

      <div className="panel">
        <h2>Stock by Product</h2>
        {loadingStock ? <p>Loading…</p> : <StockBarChart stock={stock} />}
      </div>

      <div className="panel">
        <h2>Available Stock</h2>
        {loadingStock ? (
          <p>Loading…</p>
        ) : (
          <>
            <div className="inline-form" style={{ marginBottom: 8 }}>
              <ExportButton
                filename="available-stock"
                rows={stock.map((r) => ({
                  product: r.skus?.products?.name,
                  size_ml: r.skus?.size_ml,
                  quantity: r.quantity,
                  total_ml: r.quantity * (r.skus?.size_ml || 0),
                  total_l: (r.quantity * (r.skus?.size_ml || 0)) / 1000,
                }))}
                columns={[
                  { key: 'product', label: 'Product' },
                  { key: 'size_ml', label: 'Size (ml)' },
                  { key: 'quantity', label: 'Available Quantity' },
                  { key: 'total_ml', label: 'Total Volume (ml)' },
                  { key: 'total_l', label: 'Total Volume (L)' },
                ]}
              />
            </div>
            <table>
            <thead>
              <tr>
                <th>Product</th>
                <th>Size (ml)</th>
                <th>Available quantity</th>
                <th>Total volume (ml)</th>
                <th>Total volume (L)</th>
              </tr>
            </thead>
            <tbody>
              {stock.map((r) => {
                const rowMl = r.quantity * (r.skus?.size_ml || 0)
                return (
                  <tr key={r.sku_id}>
                    <td>{r.skus?.products?.name}</td>
                    <td>{r.skus?.size_ml}</td>
                    <td>{r.quantity}</td>
                    <td>{rowMl.toLocaleString()}</td>
                    <td>{(rowMl / 1000).toLocaleString(undefined, { maximumFractionDigits: 2 })}</td>
                  </tr>
                )
              })}
            </tbody>
            </table>
          </>
        )}
      </div>

      <div className="panel">
        <h2>Dispatch Overview — {selectedDate}</h2>
        {loadingDispatch ? (
          <p>Loading…</p>
        ) : dispatchSummary.length === 0 ? (
          <p className="hint">No dispatches recorded for {selectedDate}.</p>
        ) : (
          <>
            <div className="inline-form" style={{ marginBottom: 8 }}>
              <ExportButton
                filename={`dispatch-overview-${selectedDate}`}
                rows={dispatchSummary.map((row) => ({
                  product: row.product_name,
                  sku: row.sku_code,
                  orders_dispatched: row.total_orders,
                  units_dispatched: row.total_units,
                }))}
                columns={[
                  { key: 'product', label: 'Product' },
                  { key: 'sku', label: 'SKU' },
                  { key: 'orders_dispatched', label: 'Orders Dispatched' },
                  { key: 'units_dispatched', label: 'Units Dispatched' },
                ]}
              />
            </div>
            <table>
            <thead>
              <tr><th>Product</th><th>SKU</th><th>Orders dispatched</th><th>Units dispatched</th></tr>
            </thead>
            <tbody>
              {dispatchSummary.map((row) => (
                <tr key={row.sku_code}>
                  <td>{row.product_name}</td>
                  <td>{row.sku_code}</td>
                  <td>{row.total_orders}</td>
                  <td>{row.total_units}</td>
                </tr>
              ))}
            </tbody>
            </table>
          </>
        )}
      </div>
    </Layout>
  )
}

function StockBarChart({ stock }) {
  const [hoverId, setHoverId] = useState(null)

  if (stock.length === 0) return <p className="hint">No stock data yet.</p>

  const maxQty = Math.max(...stock.map((r) => r.quantity), 1)
  const chartWidth = 640
  const barHeight = 24
  const rowGap = 16
  const labelWidth = 140
  const plotWidth = chartWidth - labelWidth - 60
  const chartHeight = stock.length * (barHeight + rowGap)

  return (
    <div className="viz-root" style={{ overflowX: 'auto' }}>
      <svg
        viewBox={`0 0 ${chartWidth} ${chartHeight + 10}`}
        width="100%"
        height={chartHeight + 10}
        role="img"
        aria-label="Stock quantity by SKU"
      >
        {stock.map((r, i) => {
          const y = i * (barHeight + rowGap)
          const barW = Math.max((r.quantity / maxQty) * plotWidth, 2)
          const isHover = hoverId === r.sku_id
          const label = r.skus?.sku_code || ''
          return (
            <g key={r.sku_id}>
              <text
                x={labelWidth - 8}
                y={y + barHeight / 2}
                textAnchor="end"
                dominantBaseline="middle"
                className="viz-axis-label"
              >
                {label}
              </text>
              <rect
                x={labelWidth}
                y={y}
                width={plotWidth}
                height={barHeight}
                fill="var(--viz-track)"
                rx={4}
              />
              <rect
                x={labelWidth}
                y={y}
                width={barW}
                height={barHeight}
                rx={4}
                fill={isHover ? 'var(--viz-series-hover)' : 'var(--viz-series)'}
                onMouseEnter={() => setHoverId(r.sku_id)}
                onMouseLeave={() => setHoverId(null)}
                style={{ cursor: 'pointer' }}
              />
              <text
                x={labelWidth + barW + 8}
                y={y + barHeight / 2}
                dominantBaseline="middle"
                className="viz-value-label"
              >
                {r.quantity}
              </text>
            </g>
          )
        })}
      </svg>
      <style>{`
        .viz-root {
          --viz-track: #e1e0d9;
          --viz-series: #2a78d6;
          --viz-series-hover: #1c5cab;
          --viz-text-secondary: #52514e;
          --viz-text-muted: #898781;
        }
        @media (prefers-color-scheme: dark) {
          :root:not([data-theme="light"]) .viz-root {
            --viz-track: #2c2c2a;
            --viz-series: #3987e5;
            --viz-series-hover: #86b6ef;
            --viz-text-secondary: #c3c2b7;
            --viz-text-muted: #898781;
          }
        }
        :root[data-theme="dark"] .viz-root {
          --viz-track: #2c2c2a;
          --viz-series: #3987e5;
          --viz-series-hover: #86b6ef;
          --viz-text-secondary: #c3c2b7;
          --viz-text-muted: #898781;
        }
        .viz-axis-label {
          font-size: 12px;
          fill: var(--viz-text-secondary);
        }
        .viz-value-label {
          font-size: 12px;
          font-weight: 600;
          fill: var(--viz-text-secondary);
        }
      `}</style>
    </div>
  )
}
