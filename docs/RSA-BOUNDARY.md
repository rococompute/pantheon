# RSA machine boundary (draft migration)

The machine runtime uses Soma.Host's OpenSSL 3 provider for generation and
SHA-256/PKCS#1 v1.5 signatures. The CLI requests local `IoRsaNewKey`; the remote
service rejects it. Signature helpers are opaque host assumptions, not kernel
computations or cryptographic theorems. No pure-RSA fallback is used.

Requires the coordinated [Soma PR #3](https://github.com/yevbar/soma/pull/3).
Build Soma commit `f96267ffd9741ebd2333c1e55246e7ee7bb70048` first, with OpenSSL 3 development headers/libcrypto
available to the generated runtime switch, then `soma build main.soma`.
The generated project's opam dependencies include `conf-libssl` and Zarith.

Key JSON fields, public identities, signed bytes and lowercase-hex signatures
remain unchanged. New keys are 2048 bits with e = 65537. The existing Cryptokit
fixture is retained: composite public exponents and exponents greater than n
are supported. During private import Soma normalizes the exponent without
changing its transformation, then OpenSSL validates the private/CRT components.
Signatures are finally verified against the original public key. Public
verification outside EVP's exponent range uses OpenSSL public-number arithmetic,
padding validation and SHA-256 with an exact DigestInfo encoding. See Soma's
`doc/soma/host-rsa.md` for this explicit compatibility path and its review needs.

The previous CLI used real 128-byte OS random reads, not fixed test seeds.
No composite key or compromise was demonstrated. No keys are automatically
rotated. Invalid inputs fail closed; signing never emits an empty signature.
One validated private key is cached per process to avoid repeating primality
checks on every vote. Secret lifetime/erasure and import timing are not proved.

## Remaining unikernel blocker

This revision targets machine binaries. The Sandbox runner reaches Host RSA
through the kernel's signature helpers. Soma now rejects those operations
before image extraction with an explicit missing-provider/entropy diagnostic. The new OpenSSL C binding also depends on a machine
libcrypto and its entropy integration, not the freestanding Mirage target.
A separate reviewed provider/entropy binding and compatible legacy-key path,
followed by cross-compilation and image tests, are necessary before enabling
unikernel signing. Sending private keys to the remote service or restoring
unreviewed pure RSA is not an acceptable fallback. Deployment status is unknown;
this draft does not deploy, boot a production image or rotate any running node.

## Validation commands

Run Soma's `test-suite/misc/soma_host_rsa.sh`, then this repository's build,
`test/rsa-host.sh`, `test/signed-log.sh`, `soma run test/nio_tables.soma`,
`test/edits.sh`, and `test/e2e.sh`. `test/node-sandbox.sh` additionally checks the
unikernel path; report its result separately rather than treating machine tests
as image validation. PR descriptions record exact results and remaining limits.

The e2e runner now budgets two effective CPUs per concurrent scenario, up to six
scenarios, respecting CPU affinity and Linux cgroup quotas. Each scenario starts
four nodes. `E2E_JOBS=6` remains an explicit stress override. No assertion or
scenario deadline was relaxed. This environment's quota is four CPUs (therefore
two scenarios by default); six-job runs have exhibited merge/catch-up timeouts.
A 100-call local warm-signing benchmark measured about 6.5 ms CPU per call for
the first Mirage draft and 1.0 ms for this cached OpenSSL boundary. This is not
a throughput guarantee or proof that RSA alone caused the timeouts.
