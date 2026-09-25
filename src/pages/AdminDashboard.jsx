import { useEffect, useState } from 'react'
import Layout from '../components/Layout'
import { supabase } from '../lib/supabaseClient'
import { useAuth } from '../context/AuthContext'
import ExportButton from '../components/ExportButton'

export default function AdminDashboard() {
  const { profile } = useAuth()
  const [tab, setTab] = useState('users')

  return (
    <Layout title="Super Admin">
      <nav className="tabs">
        <button className={tab === 'users' ? 'active' : ''} onClick={() => setTab('users')}>
          Users
        </button>
        <button className={tab === 'products' ? 'active' : ''} onClick={() => setTab('products')}>
          Products & SKUs
        </button>
        <button className={tab === 'raw-stock' ? 'active' : ''} onClick={() => setTab('raw-stock')}>
          Raw Stock Inward
        </button>
        <button className={tab === 'stock' ? 'active' : ''} onClick={() => setTab('stock')}>
          Current Stock
        </button>
      </nav>

      {tab === 'users' && <UsersPanel currentUserId={profile.id} />}
      {tab === 'products' && <ProductsPanel />}
      {tab === 'raw-stock' && <RawStockPanel currentUserId={profile.id} />}
      {tab === 'stock' && <StockPanel />}
    </Layout>
  )
}

