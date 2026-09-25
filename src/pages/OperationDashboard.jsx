import { useEffect, useState } from 'react'
import Layout from '../components/Layout'
import { supabase } from '../lib/supabaseClient'
import { useAuth } from '../context/AuthContext'
import ExportButton from '../components/ExportButton'

export default function OperationDashboard() {
  const { profile } = useAuth()
  const [tab, setTab] = useState('bulk-order')

  return (
    <Layout title="Warehouse Operations">
      <StockWidgets />
      <nav className="tabs">
        <button className={tab === 'bulk-order' ? 'active' : ''} onClick={() => setTab('bulk-order')}>
          Bulk Order
        </button>
        <button className={tab === 'manual-order' ? 'active' : ''} onClick={() => setTab('manual-order')}>
          Manual Entry
        </button>
        <button className={tab === 'packaging' ? 'active' : ''} onClick={() => setTab('packaging')}>
          Daily Packaging Tally
        </button>
        <button className={tab === 'dispatch' ? 'active' : ''} onClick={() => setTab('dispatch')}>
          Dispatch
        </button>
        <button className={tab === 'rto' ? 'active' : ''} onClick={() => setTab('rto')}>
          RTO
        </button>
        <button className={tab === 'order-log' ? 'active' : ''} onClick={() => setTab('order-log')}>
          Order Log
        </button>
        <button className={tab === 'closure-log' ? 'active' : ''} onClick={() => setTab('closure-log')}>
          Closure Log
        </button>
        <button className={tab === 'stock' ? 'active' : ''} onClick={() => setTab('stock')}>
          Stock Levels
        </button>
        <button className={tab === 'raw-stock-history' ? 'active' : ''} onClick={() => setTab('raw-stock-history')}>
          Raw Stock Inward
        </button>
      </nav>

      {tab === 'bulk-order' && <BulkOrderPanel currentUserId={profile.id} />}
      {tab === 'manual-order' && <ManualOrderPanel currentUserId={profile.id} />}
      {tab === 'packaging' && <PackagingPanel currentUserId={profile.id} />}
      {tab === 'dispatch' && <DispatchPanel currentUserId={profile.id} />}
      {tab === 'rto' && <RtoPanel currentUserId={profile.id} />}
      {tab === 'order-log' && <OrderLogPanel />}
      {tab === 'closure-log' && <ClosureLogPanel />}
      {tab === 'stock' && <StockPanel />}
      {tab === 'raw-stock-history' && <RawStockHistoryPanel />}
    </Layout>
  )
}

function StockWidgets() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    async function load() {
      setLoading(true)
      const { data } = await supabase
        .from('stock_levels')
        .select('sku_id, quantity, skus(sku_code)')
        .order('sku_id')
      setRows(data || [])
      setLoading(false)
    }
    load()

    // Keep widgets fresh as orders/dispatch/RTO/etc change stock elsewhere in the app
    const channel = supabase
      .channel('stock_widgets_stock_levels')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_levels' }, load)
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [])

  if (loading) return null

  const totalBottles = rows.reduce((sum, r) => sum + r.quantity, 0)

  return (
    <div className="widget-row" style={{ marginBottom: 20 }}>
      <div className="widget-card">
        <span className="widget-value">{totalBottles}</span>
        <span className="widget-label">Total bottles/tins in stock</span>
      </div>
      {rows.map((r) => (
        <div className="widget-card" key={r.sku_id}>
          <span className="widget-value">{r.quantity}</span>
          <span className="widget-label">{r.skus?.sku_code}</span>
        </div>
      ))}
    </div>
  )
}

const PACKAGING_STAGES = [
  { value: 'raw_unpacked', label: 'Raw bottles (unpacked)' },
  { value: 'bottle_plastic_wrap', label: 'Bottle plastic wrap' },
  { value: 'bottle_bubble_wrap', label: 'Bottle bubble wrap' },
  { value: 'box_packed', label: 'Box packed' },
  { value: 'box_bubble_wrap', label: 'Box bubble wrap' },
  { value: 'box_labeled', label: 'Box labeled' },
  { value: 'dispatched', label: 'Dispatched' },
]

