import { useEffect, useMemo, useState } from 'react'
import Layout from '../components/Layout'
import { supabase } from '../lib/supabaseClient'
import ExportButton from '../components/ExportButton'

const PACKAGING_STAGES = [
  { value: 'raw_unpacked', label: 'Raw bottles (unpacked)' },
  { value: 'bottle_plastic_wrap', label: 'Bottle plastic wrap' },
  { value: 'bottle_bubble_wrap', label: 'Bottle bubble wrap' },
  { value: 'box_packed', label: 'Box packed' },
  { value: 'box_bubble_wrap', label: 'Box bubble wrap' },
  { value: 'box_labeled', label: 'Box labeled' },
  { value: 'dispatched', label: 'Dispatched' },
]

export default function ClientDashboard() {
  const [stock, setStock] = useState([])
  const [loadingStock, setLoadingStock] = useState(true)

  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().slice(0, 10))
  const [dispatchSummary, setDispatchSummary] = useState([])
  const [loadingDispatch, setLoadingDispatch] = useState(true)

  // Today's date shows live current stock. Any past date shows that date's
  // frozen historical balance (via stock_balance_as_of), so picking an
  // earlier date doesn't retroactively show stock that only arrived later —
  // same reasoning as the Operation dashboard's Packaging Tally.
  useEffect(() => {
    async function loadStock() {
      setLoadingStock(true)
      const { data: skuRows } = await supabase
        .from('skus')
        .select('id, sku_code, size_ml, products(name)')
        .eq('is_active', true)
        .order('id')

      const isToday = selectedDate === new Date().toISOString().slice(0, 10)
      let quantityBySku = {}
      if (isToday) {
        const { data } = await supabase.from('stock_levels').select('sku_id, quantity')
        for (const r of data || []) quantityBySku[r.sku_id] = r.quantity
      } else {
        const { data } = await supabase.rpc('stock_balance_as_of', { p_date: selectedDate })
        for (const r of data || []) quantityBySku[r.sku_id] = r.quantity
      }

      setStock(
        (skuRows || []).map((s) => ({
          sku_id: s.id,
          quantity: quantityBySku[s.id] ?? 0,
          skus: { sku_code: s.sku_code, size_ml: s.size_ml, products: s.products },
        }))
      )
      setLoadingStock(false)
    }
    loadStock()
  }, [selectedDate])

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

      <ClientPackagingTally />
      <ClientOrderLog />
      <ClientRtoLog />
      <ClientLeakLog />
    </Layout>
  )
}

