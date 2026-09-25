import { useAuth } from '../context/AuthContext'

export default function Layout({ title, children }) {
  const { profile, signOut } = useAuth()

  return (
    <div className="app-shell">
      <header className="app-header">
        <div>
          <h1>{title}</h1>
          <span className="role-tag">{profile?.role?.replaceAll('_', ' ')}</span>
        </div>
        <div className="header-right">
          <span>{profile?.full_name} ({profile?.email})</span>
          <button type="button" onClick={signOut}>Sign out</button>
        </div>
      </header>
      <main className="app-main">{children}</main>
    </div>
  )
}
