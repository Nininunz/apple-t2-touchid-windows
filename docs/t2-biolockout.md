# T2 fingerprint lockout on Windows

The matching macOS 25G241 host names BiometricKit status 83
`FingerOnInBioLockout`. A Windows capture on this T2 emitted status 83 after
the current StartMatch entered capture mode. A separate read-only command
`0x27` for user 501 returned SKS state `0x44` (BioLockout `0x04` and
IdentificationLockout `0x40`). In a later clean S4 test, the same read returned
`0x208` before and after hibernate, and a fingerprint unlocked Windows.
Hibernate alone therefore did not reproduce the lockout.

The verify engine treats status 83 as a reason to check the current SKS state,
not as a verdict by itself. It also checks SKS if StartMatch is rejected.
Only a successful, exact four-byte read with a fingerprint lockout bit set
produces `VerifyOutcome::BioLockout`. A valid unlocked read after status 83
retries the match session twice before failing closed as a device error.
An unreadable or malformed SKS result also fails closed. No fingerprint BIR
is emitted on these paths.

The WBDI driver reports a confirmed T2 lockout as `WINBIO_SENSOR_BUSY` and
`WINBIO_E_DEVICE_BUSY`, including on subsequent status polls and captures
within that Windows sign-in session. A successful Windows sign-in invalidates
the cached T2 verdict so the next lock session can check again. This does
**not** clear lockout on the T2. Windows Hello has its own credential-provider
lockout; the driver does not impersonate that state or count T2 lockout as a
fingerprint mismatch. Microsoft's WBDI contract has no dedicated sensor
lockout status.

## Live validation still needed

Build and sign the test driver, then confirm in a controlled locked-out state
that Windows ends the pending capture, leaves PIN available, and does not
silently re-arm. Record the WBDI capture result and status poll. A separate
read-only `0x27` comparison before and after Windows PIN sign-in can establish
whether PIN plus existing fork behavior changes T2 state. The observed
`0x44` to `0x208` change across a restart does not identify which boot step
cleared it. The current bootstrap deliberately runs once per cold boot; it
must not be replayed merely because Windows accepted a PIN.