function UsersPanel({ currentUserId }) {
  const [profiles, setProfiles] = useState([])
  const [loading, setLoading] = useState(true)
  const [savingId, setSavingId] = useState(null)

  async function load() {
    setLoading(true)
    const { data } = await supabase
      .from('profiles')
      .select('id, full_name, email, role, created_at')
      .order('created_at', { ascending: false })
    setProfiles(data || [])
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  async function updateRole(id, role) {
    setSavingId(id)
    await supabase
      .from('profiles')
      .update({ role, approved_by: currentUserId, approved_at: new Date().toISOString() })
      .eq('id', id)
    setSavingId(null)
    load()
  }

  if (loading) return <p>Loading users…</p>

  return (
    <div className="panel">
      <h2>Users</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename="users"
          rows={profiles.map((p) => ({
            name: p.full_name,
            email: p.email,
            role: p.role,
            created_at: p.created_at,
          }))}
          columns={[
            { key: 'name', label: 'Name' },
            { key: 'email', label: 'Email' },
            { key: 'role', label: 'Role' },
            { key: 'created_at', label: 'Created At' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Email</th>
            <th>Role</th>
            <th>Change role</th>
          </tr>
        </thead>
        <tbody>
          {profiles.map((p) => (
            <tr key={p.id}>
              <td>{p.full_name}</td>
              <td>{p.email}</td>
              <td>
                <span className={`badge badge-${p.role}`}>{p.role.replaceAll('_', ' ')}</span>
              </td>
              <td>
                <select
                  value={p.role}
                  disabled={savingId === p.id || p.id === currentUserId}
                  onChange={(e) => updateRole(p.id, e.target.value)}
                >
                  <option value="pending">pending</option>
                  <option value="super_admin">super_admin</option>
                  <option value="operation_incharge">operation_incharge</option>
                  <option value="client">client</option>
                </select>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ProductsPanel() {
  const [products, setProducts] = useState([])
  const [skus, setSkus] = useState([])
  const [loading, setLoading] = useState(true)

  const [newProductName, setNewProductName] = useState('')
  const [newSku, setNewSku] = useState({ product_id: '', size_ml: '', sku_code: '', units_per_box: '' })

  const [editingProductId, setEditingProductId] = useState(null)
  const [productDraft, setProductDraft] = useState('')

  const [editingSkuId, setEditingSkuId] = useState(null)
  const [skuDraft, setSkuDraft] = useState({ sku_code: '', size_ml: '', units_per_box: '' })

  async function load() {
    setLoading(true)
    const [{ data: p }, { data: s }] = await Promise.all([
      supabase.from('products').select('id, name').order('name'),
      supabase.from('skus').select('id, product_id, size_ml, sku_code, units_per_box, is_active').order('sku_code'),
    ])
    setProducts(p || [])
    setSkus(s || [])
    setLoading(false)
  }

  useEffect(() => {
    load()
  }, [])

  async function addProduct(e) {
    e.preventDefault()
    if (!newProductName.trim()) return
    await supabase.from('products').insert({ name: newProductName.trim() })
    setNewProductName('')
    load()
  }

  function startEditProduct(p) {
    setEditingProductId(p.id)
    setProductDraft(p.name)
  }

  async function saveProduct(id) {
    if (!productDraft.trim()) return
    const { error } = await supabase.from('products').update({ name: productDraft.trim() }).eq('id', id)
    if (error) {
      alert(error.message)
      return
    }
    setEditingProductId(null)
    load()
  }

  async function addSku(e) {
    e.preventDefault()
    const { product_id, size_ml, sku_code, units_per_box } = newSku
    if (!product_id || !size_ml || !sku_code || !units_per_box) return
    await supabase.from('skus').insert({
      product_id,
      size_ml: Number(size_ml),
      sku_code: sku_code.trim(),
      units_per_box: Number(units_per_box),
    })
    setNewSku({ product_id: '', size_ml: '', sku_code: '', units_per_box: '' })
    load()
  }

  async function toggleActive(sku) {
    await supabase.from('skus').update({ is_active: !sku.is_active }).eq('id', sku.id)
    load()
  }

  function startEditSku(s) {
    setEditingSkuId(s.id)
    setSkuDraft({ sku_code: s.sku_code, size_ml: s.size_ml, units_per_box: s.units_per_box })
  }

  async function saveSku(id) {
    const { sku_code, size_ml, units_per_box } = skuDraft
    if (!sku_code.trim() || !size_ml || !units_per_box) return
    const { error } = await supabase
      .from('skus')
      .update({
        sku_code: sku_code.trim(),
        size_ml: Number(size_ml),
        units_per_box: Number(units_per_box),
      })
      .eq('id', id)
    if (error) {
      alert(error.message)
      return
    }
    setEditingSkuId(null)
    load()
  }

  if (loading) return <p>Loading…</p>

  return (
    <div className="panel">
      <h2>Products</h2>
      <ul className="plain-list">
        {products.map((p) => (
          <li key={p.id}>
            {editingProductId === p.id ? (
              <>
                <input value={productDraft} onChange={(e) => setProductDraft(e.target.value)} />
                <span>
                  <button type="button" onClick={() => saveProduct(p.id)}>Save</button>
                  <button type="button" onClick={() => setEditingProductId(null)}>Cancel</button>
                </span>
              </>
            ) : (
              <>
                {p.name}
                <button type="button" onClick={() => startEditProduct(p)}>Edit</button>
              </>
            )}
          </li>
        ))}
      </ul>
      <form className="inline-form" onSubmit={addProduct}>
        <input
          placeholder="New product name (e.g. Agam Gold)"
          value={newProductName}
          onChange={(e) => setNewProductName(e.target.value)}
        />
        <button type="submit">Add product</button>
      </form>

      <h2>SKUs</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <ExportButton
          filename="skus"
          rows={skus.map((s) => ({
            sku_code: s.sku_code,
            product: products.find((p) => p.id === s.product_id)?.name,
            size_ml: s.size_ml,
            units_per_box: s.units_per_box,
            active: s.is_active,
          }))}
          columns={[
            { key: 'sku_code', label: 'SKU Code' },
            { key: 'product', label: 'Product' },
            { key: 'size_ml', label: 'Size (ml)' },
            { key: 'units_per_box', label: 'Units/Box' },
            { key: 'active', label: 'Active' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th>SKU code</th>
            <th>Product</th>
            <th>Size (ml)</th>
            <th>Units / box</th>
            <th>Active</th>
            <th>Edit</th>
          </tr>
        </thead>
        <tbody>
          {skus.map((s) => (
            <tr key={s.id}>
              {editingSkuId === s.id ? (
                <>
                  <td>
                    <input
                      value={skuDraft.sku_code}
                      onChange={(e) => setSkuDraft({ ...skuDraft, sku_code: e.target.value })}
                    />
                  </td>
                  <td>{products.find((p) => p.id === s.product_id)?.name}</td>
                  <td>
                    <input
                      type="number"
                      value={skuDraft.size_ml}
                      onChange={(e) => setSkuDraft({ ...skuDraft, size_ml: e.target.value })}
                    />
                  </td>
                  <td>
                    <input
                      type="number"
                      value={skuDraft.units_per_box}
                      onChange={(e) => setSkuDraft({ ...skuDraft, units_per_box: e.target.value })}
                    />
                  </td>
                  <td>
                    <button type="button" onClick={() => toggleActive(s)}>
                      {s.is_active ? 'Active' : 'Inactive'}
                    </button>
                  </td>
                  <td>
                    <button type="button" onClick={() => saveSku(s.id)}>Save</button>
                    <button type="button" onClick={() => setEditingSkuId(null)}>Cancel</button>
                  </td>
                </>
              ) : (
                <>
                  <td>{s.sku_code}</td>
                  <td>{products.find((p) => p.id === s.product_id)?.name}</td>
                  <td>{s.size_ml}</td>
                  <td>{s.units_per_box}</td>
                  <td>
                    <button type="button" onClick={() => toggleActive(s)}>
                      {s.is_active ? 'Active' : 'Inactive'}
                    </button>
                  </td>
                  <td>
                    <button type="button" onClick={() => startEditSku(s)}>Edit</button>
                  </td>
                </>
              )}
            </tr>
          ))}
        </tbody>
      </table>

      <form className="inline-form" onSubmit={addSku}>
        <input
          placeholder="SKU code (e.g. AGAM-GOLD-500)"
          value={newSku.sku_code}
          onChange={(e) => setNewSku({ ...newSku, sku_code: e.target.value })}
        />
        <select
          value={newSku.product_id}
          onChange={(e) => setNewSku({ ...newSku, product_id: e.target.value })}
        >
          <option value="">Select product</option>
          {products.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        <input
          type="number"
          placeholder="Size ml"
          value={newSku.size_ml}
          onChange={(e) => setNewSku({ ...newSku, size_ml: e.target.value })}
        />
        <input
          type="number"
          placeholder="Units per box"
          value={newSku.units_per_box}
          onChange={(e) => setNewSku({ ...newSku, units_per_box: e.target.value })}
        />
        <button type="submit">Add SKU</button>
      </form>
    </div>
  )
}

function RawStockPanel({ currentUserId }) {
  const [skus, setSkus] = useState([])
  const [batches, setBatches] = useState([])
  const [form, setForm] = useState({ sku_id: '', box_count: '', loose_units: '', supplier_note: '' })
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [selectedIds, setSelectedIds] = useState(new Set())
  const [deleting, setDeleting] = useState(false)
  const [editingBatchId, setEditingBatchId] = useState(null)
  const [editTotal, setEditTotal] = useState('')
  const [savingEdit, setSavingEdit] = useState(false)

  async function load() {
    setLoading(true)
    const [{ data: s }, { data: b }] = await Promise.all([
      supabase.from('skus').select('id, sku_code, units_per_box').eq('is_active', true).order('sku_code'),
      supabase
        .from('raw_stock_batches')
        .select('id, sku_id, box_count, loose_units, units_per_box_at_time, total_units, received_date, supplier_note')
        .order('received_date', { ascending: false })
        .limit(30),
    ])
    setSkus(s || [])
    setBatches(b || [])
    setLoading(false)
  }

  function startEditBatch(b) {
    setEditingBatchId(b.id)
    setEditTotal(String(b.total_units))
  }

  async function saveEditBatch(batchId) {
    const newTotal = Number(editTotal)
    if (Number.isNaN(newTotal) || newTotal < 0) return
    setSavingEdit(true)
    const { error } = await supabase.rpc('edit_raw_stock_batch_total', {
      p_batch_id: batchId,
      p_new_total: newTotal,
      p_actor_id: currentUserId,
    })
    setSavingEdit(false)
    if (error) {
      alert(error.message)
      return
    }
    setEditingBatchId(null)
    load()
  }

  useEffect(() => {
    load()
  }, [])

  async function submitBatch(e) {
    e.preventDefault()
    const boxCount = Number(form.box_count) || 0
    const looseUnits = Number(form.loose_units) || 0
    if (!form.sku_id || (boxCount === 0 && looseUnits === 0)) return
    setSubmitting(true)
    const { error } = await supabase.from('raw_stock_batches').insert({
      sku_id: form.sku_id,
      box_count: boxCount,
      loose_units: looseUnits,
      supplier_note: form.supplier_note || null,
      received_by: currentUserId,
    })
    setSubmitting(false)
    if (error) {
      alert(error.message)
      return
    }
    setForm({ sku_id: '', box_count: '', loose_units: '', supplier_note: '' })
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
    setSelectedIds((prev) => (prev.size === batches.length ? new Set() : new Set(batches.map((b) => b.id))))
  }

  async function deleteSelected() {
    if (selectedIds.size === 0) return
    if (!confirm(`Delete ${selectedIds.size} batch(es)? Their stock contribution will be reversed.`)) return

    setDeleting(true)
    const { error } = await supabase.rpc('delete_raw_stock_batches_bulk', {
      p_batch_ids: Array.from(selectedIds),
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
      <h2>Log Raw Stock Arrival</h2>
      <form className="inline-form" onSubmit={submitBatch}>
        <select value={form.sku_id} onChange={(e) => setForm({ ...form, sku_id: e.target.value })}>
          <option value="">Select SKU</option>
          {skus.map((s) => (
            <option key={s.id} value={s.id}>
              {s.sku_code} ({s.units_per_box}/box)
            </option>
          ))}
        </select>
        <input
          type="number"
          placeholder="Number of boxes"
          value={form.box_count}
          onChange={(e) => setForm({ ...form, box_count: e.target.value })}
        />
        <input
          type="number"
          placeholder="Loose units (extra pieces)"
          value={form.loose_units}
          onChange={(e) => setForm({ ...form, loose_units: e.target.value })}
        />
        <input
          placeholder="Supplier note (optional)"
          value={form.supplier_note}
          onChange={(e) => setForm({ ...form, supplier_note: e.target.value })}
        />
        <button type="submit" disabled={submitting}>
          {submitting ? 'Saving…' : 'Add batch'}
        </button>
      </form>

      <h2>Recent Batches</h2>
      <div className="inline-form" style={{ marginBottom: 8 }}>
        <button type="button" onClick={toggleSelectAll}>
          {selectedIds.size === batches.length && batches.length > 0 ? 'Unselect all' : 'Select all'}
        </button>
        <button type="button" onClick={deleteSelected} disabled={selectedIds.size === 0 || deleting}>
          {deleting ? 'Deleting…' : `Delete selected (${selectedIds.size})`}
        </button>
        <ExportButton
          filename="raw-stock-batches"
          rows={batches.map((b) => ({
            date: b.received_date,
            sku: skus.find((s) => s.id === b.sku_id)?.sku_code || b.sku_id,
            boxes: b.box_count,
            loose_units: b.loose_units,
            units_per_box: b.units_per_box_at_time,
            total_units: b.total_units,
            note: b.supplier_note,
          }))}
          columns={[
            { key: 'date', label: 'Date' },
            { key: 'sku', label: 'SKU' },
            { key: 'boxes', label: 'Boxes' },
            { key: 'loose_units', label: 'Loose Units' },
            { key: 'units_per_box', label: 'Units/Box' },
            { key: 'total_units', label: 'Total Units' },
            { key: 'note', label: 'Note' },
          ]}
        />
      </div>
      <table>
        <thead>
          <tr>
            <th></th>
            <th>Date</th>
            <th>SKU</th>
            <th>Boxes</th>
            <th>Loose units</th>
            <th>Units/box</th>
            <th>Total units</th>
            <th>Note</th>
            <th>Edit</th>
          </tr>
        </thead>
        <tbody>
          {batches.map((b) => (
            <tr key={b.id}>
              <td>
                <input
                  type="checkbox"
                  checked={selectedIds.has(b.id)}
                  onChange={() => toggleSelected(b.id)}
                />
              </td>
              <td>{b.received_date}</td>
              <td>{skus.find((s) => s.id === b.sku_id)?.sku_code || b.sku_id}</td>
              <td>{b.box_count}</td>
              <td>{b.loose_units}</td>
              <td>{b.units_per_box_at_time}</td>
              <td>
                {editingBatchId === b.id ? (
                  <input
                    type="number"
                    value={editTotal}
                    onChange={(e) => setEditTotal(e.target.value)}
                    style={{ width: 70 }}
                  />
                ) : (
                  b.total_units
                )}
              </td>
              <td>{b.supplier_note}</td>
              <td>
                {editingBatchId === b.id ? (
                  <>
                    <button type="button" onClick={() => saveEditBatch(b.id)} disabled={savingEdit}>
                      {savingEdit ? 'Saving…' : 'Save'}
                    </button>
                    <button type="button" onClick={() => setEditingBatchId(null)}>Cancel</button>
                  </>
                ) : (
                  <button type="button" onClick={() => startEditBatch(b)}>Edit</button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
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
            <th>SKU</th>
            <th>Product</th>
            <th>Size (ml)</th>
            <th>Quantity</th>
            <th>Last updated</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.sku_id}>
              <td>{r.skus?.sku_code}</td>
              <td>{r.skus?.products?.name}</td>
              <td>{r.skus?.size_ml}</td>
              <td>{r.quantity}</td>
              <td>{new Date(r.updated_at).toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