function BulkOrderPanel({ currentUserId }) {
  const [skus, setSkus] = useState([])
  const [products, setProducts] = useState([])
  const [loading, setLoading] = useState(true)

  const [orderedProductId, setOrderedProductId] = useState('') // "order variety": which product was ordered
  const [orderedLitres, setOrderedLitres] = useState('') // volume ordered, in litres (supports 3L, 4L, 7L, etc.)
  const [orderDate, setOrderDate] = useState(new Date().toISOString().slice(0, 10))
  const [bulkCount, setBulkCount] = useState('')
  const [bulkMix, setBulkMix] = useState([]) // [{ sku_id, quantity }] — how it's actually packed
  const [bulkMixDraft, setBulkMixDraft] = useState({ sku_id: '', quantity: '' })
  const [bulkSubmitting, setBulkSubmitting] = useState(false)
  const [lastResult, setLastResult] = useState(null)

  useEffect(() => {
    async function load() {
      setLoading(true)
      const [{ data: s }, { data: p }] = await Promise.all([
        supabase
          .from('skus')
          .select('id, sku_code, size_ml, product_id, products(name)')
          .eq('is_active', true)
          .order('sku_code'),
        supabase.from('products').select('id, name').order('name'),
      ])
      setSkus(s || [])
      setProducts(p || [])
      setLoading(false)
    }
    load()
  }, [])

  const requestedMl = orderedLitres ? Math.round(Number(orderedLitres) * 1000) : 0

  // Only offer bottle sizes from the ordered product
  const packOptions = orderedProductId ? skus.filter((s) => s.product_id === orderedProductId) : []

  const bulkMixMl = bulkMix.reduce((sum, line) => {
    const sku = skus.find((s) => s.id === line.sku_id)
    return sum + (sku ? sku.size_ml * line.quantity : 0)
  }, 0)
  const mixMatches = requestedMl > 0 && bulkMixMl === requestedMl && bulkMix.length > 0

  function selectOrderedProduct(id) {
    setOrderedProductId(id)
    setBulkMix([]) // mix must be rebuilt for the newly chosen product
  }

  function addBulkMixLine() {
    if (!bulkMixDraft.sku_id || !bulkMixDraft.quantity) return
    const qty = Number(bulkMixDraft.quantity)
    setBulkMix((prev) => {
      const existing = prev.find((l) => l.sku_id === bulkMixDraft.sku_id)
      if (existing) {
        return prev.map((l) => (l.sku_id === bulkMixDraft.sku_id ? { ...l, quantity: l.quantity + qty } : l))
      }
      return [...prev, { sku_id: bulkMixDraft.sku_id, quantity: qty }]
    })
    setBulkMixDraft({ sku_id: '', quantity: '' })
  }

  function removeBulkMixLine(sku_id) {
    setBulkMix((prev) => prev.filter((l) => l.sku_id !== sku_id))
  }

  async function submitBulkFulfill(e) {
    e.preventDefault()
    const count = Number(bulkCount)
    if (!count || count < 1 || bulkMix.length === 0) return

    setBulkSubmitting(true)
    setLastResult(null)
    try {
      const productName = products.find((p) => p.id === orderedProductId)?.name
      const { error } = await supabase.rpc('bulk_fulfill_orders', {
        p_order_code_prefix: productName?.replace(/\s+/g, '-').toUpperCase() || 'BULK',
        p_count: count,
        p_mix: bulkMix.map((l) => ({ sku_id: l.sku_id, quantity: l.quantity })),
        p_created_by: currentUserId,
        p_order_date: orderDate,
      })
      if (error) throw error

      setLastResult({ ok: true, message: `Created & fulfilled ${count} orders.` })
      setBulkCount('')
      setBulkMix([])
      setOrderedProductId('')
      setOrderedLitres('')
    } catch (err) {
      setLastResult({ ok: false, message: err.message })
    } finally {
      setBulkSubmitting(false)
    }
  }

  if (loading) return <p>Loading…</p>

  return (
    <div className="panel">
      <h2>Bulk Order</h2>
      <p className="hint">
        For orders that all use the same bottle-mix — e.g. 300 orders, each Sahyadri 1L, each packed as 2×Sahyadri-500.
      </p>

      <div className="sub-panel" style={{ marginTop: 8 }}>
        <strong>1. What was ordered</strong>
        <div className="inline-form">
          <select value={orderedProductId} onChange={(e) => selectOrderedProduct(e.target.value)}>
            <option value="">Select product</option>
            {products.map((p) => (
              <option key={p.id} value={p.id}>{p.name}</option>
            ))}
          </select>
          <input
            type="number"
            step="0.5"
            placeholder="Volume (litres) — e.g. 1, 3, 5"
            value={orderedLitres}
            onChange={(e) => setOrderedLitres(e.target.value)}
          />
        </div>
        {requestedMl > 0 && <p className="hint">Requested volume per order: {requestedMl}ml</p>}
      </div>

      {orderedProductId && requestedMl > 0 && (
        <div className="sub-panel" style={{ marginTop: 8 }}>
          <strong>2. Pack each order with</strong>
          <ul className="plain-list">
            {bulkMix.map((l) => (
              <li key={l.sku_id}>
                {skus.find((s) => s.id === l.sku_id)?.sku_code} × {l.quantity}
                <button type="button" onClick={() => removeBulkMixLine(l.sku_id)}>Remove</button>
              </li>
            ))}
          </ul>
          <div className="inline-form">
            <select
              value={bulkMixDraft.sku_id}
              onChange={(e) => setBulkMixDraft({ ...bulkMixDraft, sku_id: e.target.value })}
            >
              <option value="">Select bottle to pack with</option>
              {packOptions.map((s) => (
                <option key={s.id} value={s.id}>{s.sku_code} ({s.size_ml}ml)</option>
              ))}
            </select>
            <input
              type="number"
              placeholder="Qty per order"
              value={bulkMixDraft.quantity}
              onChange={(e) => setBulkMixDraft({ ...bulkMixDraft, quantity: e.target.value })}
            />
            <button type="button" onClick={addBulkMixLine}>Add to mix</button>
          </div>
          <p className="hint" style={{ color: bulkMix.length === 0 ? undefined : mixMatches ? 'green' : 'crimson' }}>
            Mix total per order: {bulkMixMl}ml (need {requestedMl}ml)
          </p>
        </div>
      )}

      {mixMatches && (
        <div className="sub-panel" style={{ marginTop: 8 }}>
          <strong>3. How many orders, and on which date</strong>
          <form className="inline-form" onSubmit={submitBulkFulfill}>
            <input
              type="number"
              placeholder="Number of orders"
              value={bulkCount}
              onChange={(e) => setBulkCount(e.target.value)}
            />
            <input type="date" value={orderDate} onChange={(e) => setOrderDate(e.target.value)} />
            <button type="submit" disabled={bulkSubmitting || !bulkCount}>
              {bulkSubmitting ? 'Creating…' : `Create & fulfill ${bulkCount || 0} orders`}
            </button>
          </form>
        </div>
      )}

      {lastResult && (
        <p className={lastResult.ok ? 'info-text' : 'error-text'}>{lastResult.message}</p>
      )}
    </div>
  )
}

