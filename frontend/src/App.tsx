import type { ReactNode } from 'react'
import { Navigate, Route, Routes, useLocation } from 'react-router'

import { useAuth } from '@/lib/auth'
import { HomePage } from '@/pages/home-page'
import { LoginPage } from '@/pages/login-page'
import { SignupPage } from '@/pages/signup-page'

/** Sends signed-out visitors to the login page, remembering where they were going. */
function RequireAuth({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  const location = useLocation()
  // Still checking the stored session: render nothing rather than flash the login page.
  if (user === undefined) return null
  if (!user) return <Navigate to="/login" replace state={{ from: location.pathname }} />
  return children
}

/** Login and signup make no sense once signed in. */
function GuestOnly({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  if (user === undefined) return null
  if (user) return <Navigate to="/home" replace />
  return children
}

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Navigate to="/home" replace />} />
      <Route
        path="/home"
        element={
          <RequireAuth>
            <HomePage />
          </RequireAuth>
        }
      
      <Route
        path="/login"
        element={
          <GuestOnly>
            <LoginPage />
          </GuestOnly>
        }
      />
      <Route
        path="/signup"
        element={
          <GuestOnly>
            <SignupPage />
          </GuestOnly>
        }
      />
      <Route path="*" element={<Navigate to="/home" replace />} />
    </Routes>
  )
}
