// OTP send/verify is handled by Firebase Phone Auth on the CLIENT; the server
// verifies the resulting Firebase ID token (see backend/api/src/firebase.ts),
// so there is no server-side SMS provider here anymore.
export * from './crypto';