function ManualOrderPanel({ currentUserId }) {
  const [orders, setOrders] = useState([])
  const [skus, setSkus] = useState([])
  const [products, setProducts] = useState([])
  const [loading, setLoading] = useState(true)

  const [orderedProductId, setOrderedProductId] = useState('')
  const [orderedLitres, setOrderedLitres] = useState('')
  const [orderDate, setOrderDate] = useState(new Date().toISOString().slice(0, 10))
  const [mix, setMix] = useState([]) // [{ sku_id, quantity }]
  const [mixDraft, setMixDraft] = useState({ sku_id: '', quantity: '' })
  const [creating, setCreating] = useState(false)
  const [createError, setCreateError] = useState('')

  const [selectedIds, setSelectedIds] = useState(new Set())
  const [deleting, setDeleting] = useState(false)

  const [expandedOrder, setExpandedOrder] = useState(null)
  const [lineDraft, setLineDraft] = useState({ sku_id: '', quantity: '' })

  async function load() {
    setLoading(true)
    const [{ data: o }, { data: s }, { data: p }] = await Promise.all([
      supabase
        .from('orders')
        .select('id, order_code, client_id, requested_ml, status, created_at, order_lines(id, sku_id, quantity)')
        .order('created_at', { ascending: false })
        .limit(50),
      supabase.from('skus').select('id, sku_code, size_ml, product_id, products(name)').eq('is_active', true).order('sku_code'),
      supabase.from('products').select('id, name').order('name'),
    ])
    setOrders(o || [])
    setSkus(s || [])
    setProducts(p || [])
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  const requestedMl = orderedLitres ? Math.round(Number(orderedLitres) * 1000) : 0
  const packOptions = orderedProductId ? skus.filter((s) => s.product_id === orderedProductId) : []
  const mixMl = mix.reduce((sum, line) => {
    const sku = skus.find((s) => s.id === line.sku_id)
    return sum + (sku ? sku.size_ml * line.quantity : 0)
  }, 0)
  const mixMatches = requestedMl > 0 && mixMl === requestedMl && mix.length > 0

  function selectOrderedProduct(id) {
    setOrderedProductId(id)
    setMix([])
  }

  function addMixLine() {
    if (!mixDraft.sku_id || !mixDraft.quantity) return
    const qty = Number(mixDraft.quantity)
    setMix((prev) => {
      const existing = prev.find((l) => l.sku_id === mixDraft.sku_id)
      if (existing) {
        return prev.map((l) => (l.sku_id === mixDraft.sku_id ? { ...l, quantity: l.quantity + qty } : l))
      }
      return [...prev, { sku_id: mixDraft.sku_id, quantity: qty }]
    })
    setMixDraft({ sku_id: '', quantity: '' })
  }

  function removeMixLine(sku_id) {
    setMix((prev) => prev.filter((l) => l.sku_id !== sku_id))
  }

  async function createOrder() {
    if (!mixMatches) return
    setCreating(true)
    setCreateError('')
    try {
      const { error } = await supabase.rpc('bulk_fulfill_orders', {
        p_order_code_prefix: products.find((p) => p.id === orderedProductId)?.name.replace(/\s+/g, '-').toUpperCase() || 'ORDER',
        p_count: 1,
        p_mix: mix.map((l) => ({ sku_id: l.sku_id, quantity: l.quantity })),
        p_created_by: currentUserId,
        p_order_date: orderDate,
      })
      if (error) throw error

      setOrderedProductId('')
      setOrderedLitres('')
      setMix([])
      load()
    } catch (err) {
      setCreateError(err.message)
    } finally {
      setCreating(false)
    }
  }

  function fulfilledMl(order) {
    return order.order_lines.reduce((sum, line) => {
      const sku = skus.find((s) => s.id === line.sku_id)
      return sum + (sku ? sku.size_ml * line.quantity : 0)
    }, 0)
  }

  async function addLine(order) {
    if (!lineDraft.sku_id || !lineDraft.quantity) return
    const qty = Number(lineDraft.quantity)

    // upsert-ish: check existing line for this sku on this order
    const existing = order.order_lines.find((l) => l.sku_id === lineDraft.sku_id)
    if (existing) {
      await supabase
        .from('order_lines')
        .update({ quantity: existing.quantity + qty })
        .eq('id', existing.id)
    } else {
      await supabase.from('order_lines').insert({
        order_id: order.id,
        sku_id: lineDraft.sku_id,
        quantity: qty,
      })
    }
    setLineDraft({ sku_id: '', quantity: '' })
    load()
  }

  async function removeLine(lineId) {
    await supabase.from('order_lines').delete().eq('id', lineId)
    load()
  }

  async function fulfillOrder(order) {
    const fulfilled = fulfilledMl(order)
    if (fulfilled !== order.requested_ml) {
      alert(`Volume mismatch: requested ${order.requested_ml}ml, chosen bottles total ${fulfilled}ml. They must be equal.`)
      return
    }
    // Deduct stock for each line, then mark order fulfilled
    for (const line of order.order_lines) {
      const { error } = await supabase.from('stock_movements').insert({
        sku_id: line.sku_id,
        movement_type: 'order_fulfillment',
        quantity_change: -line.quantity,
        reference_order_id: order.id,
        created_by: currentUserId,
      })
      if (error) {
        alert(`Stock deduction failed: ${error.message}`)
        return
      }
    }
    await supabase.from('orders').update({ status: 'fulfilled', updated_at: new Date().toISOString() }).eq('id', order.id)
    load()
  }

  async function markDispatched(order) {
    await supabase.from('orders').update({ status: 'dispatched', updated_at: new Date().toISOString() }).eq('id', order.id)
    load()
  }

  function toggleSelected(id) {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function toggleSelectAll() {
    setSelectedIds((prev) => (prev.size === orders.length ? new Set() : new Set(orders.map((o) => o.id))))
  }

  async function deleteSelected() {
    if (selectedIds.size === 0) return
    if (!confirm(`Delete ${selectedIds.size} order(s)? Stock from any fulfilled/dispatched ones will be added back.`)) return

    setDeleting(true)
    const { error } = await supabase.rpc('delete_orders_bulk', {
      p_order_ids: Array.from(selectedIds),
    })
    setDeleting(false)
    if (error) {
      alert(error.message)
      return
    }
    setSelectedIds(new Set())
    load()
  }

  if (loading) return <p>Loading…</p>

  return (
    <div className="panel">
      <h2>New Single Order</h2>

      <div className="sub-panel">
        <div className="inline-form">
          <select value={orderedProductId} onChange={(e) => selectOrderedProduct(e.target.value)}>
            <option value="">Select product</option>
            {products.map((p) => (
              <option key={p.id} value={p.id}>{p.name}</option>
            ))}
          </select>
          <input
            type="number"
            step="0.5"
            placeholder="Volume (litres)"
            value={orderedLitres}
            onChange={(e) => setOrderedLitres(e.target.value)}
          />
          <input type="date" value={orderDate} onChange={(e) => setOrderDate(e.target.value)} />
        </div>

        {orderedProductId && requestedMl > 0 && (
          <>
            <div className="inline-form" style={{ marginTop: 8 }}>
              <select
                value={mixDraft.sku_id}
                onChange={(e) => setMixDraft({ ...mixDraft, sku_id: e.target.value })}
              >
                <option value="">Select bottle to pack with</option>
                {packOptions.map((s) => (
                  <option key={s.id} value={s.id}>{s.sku_code} ({s.size_ml}ml)</option>
                ))}
              </select>
              <input
                type="number"
                placeholder="Qty"
                value={mixDraft.quantity}
                onChange={(e) => setMixDraft({ ...mixDraft, quantity: e.target.value })}
              />
              <button type="button" onClick={addMixLine}>Add to mix</button>
            </div>
            {mix.length > 0 && (
              <ul className="plain-list">
                {mix.map((l) => (
                  <li key={l.sku_id}>
                    {skus.find((s) => s.id === l.sku_id)?.sku_code} × {l.quantity}
                    <button type="button" onClick={() => removeMixLine(l.sku_id)}>Remove</button>
                  </li>
                ))}
              </ul>
            )}
            <p className="hint" style={{ color: mix.length === 0 ? undefined : mixMatches ? 'green' : 'crimson' }}>
              Mix total: {mixMl}ml (need {requestedMl}ml)
            </p>
            <button type="button" onClick={createOrder} disabled={!mixMatches || creating}>
              {creating ? 'Creating…' : 'Create order'}
            </button>
          </>
        )}
        {createError && <p className="error-text">{createError}</p>}
      </div>

      <h2>Orders</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <button type="button" onClick={toggleSelectAll}>
          {selectedIds.size === orders.length && orders.length > 0 ? 'Unselect all' : 'Select all'}
        </button>
        <button type="button" onClick={deleteSelected} disabled={selectedIds.size === 0 || deleting}>
          {deleting ? 'Deleting…' : `Delete selected (${selectedIds.size})`}
        </button>
        <ExportButton
          filename="orders"
          rows={orders.map((o) => ({
            code: o.order_code,
            requested_ml: o.requested_ml,
            fulfilled_ml: fulfilledMl(o),
            status: o.status,
            bottle_mix: o.order_lines.map((l) => `${skus.find((s) => s.id === l.sku_id)?.sku_code} x ${l.quantity}`).join('; '),
            created_at: o.created_at,
          }))}
          columns={[
            { key: 'code', label: 'Code' },
            { key: 'requested_ml', label: 'Requested (ml)' },
            { key: 'fulfilled_ml', label: 'Fulfilled (ml)' },
            { key: 'status', label: 'Status' },
            { key: 'bottle_mix', label: 'Bottle Mix' },
            { key: 'created_at', label: 'Created At' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th></th>
            <th>Code</th>
            <th>Requested (ml)</th>
            <th>Fulfilled (ml)</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {orders.map((o) => {
            const fulfilled = fulfilledMl(o)
            const matched = fulfilled === o.requested_ml
            return (
              <>
                <tr key={o.id}>
                  <td>
                    <input
                      type="checkbox"
                      checked={selectedIds.has(o.id)}
                      onChange={() => toggleSelected(o.id)}
                    />
                  </td>
                  <td>{o.order_code}</td>
                  <td>{o.requested_ml}</td>
                  <td style={{ color: matched ? 'green' : 'crimson' }}>{fulfilled}</td>
                  <td>{o.status}</td>
                  <td>
                    <button type="button" onClick={() => setExpandedOrder(expandedOrder === o.id ? null : o.id)}>
                      {expandedOrder === o.id ? 'Close' : 'Bottles'}
                    </button>
                    {o.status === 'pending' && (
                      <button type="button" onClick={() => fulfillOrder(o)} disabled={!matched}>
                        Fulfill
                      </button>
                    )}
                    {o.status === 'fulfilled' && (
                      <button type="button" onClick={() => markDispatched(o)}>Mark dispatched</button>
                    )}
                  </td>
                </tr>
                {expandedOrder === o.id && (
                  <tr>
                    <td colSpan={6}>
                      <div className="sub-panel">
                        <ul className="plain-list">
                          {o.order_lines.map((l) => (
                            <li key={l.id}>
                              {skus.find((s) => s.id === l.sku_id)?.sku_code} × {l.quantity}
                              {o.status === 'pending' && (
                                <button type="button" onClick={() => removeLine(l.id)}>Remove</button>
                              )}
                            </li>
                          ))}
                        </ul>
                        {o.status === 'pending' && (
                          <div className="inline-form">
                            <select
                              value={lineDraft.sku_id}
                              onChange={(e) => setLineDraft({ ...lineDraft, sku_id: e.target.value })}
                            >
                              <option value="">Select bottle SKU</option>
                              {skus.map((s) => (
                                <option key={s.id} value={s.id}>{s.sku_code} ({s.size_ml}ml)</option>
                              ))}
                            </select>
                            <input
                              type="number"
                              placeholder="Qty"
                              value={lineDraft.quantity}
                              onChange={(e) => setLineDraft({ ...lineDraft, quantity: e.target.value })}
                            />
                            <button type="button" onClick={() => addLine(o)}>Add bottles</button>
                          </div>
                        )}
                      </div>
                    </td>
                  </tr>
                )}
              </>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

const MANUAL_PACKAGING_STAGES = PACKAGING_STAGES.filter((s) => s.value !== 'dispatched')

function PackagingPanel({ currentUserId }) {
  const [logDate, setLogDate] = useState(new Date().toISOString().slice(0, 10))
  const [skus, setSkus] = useState([])
  const [stockBySku, setStockBySku] = useState({})
  const [dispatchedBySku, setDispatchedBySku] = useState({})
  const [skuId, setSkuId] = useState('')
  const [stage, setStage] = useState(MANUAL_PACKAGING_STAGES[0].value)
  const [quantity, setQuantity] = useState('')
  const [totals, setTotals] = useState([])
  const [submitting, setSubmitting] = useState(false)
  const [editingCell, setEditingCell] = useState(null) // `${skuId}:${stage}`
  const [editValue, setEditValue] = useState('')
  const [savingEdit, setSavingEdit] = useState(false)
  const [closeNote, setCloseNote] = useState('')
  const [closing, setClosing] = useState(false)
  const [closeResult, setCloseResult] = useState(null)

  async function loadStock() {
    const { data } = await supabase.from('stock_levels').select('sku_id, quantity')
    const map = {}
    for (const r of data || []) map[r.sku_id] = r.quantity
    setStockBySku(map)
  }

  async function loadDispatched(date) {
    const { data } = await supabase
      .from('scan_fail_summary')
      .select('sku_id, total_units')
      .eq('order_date', date)
    const map = {}
    for (const r of data || []) map[r.sku_id] = r.total_units
    setDispatchedBySku(map)
  }

  useEffect(() => {
    async function loadSkus() {
      const { data } = await supabase.from('skus').select('id, sku_code').eq('is_active', true).order('sku_code')
      setSkus(data || [])
    }
    loadSkus()
    loadStock()

    // Keep the warehouse-count column live as stock changes elsewhere in the app
    const channel = supabase
      .channel('packaging_panel_stock_levels')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_levels' }, loadStock)
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [])

  async function loadTotals(date) {
    const { data } = await supabase
      .from('packaging_daily_totals')
      .select('log_date, sku_id, sku_code, product_name, stage, total_quantity')
      .eq('log_date', date)
    setTotals(data || [])
  }

  useEffect(() => {
    loadTotals(logDate)
    loadDispatched(logDate)
    setCloseResult(null)
  }, [logDate])

  async function submitEntry(e) {
    e.preventDefault()
    if (!quantity || !skuId) return
    setSubmitting(true)
    const { error } = await supabase.from('packaging_daily_log').insert({
      log_date: logDate,
      sku_id: skuId,
      stage,
      quantity: Number(quantity),
      recorded_by: currentUserId,
    })
    setSubmitting(false)
    if (error) {
      alert(error.message)
      return
    }
    setQuantity('')
    loadTotals(logDate)
  }

  function currentTotal(skuId, stageValue) {
    if (stageValue === 'dispatched') return dispatchedBySku[skuId] || 0
    return totals.find((t) => t.sku_id === skuId && t.stage === stageValue)?.total_quantity || 0
  }

  function packagingGrandTotal(skuId) {
    return PACKAGING_STAGES.reduce((sum, stg) => sum + currentTotal(skuId, stg.value), 0)
  }

  async function closeWarehouse() {
    setClosing(true)
    setCloseResult(null)
    try {
      const manualTotals = {}
      for (const s of skus) {
        manualTotals[s.id] = {}
        for (const stg of MANUAL_PACKAGING_STAGES) {
          manualTotals[s.id][stg.value] = currentTotal(s.id, stg.value)
        }
      }
      const { data, error } = await supabase.rpc('close_warehouse', {
        p_closure_date: logDate,
        p_manual_stage_totals: manualTotals,
        p_note: closeNote || null,
        p_actor_id: currentUserId,
      })
      if (error) throw error
      const row = data?.[0]
      setCloseResult({
        ok: true,
        allMatched: row?.all_matched,
        message: row?.all_matched
          ? `Warehouse closed for ${logDate} — all SKUs matched.`
          : `Warehouse closed for ${logDate} with mismatches, noted.`,
      })
      setCloseNote('')
    } catch (err) {
      setCloseResult({ ok: false, message: err.message })
    } finally {
      setClosing(false)
    }
  }

  const anyMismatch = skus.some((s) => packagingGrandTotal(s.id) !== (stockBySku[s.id] ?? 0))

  function startEdit(skuId, stageValue) {
    setEditingCell(`${skuId}:${stageValue}`)
    setEditValue(String(currentTotal(skuId, stageValue)))
  }

  async function saveEdit(skuId, stageValue) {
    const target = Number(editValue)
    if (Number.isNaN(target) || target < 0) return
    const current = currentTotal(skuId, stageValue)
    const delta = target - current
    setSavingEdit(true)
    if (delta !== 0) {
      const { error } = await supabase.from('packaging_daily_log').insert({
        log_date: logDate,
        sku_id: skuId,
        stage: stageValue,
        quantity: delta,
        recorded_by: currentUserId,
      })
      if (error) {
        alert(error.message)
        setSavingEdit(false)
        return
      }
    }
    setSavingEdit(false)
    setEditingCell(null)
    loadTotals(logDate)
  }

  return (
    <div className="panel">
      <h2>Punch Packaging Count</h2>
      <p className="hint">
        Log any stage directly — e.g. a 3L order packed as 3×1L bottles can be entered straight into
        "Box bubble wrap" without going through earlier stages first. Click any total below to correct it.
        "Warehouse Stock" is the live current stock for that SKU — use it to cross-check packaging/dispatch
        counts against what's actually left in the warehouse.
      </p>
      <form className="inline-form" onSubmit={submitEntry}>
        <input type="date" value={logDate} onChange={(e) => setLogDate(e.target.value)} />
        <select value={skuId} onChange={(e) => setSkuId(e.target.value)}>
          <option value="">Select SKU</option>
          {skus.map((s) => (
            <option key={s.id} value={s.id}>{s.sku_code}</option>
          ))}
        </select>
        <select value={stage} onChange={(e) => setStage(e.target.value)}>
          {MANUAL_PACKAGING_STAGES.map((s) => (
            <option key={s.value} value={s.value}>{s.label}</option>
          ))}
        </select>
        <input
          type="number"
          placeholder="Count to add"
          value={quantity}
          onChange={(e) => setQuantity(e.target.value)}
        />
        <button type="submit" disabled={submitting || !skuId}>
          {submitting ? 'Saving…' : 'Add count'}
        </button>
      </form>

      <h2>Totals for {logDate}</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename={`packaging-tally-${logDate}`}
          rows={skus.map((s) => {
            const row = { sku: s.sku_code }
            let total = 0
            PACKAGING_STAGES.forEach((stg) => {
              const v = currentTotal(s.id, stg.value)
              row[stg.value] = v
              total += v
            })
            row.total = total
            row.warehouse_stock = stockBySku[s.id] ?? 0
            return row
          })}
          columns={[
            { key: 'sku', label: 'SKU' },
            ...PACKAGING_STAGES.map((s) => ({ key: s.value, label: s.label })),
            { key: 'total', label: 'Total' },
            { key: 'warehouse_stock', label: 'Warehouse Stock' },
          ]}
        />
      </div>
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
            const rowTotal = PACKAGING_STAGES.reduce((sum, stg) => sum + currentTotal(s.id, stg.value), 0)
            return (
              <tr key={s.id}>
                <td>{s.sku_code}</td>
                {PACKAGING_STAGES.map((stg) => {
                  if (stg.value === 'dispatched') {
                    return (
                      <td key={stg.value} title="Auto-filled from Dispatch tab">
                        {currentTotal(s.id, stg.value)}
                      </td>
                    )
                  }
                  const key = `${s.id}:${stg.value}`
                  const value = currentTotal(s.id, stg.value)
                  if (editingCell === key) {
                    return (
                      <td key={stg.value}>
                        <input
                          type="number"
                          value={editValue}
                          onChange={(e) => setEditValue(e.target.value)}
                          style={{ width: 60 }}
                        />
                        <button type="button" onClick={() => saveEdit(s.id, stg.value)} disabled={savingEdit}>
                          Save
                        </button>
                        <button type="button" onClick={() => setEditingCell(null)}>Cancel</button>
                      </td>
                    )
                  }
                  return (
                    <td key={stg.value} onClick={() => startEdit(s.id, stg.value)} style={{ cursor: 'pointer' }} title="Click to edit">
                      {value}
                    </td>
                  )
                })}
                <td><strong>{rowTotal}</strong></td>
                <td style={{ color: rowTotal !== (stockBySku[s.id] ?? 0) ? 'crimson' : 'green' }}>
                  {stockBySku[s.id] ?? 0}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>

      <div className="sub-panel" style={{ marginTop: 16 }}>
        <strong>Close Warehouse — {logDate}</strong>
        <p className="hint">
          {anyMismatch
            ? 'One or more SKUs don\'t match (shown in red above). Add a note explaining the mismatch to close anyway.'
            : 'All SKUs match packaging total to warehouse stock. Ready to close.'}
        </p>
        {anyMismatch && (
          <input
            placeholder="Note (required due to mismatch)"
            value={closeNote}
            onChange={(e) => setCloseNote(e.target.value)}
            style={{ width: '100%', marginBottom: 8, padding: '8px 10px', border: '1px solid #ccc', borderRadius: 4 }}
          />
        )}
        <button type="button" onClick={closeWarehouse} disabled={closing || (anyMismatch && !closeNote.trim())}>
          {closing ? 'Closing…' : 'Close Warehouse'}
        </button>
        {closeResult && (
          <p className={closeResult.ok ? 'info-text' : 'error-text'}>{closeResult.message}</p>
        )}
      </div>
    </div>
  )
}

function DispatchPanel({ currentUserId }) {
  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().slice(0, 10))
  const [skus, setSkus] = useState([])
  const [selectedSkuId, setSelectedSkuId] = useState('')
  const [readyOrders, setReadyOrders] = useState([]) // fulfilled orders for selected sku/date
  const [scanFailCount, setScanFailCount] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [lastResult, setLastResult] = useState(null)
  const [summary, setSummary] = useState([])
  const [dispatchingAll, setDispatchingAll] = useState(false)
  const [dispatchAllResult, setDispatchAllResult] = useState(null)

  async function loadSkus() {
    const { data } = await supabase.from('skus').select('id, sku_code').eq('is_active', true).order('sku_code')
    setSkus(data || [])
  }

  async function loadReady(skuId, date) {
    if (!skuId) {
      setReadyOrders([])
      return
    }
    const { data } = await supabase
      .from('orders')
      .select('id, status, created_at, order_lines!inner(quantity, sku_id)')
      .eq('order_lines.sku_id', skuId)
      .eq('status', 'fulfilled')
      .gte('created_at', `${date}T00:00:00+05:30`)
      .lte('created_at', `${date}T23:59:59.999+05:30`)
    setReadyOrders(data || [])
  }

  async function loadSummary(date) {
    const [{ data: dispatchData }, { data: packagingData }] = await Promise.all([
      supabase
        .from('scan_fail_summary')
        .select('sku_code, product_name, scan_failed_orders, scan_failed_units, total_orders, total_units')
        .eq('order_date', date),
      supabase
        .from('packaging_daily_totals')
        .select('sku_code, total_quantity')
        .eq('log_date', date)
        .eq('stage', 'dispatched'),
    ])
    const merged = (dispatchData || []).map((row) => ({
      ...row,
      packaged_units: packagingData?.find((p) => p.sku_code === row.sku_code)?.total_quantity || 0,
    }))
    setSummary(merged)
  }

  useEffect(() => {
    loadSkus()
  }, [])

  useEffect(() => {
    loadReady(selectedSkuId, selectedDate)
    loadSummary(selectedDate)
  }, [selectedSkuId, selectedDate])

  const readyUnits = readyOrders.reduce((sum, o) => sum + (o.order_lines[0]?.quantity || 0), 0)

  async function dispatchAll() {
    setDispatchingAll(true)
    setDispatchAllResult(null)
    try {
      // Refetch SKUs fresh rather than trusting possibly-stale state
      const { data: freshSkus, error: skuErr } = await supabase
        .from('skus')
        .select('id, sku_code')
        .eq('is_active', true)
      if (skuErr) throw skuErr
      if (!freshSkus || freshSkus.length === 0) {
        throw new Error('No active SKUs found.')
      }

      let totalOrders = 0
      let totalUnits = 0
      for (const s of freshSkus) {
        const { data, error } = await supabase.rpc('reconcile_and_dispatch', {
          p_sku_id: s.id,
          p_date: selectedDate,
          p_scan_fail_count: 0,
          p_actor_id: currentUserId,
        })
        if (error) throw error
        const row = data?.[0]
        totalOrders += row?.dispatched_orders || 0
        totalUnits += row?.dispatched_units || 0
      }
      setDispatchAllResult({ ok: true, message: `Dispatched ${totalOrders} orders (${totalUnits} units) across all SKUs for ${selectedDate}.` })
      loadReady(selectedSkuId, selectedDate)
      loadSummary(selectedDate)
    } catch (err) {
      setDispatchAllResult({ ok: false, message: err.message })
    } finally {
      setDispatchingAll(false)
    }
  }

  async function submitReconcile(e) {
    e.preventDefault()
    if (!selectedSkuId || scanFailCount === '') return
    setSubmitting(true)
    setLastResult(null)
    try {
      const { data, error } = await supabase.rpc('reconcile_and_dispatch', {
        p_sku_id: selectedSkuId,
        p_date: selectedDate,
        p_scan_fail_count: Number(scanFailCount),
        p_actor_id: currentUserId,
      })
      if (error) throw error
      const row = data?.[0]
      setLastResult({
        ok: true,
        message: `${row?.dispatched_orders || 0} orders (${row?.dispatched_units || 0} units) dispatched. ${row?.reconciled_orders || 0} orders (${row?.reconciled_units || 0} units) marked scan-failed, stock restored.`,
      })
      setScanFailCount('')
      loadReady(selectedSkuId, selectedDate)
      loadSummary(selectedDate)
    } catch (err) {
      setLastResult({ ok: false, message: err.message })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="panel">
      <h2>Dispatch</h2>
      <p className="hint">
        Orders are created "fulfilled" (packed, ready). Pick a product and date, enter how many failed to scan,
        and the rest get dispatched — scan-failed ones keep their record but return their stock.
      </p>

      <div className="sub-panel" style={{ marginBottom: 16 }}>
        <strong>Dispatch all products for a date</strong>
        <p className="hint">Sends every SKU's ready orders for the date to dispatch, assuming zero scan-fails. Reconcile specific SKUs below afterward if any scan-fails happened.</p>
        <div className="inline-form">
          <input type="date" value={selectedDate} onChange={(e) => setSelectedDate(e.target.value)} />
          <button type="button" onClick={dispatchAll} disabled={dispatchingAll}>
            {dispatchingAll ? 'Dispatching…' : 'Dispatch All (no scan-fail)'}
          </button>
        </div>
        {dispatchAllResult && (
          <p className={dispatchAllResult.ok ? 'info-text' : 'error-text'}>{dispatchAllResult.message}</p>
        )}
      </div>

      <div className="inline-form" style={{ marginBottom: 16 }}>
        <select value={selectedSkuId} onChange={(e) => setSelectedSkuId(e.target.value)}>
          <option value="">Select SKU (to reconcile scan-fails individually)</option>
          {skus.map((s) => (
            <option key={s.id} value={s.id}>{s.sku_code}</option>
          ))}
        </select>
      </div>

      {selectedSkuId && (
        <div className="sub-panel">
          <p className="hint">
            Ready to dispatch on {selectedDate}: <strong>{readyOrders.length} orders</strong> ({readyUnits} units)
          </p>
          <form className="inline-form" onSubmit={submitReconcile}>
            <input
              type="number"
              placeholder="Scan-fail count (units)"
              value={scanFailCount}
              onChange={(e) => setScanFailCount(e.target.value)}
            />
            <button type="submit" disabled={submitting || readyOrders.length === 0}>
              {submitting ? 'Processing…' : 'Reconcile & Dispatch'}
            </button>
          </form>
          {lastResult && (
            <p className={lastResult.ok ? 'info-text' : 'error-text'}>{lastResult.message}</p>
          )}
        </div>
      )}

      <h2>Scan-Fail Summary for {selectedDate}</h2>
      <p className="hint">
        "Packaged" is the count logged as "Dispatched" stage in Daily Packaging Tally — it should match
        "Dispatched units". A mismatch means packaging and dispatch counts disagree for that SKU/date.
      </p>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename={`dispatch-summary-${selectedDate}`}
          rows={summary.map((row) => ({
            sku: row.sku_code,
            product: row.product_name,
            scan_failed_orders: row.scan_failed_orders,
            scan_failed_units: row.scan_failed_units,
            dispatched_orders: row.total_orders,
            dispatched_units: row.total_units,
            packaged_units: row.packaged_units,
          }))}
          columns={[
            { key: 'sku', label: 'SKU' },
            { key: 'product', label: 'Product' },
            { key: 'scan_failed_orders', label: 'Scan-Failed Orders' },
            { key: 'scan_failed_units', label: 'Scan-Failed Units' },
            { key: 'dispatched_orders', label: 'Dispatched Orders' },
            { key: 'dispatched_units', label: 'Dispatched Units' },
            { key: 'packaged_units', label: 'Packaged Units' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th>SKU</th>
            <th>Product</th>
            <th>Scan-failed (orders / units)</th>
            <th>Dispatched (orders / units)</th>
            <th>Packaged</th>
          </tr>
        </thead>
        <tbody>
          {summary.map((row) => {
            const mismatch = row.packaged_units !== row.total_units
            return (
              <tr key={row.sku_code}>
                <td>{row.sku_code}</td>
                <td>{row.product_name}</td>
                <td style={{ color: row.scan_failed_units > 0 ? 'crimson' : undefined }}>
                  {row.scan_failed_orders} / {row.scan_failed_units}
                </td>
                <td>{row.total_orders} / {row.total_units}</td>
                <td style={{ color: mismatch ? 'crimson' : 'green' }}>
                  {row.packaged_units}{mismatch ? ' ⚠' : ''}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function RtoPanel({ currentUserId }) {
  const [skus, setSkus] = useState([])
  const [returns, setReturns] = useState([])
  const [form, setForm] = useState({ sku_id: '', quantity_returned: '', note: '' })
  const [submitting, setSubmitting] = useState(false)
  const [selectedDate, setSelectedDate] = useState(new Date().toISOString().slice(0, 10))

  async function loadSkus() {
    const { data } = await supabase.from('skus').select('id, sku_code').eq('is_active', true).order('sku_code')
    setSkus(data || [])
  }

  async function loadReturns(date) {
    const { data } = await supabase
      .from('rto_returns')
      .select('id, sku_id, quantity_returned, note, return_date')
      .eq('return_date', date)
      .order('created_at', { ascending: false })
    setReturns(data || [])
  }

  useEffect(() => {
    loadSkus()
  }, [])

  useEffect(() => {
    loadReturns(selectedDate)
  }, [selectedDate])

  async function submitReturn(e) {
    e.preventDefault()
    if (!form.sku_id || !form.quantity_returned) return
    setSubmitting(true)
    const { error } = await supabase.from('rto_returns').insert({
      sku_id: form.sku_id,
      quantity_returned: Number(form.quantity_returned),
      return_date: selectedDate,
      note: form.note || null,
      recounted_by: currentUserId,
    })
    setSubmitting(false)
    if (error) {
      alert(error.message)
      return
    }
    setForm({ sku_id: '', quantity_returned: '', note: '' })
    loadReturns(selectedDate)
  }

  const totalsBySku = skus.map((s) => ({
    ...s,
    total: returns.filter((r) => r.sku_id === s.id).reduce((sum, r) => sum + r.quantity_returned, 0),
  })).filter((s) => s.total > 0)

  return (
    <div className="panel">
      <h2>RTO (Return to Origin)</h2>
      <p className="hint">
        A dispatched order came back to the warehouse — log the product and quantity here.
        Stock is added back to inventory automatically.
      </p>

      <div className="inline-form" style={{ marginBottom: 16 }}>
        <input type="date" value={selectedDate} onChange={(e) => setSelectedDate(e.target.value)} />
      </div>

      <form className="inline-form" onSubmit={submitReturn}>
        <select value={form.sku_id} onChange={(e) => setForm({ ...form, sku_id: e.target.value })}>
          <option value="">Select SKU</option>
          {skus.map((s) => (
            <option key={s.id} value={s.id}>{s.sku_code}</option>
          ))}
        </select>
        <input
          type="number"
          placeholder="Quantity"
          value={form.quantity_returned}
          onChange={(e) => setForm({ ...form, quantity_returned: e.target.value })}
        />
        <input
          placeholder="Note (optional)"
          value={form.note}
          onChange={(e) => setForm({ ...form, note: e.target.value })}
        />
        <button type="submit" disabled={submitting}>
          {submitting ? 'Saving…' : 'Log RTO'}
        </button>
      </form>

      {totalsBySku.length > 0 && (
        <div className="widget-row" style={{ marginTop: 16 }}>
          {totalsBySku.map((s) => (
            <div className="widget-card" key={s.id}>
              <span className="widget-value">{s.total}</span>
              <span className="widget-label">{s.sku_code}</span>
            </div>
          ))}
        </div>
      )}

      <h2>RTO Entries for {selectedDate}</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename={`rto-entries-${selectedDate}`}
          rows={returns.map((r) => ({
            sku: skus.find((s) => s.id === r.sku_id)?.sku_code,
            quantity: r.quantity_returned,
            note: r.note,
          }))}
          columns={[
            { key: 'sku', label: 'SKU' },
            { key: 'quantity', label: 'Quantity' },
            { key: 'note', label: 'Note' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr><th>SKU</th><th>Qty</th><th>Note</th></tr>
        </thead>
        <tbody>
          {returns.map((r) => (
            <tr key={r.id}>
              <td>{skus.find((s) => s.id === r.sku_id)?.sku_code}</td>
              <td>{r.quantity_returned}</td>
              <td>{r.note}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function OrderLogPanel() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [dateFilter, setDateFilter] = useState('')

  async function load(date) {
    setLoading(true)
    let query = supabase
      .from('order_log_summary')
      .select('batch_key, batch_created_at, order_date, product_name, sku_code, size_ml, order_count, bottle_count, total_ml')
    if (date) query = query.eq('order_date', date)
    const { data } = await query.order('batch_created_at', { ascending: false })
    setRows(data || [])
    setLoading(false)
  }

  useEffect(() => {
    load(dateFilter || null)
  }, [dateFilter])

  // Group rows by batch_key so each submission (Bulk/Manual Order click) is its own
  // entry, even if same date/product as another submission — its SKU-mix lines sit together
  const grouped = []
  for (const r of rows) {
    let group = grouped.find((g) => g.batch_key === r.batch_key)
    if (!group) {
      group = {
        batch_key: r.batch_key,
        order_date: r.order_date,
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
      <p className="hint">Product-wise, date-wise summary of every order created — how many, and the bottle-mix used to fulfill them.</p>
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
                product: g.product_name,
                bottle_mix: g.lines.map((l) => `${l.sku_code} x ${l.bottle_count}`).join('; '),
                orders: g.totalOrders,
                units: g.totalUnits,
                total_ml: g.totalMl,
              }))}
              columns={[
                { key: 'date', label: 'Date' },
                { key: 'product', label: 'Product' },
                { key: 'bottle_mix', label: 'Bottle Mix' },
                { key: 'orders', label: 'Orders' },
                { key: 'units', label: 'Units' },
                { key: 'total_ml', label: 'Total ml' },
              ]}
            />
          </div>
          <table>
            <thead>
              <tr>
                <th>Date</th>
                <th>Product</th>
                <th>Bottle mix</th>
                <th>Orders</th>
                <th>Units</th>
                <th>Total ml</th>
              </tr>
            </thead>
            <tbody>
              {grouped.map((g) => (
                <tr key={g.batch_key}>
                  <td>{g.order_date}</td>
                  <td>{g.product_name}</td>
                  <td>
                    {g.lines.map((l) => `${l.sku_code} × ${l.bottle_count}`).join(', ')}
                  </td>
                  <td>{g.totalOrders}</td>
                  <td>{g.totalUnits}</td>
                  <td>{g.totalMl.toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}

function ClosureLogPanel() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [dateFilter, setDateFilter] = useState('')

  async function load(date) {
    setLoading(true)
    let query = supabase
      .from('warehouse_closure_log')
      .select('closure_id, closure_date, all_matched, note, created_at, closed_by_name, sku_code, packaging_total, warehouse_stock, matched')
    if (date) query = query.eq('closure_date', date)
    const { data } = await query.order('created_at', { ascending: false })
    setRows(data || [])
    setLoading(false)
  }

  useEffect(() => {
    load(dateFilter || null)
  }, [dateFilter])

  // Group by closure_id — each Close Warehouse click is its own entry,
  // even multiple closures on the same date
  const closures = []
  for (const r of rows) {
    let c = closures.find((c) => c.closure_id === r.closure_id)
    if (!c) {
      c = {
        closure_id: r.closure_id,
        closure_date: r.closure_date,
        all_matched: r.all_matched,
        note: r.note,
        created_at: r.created_at,
        closed_by_name: r.closed_by_name,
        lines: [],
      }
      closures.push(c)
    }
    c.lines.push(r)
  }

  return (
    <div className="panel">
      <h2>Warehouse Closure Log</h2>
      <p className="hint">
        Every "Close Warehouse" click is logged here, even multiple closures on the same date.
      </p>
      <div className="inline-form" style={{ marginBottom: 16 }}>
        <input type="date" value={dateFilter} onChange={(e) => setDateFilter(e.target.value)} />
        {dateFilter && <button type="button" onClick={() => setDateFilter('')}>Clear filter</button>}
      </div>

      {loading ? (
        <p>Loading…</p>
      ) : closures.length === 0 ? (
        <p className="hint">No closures found{dateFilter ? ` for ${dateFilter}` : ''}.</p>
      ) : (
        <>
          <div className="inline-form" style={{ marginBottom: 8 }}>
            <ExportButton
              filename={`closure-log${dateFilter ? '-' + dateFilter : ''}`}
              rows={closures.map((c) => ({
                date: c.closure_date,
                closed_at: c.created_at,
                closed_by: c.closed_by_name,
                matched: c.all_matched,
                note: c.note,
                breakdown: c.lines.map((l) => `${l.sku_code}: ${l.packaging_total}/${l.warehouse_stock}${l.matched ? '' : ' ⚠'}`).join('; '),
              }))}
              columns={[
                { key: 'date', label: 'Date' },
                { key: 'closed_at', label: 'Closed At' },
                { key: 'closed_by', label: 'Closed By' },
                { key: 'matched', label: 'All Matched' },
                { key: 'note', label: 'Note' },
                { key: 'breakdown', label: 'SKU Breakdown (Packaging/Stock)' },
              ]}
            />
          </div>
          {closures.map((c) => (
            <div key={c.closure_id} className="sub-panel" style={{ marginBottom: 12 }}>
              <strong style={{ color: c.all_matched ? 'green' : 'crimson' }}>
                {c.closure_date} — {new Date(c.created_at).toLocaleTimeString()} — {c.all_matched ? 'All matched' : 'Mismatch'}
              </strong>
              {' '}by {c.closed_by_name}
              {c.note && <p className="hint">Note: {c.note}</p>}
              <table style={{ marginTop: 8 }}>
                <thead>
                  <tr><th>SKU</th><th>Packaging Total</th><th>Warehouse Stock</th><th>Matched</th></tr>
                </thead>
                <tbody>
                  {c.lines.map((l) => (
                    <tr key={l.sku_code}>
                      <td>{l.sku_code}</td>
                      <td>{l.packaging_total}</td>
                      <td>{l.warehouse_stock}</td>
                      <td style={{ color: l.matched ? 'green' : 'crimson' }}>{l.matched ? 'Yes' : 'No'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))}
        </>
      )}
    </div>
  )
}

function StockPanel() {
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    async function load() {
      setLoading(true)
      const { data } = await supabase
        .from('stock_levels')
        .select('sku_id, quantity, updated_at, skus(sku_code, size_ml, products(name))')
        .order('updated_at', { ascending: false })
      setRows(data || [])
      setLoading(false)
    }
    load()
  }, [])

  if (loading) return <p>Loading…</p>

  return (
    <div className="panel">
      <h2>Current Stock Levels</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename="stock-levels"
          rows={rows.map((r) => ({
            sku: r.skus?.sku_code,
            product: r.skus?.products?.name,
            size_ml: r.skus?.size_ml,
            quantity: r.quantity,
          }))}
          columns={[
            { key: 'sku', label: 'SKU' },
            { key: 'product', label: 'Product' },
            { key: 'size_ml', label: 'Size (ml)' },
            { key: 'quantity', label: 'Quantity' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th>SKU</th><th>Product</th><th>Size (ml)</th><th>Quantity</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.sku_id}>
              <td>{r.skus?.sku_code}</td>
              <td>{r.skus?.products?.name}</td>
              <td>{r.skus?.size_ml}</td>
              <td>{r.quantity}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function RawStockHistoryPanel() {
  const [skus, setSkus] = useState([])
  const [batches, setBatches] = useState([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    async function load() {
      setLoading(true)
      const [{ data: s }, { data: b }] = await Promise.all([
        supabase.from('skus').select('id, sku_code, units_per_box'),
        supabase
          .from('raw_stock_batches')
          .select('id, sku_id, box_count, loose_units, units_per_box_at_time, total_units, received_date, supplier_note')
          .order('received_date', { ascending: false })
          .limit(100),
      ])
      setSkus(s || [])
      setBatches(b || [])
      setLoading(false)
    }
    load()
  }, [])

  if (loading) return <p>Loading…</p>

  return (
    <div className="panel">
      <h2>Raw Stock Inward History</h2>
      <p className="hint">Read-only view of raw material batches received, by date.</p>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename="raw-stock-inward-history"
          rows={batches.map((b) => ({
            date: b.received_date,
            sku: skus.find((s) => s.id === b.sku_id)?.sku_code || b.sku_id,
            boxes: b.box_count,
            loose_units: b.loose_units,
            units_per_box: b.units_per_box_at_time,
            total_pieces: b.total_units,
            note: b.supplier_note,
          }))}
          columns={[
            { key: 'date', label: 'Date' },
            { key: 'sku', label: 'SKU' },
            { key: 'boxes', label: 'Boxes' },
            { key: 'loose_units', label: 'Loose Units' },
            { key: 'units_per_box', label: 'Units/Box' },
            { key: 'total_pieces', label: 'Total Pieces' },
            { key: 'note', label: 'Note' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th>Date</th>
            <th>SKU</th>
            <th>Boxes</th>
            <th>Loose units</th>
            <th>Units/box</th>
            <th>Total pieces</th>
            <th>Note</th>
          </tr>
        </thead>
        <tbody>
          {batches.map((b) => (
            <tr key={b.id}>
              <td>{b.received_date}</td>
              <td>{skus.find((s) => s.id === b.sku_id)?.sku_code || b.sku_id}</td>
              <td>{b.box_count}</td>
              <td>{b.loose_units}</td>
              <td>{b.units_per_box_at_time}</td>
              <td>{b.total_units}</td>
              <td>{b.supplier_note}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
