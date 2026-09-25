import { useAuth } from '../context/AuthContext'

export default function PendingApproval() {
  const { profile, signOut } = useAuth()

  return (
    <div className="auth-screen">
      <div className="auth-card">
        <h1>Waiting for approval</h1>
        <p>
          Hi {profile?.full_name}, your account has been created but a Super Admin
          still needs to approve it and assign your role.
        </p>
        <button type="button" onClick={signOut}>Sign out</button>
      </div>
    </div>
  )
}
