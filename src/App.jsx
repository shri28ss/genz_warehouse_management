import { AuthProvider, useAuth } from './context/AuthContext'
import Login from './pages/Login'
import PendingApproval from './pages/PendingApproval'
import AdminDashboard from './pages/AdminDashboard'
import OperationDashboard from './pages/OperationDashboard'
import ClientDashboard from './pages/ClientDashboard'

function Router() {
  const { session, profile, loading } = useAuth()

  if (loading) return <div className="center-screen">Loading…</div>
  if (!session) return <Login />
  if (!profile || profile.role === 'pending') return <PendingApproval />

  switch (profile.role) {
    case 'super_admin':
      return <AdminDashboard />
    case 'operation_incharge':
      return <OperationDashboard />
    case 'client':
      return <ClientDashboard />
    default:
      return <PendingApproval />
  }
}

export default function App() {
  return (
    <AuthProvider>
      <Router />
    </AuthProvider>
  )
}