function ClientPackagingTally() {
  const [logDate, setLogDate] = useState(new Date().toISOString().slice(0, 10))
  const [skus, setSkus] = useState([])
  const [totals, setTotals] = useState([])
  const [stockBySku, setStockBySku] = useState({})
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    async function loadSkus() {
      const { data } = await supabase.from('skus').select('id, sku_code').eq('is_active', true).order('sku_code')
      setSkus(data || [])
    }
    loadSkus()
  }, [])

  useEffect(() => {
    async function load() {
      setLoading(true)
      const { data } = await supabase
        .from('packaging_daily_totals')
        .select('sku_id, stage, total_quantity')
        .eq('log_date', logDate)
      setTotals(data || [])

      const isToday = logDate === new Date().toISOString().slice(0, 10)
      if (isToday) {
        const { data: live } = await supabase.from('stock_levels').select('sku_id, quantity')
        const map = {}
        for (const r of live || []) map[r.sku_id] = r.quantity
        setStockBySku(map)
      } else {
        const { data: bal } = await supabase.rpc('stock_balance_as_of', { p_date: logDate })
        const map = {}
        for (const r of bal || []) map[r.sku_id] = r.quantity
        setStockBySku(map)
      }
      setLoading(false)
    }
    load()
  }, [logDate])

  function currentTotal(skuId, stage) {
    return totals.find((t) => t.sku_id === skuId && t.stage === stage)?.total_quantity || 0
  }

  function rowTotal(skuId) {
    return PACKAGING_STAGES.filter((s) => s.value !== 'dispatched').reduce(
      (sum, s) => sum + currentTotal(skuId, s.value),
      0
    )
  }

  return (
    <div className="panel">
      <h2>Daily Packaging Tally</h2>
      <p className="hint">Read-only view of the warehouse's packaging pipeline. "Total" is everything still in the warehouse (dispatched excluded).</p>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <input type="date" value={logDate} onChange={(e) => setLogDate(e.target.value)} />
        <ExportButton
          filename={`packaging-tally-${logDate}`}
          rows={skus.map((s) => ({
            sku: s.sku_code,
            ...Object.fromEntries(PACKAGING_STAGES.map((st) => [st.value, currentTotal(s.id, st.value)])),
            total: rowTotal(s.id),
            warehouse_stock: stockBySku[s.id] ?? 0,
          }))}
          columns={[
            { key: 'sku', label: 'SKU' },
            ...PACKAGING_STAGES.map((st) => ({ key: st.value, label: st.label })),
            { key: 'total', label: 'Total' },
            { key: 'warehouse_stock', label: 'Warehouse Stock' },
          ]}
        />
      </div>
      {loading ? (
        <p>Loading…</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>SKU</th>
              {PACKAGING_STAGES.map((s) => (
                <th key={s.value}>{s.label}</th>
              ))}
              <th>Total</th>
              <th>Warehouse Stock</th>
            </tr>
          </thead>
          <tbody>
            {skus.map((s) => {
              const total = rowTotal(s.id)
              const stock = stockBySku[s.id] ?? 0
              return (
                <tr key={s.id}>
                  <td>{s.sku_code}</td>
                  {PACKAGING_STAGES.map((st) => (
                    <td key={st.value}>{currentTotal(s.id, st.value)}</td>
                  ))}
                  <td><strong>{total}</strong></td>
                  <td style={{ color: total === stock ? 'green' : 'crimson' }}>{stock}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}
    </div>
  )
}

function ClientOrderLog() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [dateFilter, setDateFilter] = useState('')

  useEffect(() => {
    async function load() {
      setLoading(true)
      let query = supabase
        .from('order_log_summary')
        .select('batch_key, batch_created_at, order_date, courier, product_name, sku_code, size_ml, order_count, bottle_count, total_ml')
      if (dateFilter) query = query.eq('order_date', dateFilter)
      const { data } = await query.order('batch_created_at', { ascending: false })
      setRows(data || [])
      setLoading(false)
    }
    load()
  }, [dateFilter])

  const grouped = []
  for (const r of rows) {
    let group = grouped.find((g) => g.batch_key === r.batch_key)
    if (!group) {
      group = {
        batch_key: r.batch_key,
        order_date: r.order_date,
        batch_created_at: r.batch_created_at,
        courier: r.courier,
        product_name: r.product_name,
        lines: [],
        totalOrders: 0,
        totalUnits: 0,
        totalMl: 0,
      }
      grouped.push(group)
    }
    group.lines.push(r)
    group.totalOrders += r.order_count
    group.totalUnits += r.bottle_count
    group.totalMl += r.total_ml
  }

  return (
    <div className="panel">
      <h2>Order Log</h2>
      <p className="hint">Product-wise, date-wise summary of every order created.</p>
      <div className="inline-form" style={{ marginBottom: 16 }}>
        <input type="date" value={dateFilter} onChange={(e) => setDateFilter(e.target.value)} />
        {dateFilter && <button type="button" onClick={() => setDateFilter('')}>Clear filter</button>}
      </div>
      {loading ? (
        <p>Loading…</p>
      ) : grouped.length === 0 ? (
        <p className="hint">No orders found{dateFilter ? ` for ${dateFilter}` : ''}.</p>
      ) : (
        <>
          <div className="inline-form" style={{ marginBottom: 8 }}>
            <ExportButton
              filename={`order-log${dateFilter ? '-' + dateFilter : ''}`}
              rows={grouped.map((g) => ({
                date: g.order_date,
                time: g.batch_created_at ? new Date(g.batch_created_at).toLocaleTimeString() : '',
                product: g.product_name,
                bottle_mix: g.lines.map((l) => `${l.sku_code} x ${l.bottle_count}`).join('; '),
                orders: g.totalOrders,
                units: g.totalUnits,
                total_ml: g.totalMl,
                courier: g.courier || '',
              }))}
              columns={[
                { key: 'date', label: 'Date' },
                { key: 'time', label: 'Time' },
                { key: 'product', label: 'Product' },
                { key: 'bottle_mix', label: 'Bottle Mix' },
                { key: 'orders', label: 'Orders' },
                { key: 'units', label: 'Units' },
                { key: 'total_ml', label: 'Total ml' },
                { key: 'courier', label: 'Courier' },
              ]}
            />
          </div>
          <table>
            <thead>
              <tr>
                <th>Date</th>
                <th>Time</th>
                <th>Product</th>
                <th>Bottle mix</th>
                <th>Orders</th>
                <th>Units</th>
                <th>Total ml</th>
                <th>Courier</th>
              </tr>
            </thead>
            <tbody>
              {grouped.map((g) => (
                <tr key={g.batch_key}>
                  <td>{g.order_date}</td>
                  <td>{g.batch_created_at ? new Date(g.batch_created_at).toLocaleTimeString() : ''}</td>
                  <td>{g.product_name}</td>
                  <td>{g.lines.map((l) => `${l.sku_code} × ${l.bottle_count}`).join(', ')}</td>
                  <td>{g.totalOrders}</td>
                  <td>{g.totalUnits}</td>
                  <td>{g.totalMl.toLocaleString()}</td>
                  <td>{g.courier || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}

function ClientRtoLog() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [dateFilter, setDateFilter] = useState('')

  useEffect(() => {
    async function load() {
      setLoading(true)
      let query = supabase
        .from('rto_returns')
        .select('id, quantity_returned, return_date, note, skus(sku_code)')
      if (dateFilter) query = query.eq('return_date', dateFilter)
      const { data } = await query.order('return_date', { ascending: false })
      setRows(data || [])
      setLoading(false)
    }
    load()
  }, [dateFilter])

  return (
    <div className="panel">
      <h2>RTO (Return to Origin)</h2>
      <p className="hint">Dispatched orders that came back to the warehouse.</p>
      <div className="inline-form" style={{ marginBottom: 16 }}>
        <input type="date" value={dateFilter} onChange={(e) => setDateFilter(e.target.value)} />
        {dateFilter && <button type="button" onClick={() => setDateFilter('')}>Clear filter</button>}
      </div>
      {loading ? (
        <p>Loading…</p>
      ) : rows.length === 0 ? (
        <p className="hint">No RTO entries found{dateFilter ? ` for ${dateFilter}` : ''}.</p>
      ) : (
        <>
          <div className="inline-form" style={{ marginBottom: 8 }}>
            <ExportButton
              filename={`rto-log${dateFilter ? '-' + dateFilter : ''}`}
              rows={rows.map((r) => ({
                date: r.return_date,
                sku: r.skus?.sku_code,
                quantity: r.quantity_returned,
                note: r.note,
              }))}
              columns={[
                { key: 'date', label: 'Date' },
                { key: 'sku', label: 'SKU' },
                { key: 'quantity', label: 'Quantity' },
                { key: 'note', label: 'Note' },
              ]}
            />
          </div>
          <table>
            <thead>
              <tr><th>Date</th><th>SKU</th><th>Quantity</th><th>Note</th></tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>{r.return_date}</td>
                  <td>{r.skus?.sku_code}</td>
                  <td>{r.quantity_returned}</td>
                  <td>{r.note}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}

function ClientLeakLog() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [dateFilter, setDateFilter] = useState('')

  useEffect(() => {
    async function load() {
      setLoading(true)
      let query = supabase
        .from('leak_entries')
        .select('id, quantity, leak_date, note, skus(sku_code)')
      if (dateFilter) query = query.eq('leak_date', dateFilter)
      const { data } = await query.order('leak_date', { ascending: false })
      setRows(data || [])
      setLoading(false)
    }
    load()
  }, [dateFilter])

  return (
    <div className="panel">
      <h2>Leak / Damage</h2>
      <p className="hint">Bottles that leaked or got damaged during packaging.</p>
      <div className="inline-form" style={{ marginBottom: 16 }}>
        <input type="date" value={dateFilter} onChange={(e) => setDateFilter(e.target.value)} />
        {dateFilter && <button type="button" onClick={() => setDateFilter('')}>Clear filter</button>}
      </div>
      {loading ? (
        <p>Loading…</p>
      ) : rows.length === 0 ? (
        <p className="hint">No leak entries found{dateFilter ? ` for ${dateFilter}` : ''}.</p>
      ) : (
        <>
          <div className="inline-form" style={{ marginBottom: 8 }}>
            <ExportButton
              filename={`leak-log${dateFilter ? '-' + dateFilter : ''}`}
              rows={rows.map((r) => ({
                date: r.leak_date,
                sku: r.skus?.sku_code,
                quantity: r.quantity,
                note: r.note,
              }))}
              columns={[
                { key: 'date', label: 'Date' },
                { key: 'sku', label: 'SKU' },
                { key: 'quantity', label: 'Quantity' },
                { key: 'note', label: 'Note' },
              ]}
            />
          </div>
          <table>
            <thead>
              <tr><th>Date</th><th>SKU</th><th>Quantity</th><th>Note</th></tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>{r.leak_date}</td>
                  <td>{r.skus?.sku_code}</td>
                  <td>{r.quantity}</td>
                  <td>{r.note}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
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
