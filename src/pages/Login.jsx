import { useState } from 'react'
import { useAuth } from '../context/AuthContext'
import { supabase } from '../lib/supabaseClient'

export default function Login() {
  const { signIn } = useAuth()
  const [mode, setMode] = useState('signin') // 'signin' | 'signup'
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [info, setInfo] = useState('')
  const [submitting, setSubmitting] = useState(false)

  async function handleSignIn(e) {
    e.preventDefault()
    setError('')
    setSubmitting(true)
    const { error } = await signIn(email, password)
    setSubmitting(false)
    if (error) setError(error.message)
  }

  async function handleSignUp(e) {
    e.preventDefault()
    setError('')
    setInfo('')
    setSubmitting(true)
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: { data: { full_name: fullName } },
    })
    setSubmitting(false)
    if (error) {
      setError(error.message)
    } else {
      setInfo('Account created. Ask your Super Admin to approve your access, then sign in.')
      setMode('signin')
    }
  }

  return (
    <div className="auth-screen">
      <form className="auth-card" onSubmit={mode === 'signin' ? handleSignIn : handleSignUp}>
        <h1>{mode === 'signin' ? 'Warehouse Login' : 'Create Account'}</h1>

        {mode === 'signup' && (
          <label>
            Full name
            <input
              type="text"
              value={fullName}
              onChange={(e) => setFullName(e.target.value)}
              required
            />
          </label>
        )}
        <label>
          Email
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </label>
        <label>
          Password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            minLength={6}
            required
          />
        </label>

        {error && <p className="error-text">{error}</p>}
        {info && <p className="info-text">{info}</p>}

        <button type="submit" disabled={submitting}>
          {submitting
            ? 'Please wait…'
            : mode === 'signin'
            ? 'Sign in'
            : 'Sign up'}
        </button>

        <button
          type="button"
          className="link-button"
          onClick={() => {
            setError('')
            setInfo('')
            setMode(mode === 'signin' ? 'signup' : 'signin')
          }}
        >
          {mode === 'signin' ? "Don't have an account? Sign up" : 'Already have an account? Sign in'}
        </button>
      </form>
    </div>
  )
}
