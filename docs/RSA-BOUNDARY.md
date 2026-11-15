# RSA machine boundary (draft migration)

Pantheon's machine runtime now asks Soma.Host to generate RSA keys and sign and
verify SHA-256/PKCS#1 v1.5 messages with Mirage Crypto. The CLI uses a dedicated
`IoRsaNewKey` operation, implemented by `node_shell`; the remote service policy
rejects that operation. The node's signature helpers invoke opaque host
primitives. They are no longer reference computations that the kernel can run.
No cryptographic theorem is asserted by this change.

This requires [Soma PR #3](https://github.com/yevbar/soma/pull/3),
commit `07fc8eae2d4e6828d4c65a0c1a8f889efee1d9a9`. Build Soma first, and
install `mirage-crypto-pk.2.4.1 mirage-crypto-rng.2.4.1` in the generated-program
OCaml switch (`SOMA_OCAML_SWITCH`). Then run `soma build main.soma`.

Existing key JSON fields, public identities, signed message bytes, and lowercase
hex signatures remain compatible. Keys are 2048 bits with e = 65537. Existing
keys with either prime order are accepted. Mirage Crypto requires a prime
public exponent for private-key import. Older Cryptokit keys with composite
random public exponents still verify but cannot sign with this provider. This
is a merge blocker until a compatible vetted provider/import path or an
explicit operational migration is reviewed. No such keys are silently rotated.
Unsupported sizes or inconsistent CRT fields fail closed. There is
no automatic key rotation and no evidence here that existing keys were
compromised. A signing error stops execution; it never emits an empty signature.

The previous CLI supplied two real 128-byte OS random reads, not fixed test
seeds. The change addresses use of an unreviewed RSA implementation, not an
assertion of predictable seeds. Soma's fixed primality-test bases and private
exponentiation need separate cryptographic review. Pure Soma RSA remains
available as reference code but is no longer used for these machine operations.

This draft intentionally targets machine binaries. The existing unikernel build
cannot use Unix-backed Soma.Host crypto and is not supported by this revision;
it needs a reviewed Mirage entropy/provider integration before use. Deployment
status is unknown, and this change does not deploy or rotate any running node.
Review the compatibility and performance implications before merging: key import
validation is repeated for each signature, and private-number import is not
claimed constant-time. OS entropy, Mirage Crypto, its dependencies, the compiler,
and the host remain trusted. In-memory secret lifetime/erasure is unchanged.

Validation: Soma's `test-suite/misc/soma_host_rsa.sh` covers provider/reference
interoperability and malformed inputs. Run this repository's build, signed-log,
edit-engine, and local e2e tests against the revised Soma compiler.
