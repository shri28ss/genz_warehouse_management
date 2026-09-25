import { exportToCsv } from '../lib/csvExport'

export default function ExportButton({ filename, rows, columns, label }) {
  return (
    <button type="button" onClick={() => exportToCsv(filename, rows, columns)}>
      {label || 'Export CSV'}
    </button>
  )
}
