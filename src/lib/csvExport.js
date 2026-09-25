function csvEscape(value) {
  if (value === null || value === undefined) return ''
  const str = String(value)
  if (/[",\n]/.test(str)) {
    return '"' + str.replace(/"/g, '""') + '"'
  }
  return str
}

// rows: array of objects. columns: [{ key, label }] — label optional, defaults to key.
export function exportToCsv(filename, rows, columns) {
  if (!rows || rows.length === 0) {
    alert('No data to export.')
    return
  }
  const cols = columns || Object.keys(rows[0]).map((key) => ({ key, label: key }))
  const header = cols.map((c) => csvEscape(c.label || c.key)).join(',')
  const lines = rows.map((row) => cols.map((c) => csvEscape(row[c.key])).join(','))
  const csv = [header, ...lines].join('\r\n')

  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename.endsWith('.csv') ? filename : `${filename}.csv`
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}
