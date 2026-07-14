# Objective-C to Swift conversion risks

Use this reference while planning, implementing, manually reviewing, and verifying a conversion. Treat compiler and generated-interface observation as authoritative for the current gitx toolchain when Swift interoperability behavior differs by version.

## Contents

- [Core verification model](#core-verification-model)
- [Nullability and optionals](#nullability-and-optionals)
- [Ownership, captures, and lifetime](#ownership-captures-and-lifetime)
- [Bridging and identity](#bridging-and-identity)
- [Runtime dynamism and Cocoa integration](#runtime-dynamism-and-cocoa-integration)
- [Numbers, enums, and pointers](#numbers-enums-and-pointers)
- [Errors, exceptions, and initialization](#errors-exceptions-and-initialization)
- [Protocols, extensions, equality, and serialization](#protocols-extensions-equality-and-serialization)
- [Value semantics and concurrency](#value-semantics-and-concurrency)
- [Risk-directed verification](#risk-directed-verification)
- [Manual equivalence checklist](#manual-equivalence-checklist)

## Core verification model

Assume the most dangerous conversion bugs are silent behavioral regressions. Compilation proves type consistency, not equivalence across nullability, ownership, runtime dispatch, bridging, atomics, numeric behavior, serialization, or threading.

Verify in layers:

1. Capture current Objective-C behavior with Swift characterization tests and frozen fixtures where appropriate.
2. Modernize the imported header and inspect the generated Swift interface.
3. Compare the old and new implementations line by line at every language seam.
4. Run the normal build, full tests, static checks, and coverage gates.
5. Add runtime observation selected by the actual risk: sanitizers, UI exercise, lifetime observation, or serialization round trips.

Preserve observed behavior unless the user explicitly approves a redesign. Include existing quirks in characterization tests when callers may depend on them; record intentional fixes separately.

## Nullability and optionals

- Treat every unannotated Objective-C pointer as unsafe to import. It may appear in Swift as an implicitly unwrapped optional without an obvious `!` at the use site.
- Add an `NS_ASSUME_NONNULL` region only after auditing every nullable parameter, return, delegate, outlet, error output, and optional collection value.
- Do not trust a `nonnull` annotation when the implementation can return `nil`. Fix the implementation or annotate the actual contract.
- Distinguish `nil`, `Optional.none`, and `NSNull`. Objective-C collections cannot store `nil`; typed Swift collection casts can fail when `NSNull` is present.
- Characterize wrong-type values passed through `id` before replacing dynamic message sends with Swift casts. Preserve whether each input returns `nil`, raises an exception, or succeeds.
- Inspect the generated Swift interface for every Objective-C API the new Swift code consumes.
- Test empty values, missing values, `NSNull`, and error paths explicitly.

## Ownership, captures, and lifetime

### Blocks and closures

- Objective-C blocks capture ordinary local variables by value unless marked `__block`; Swift closures can observe later mutation. Capture an immutable snapshot explicitly when equivalence requires capture-time value semantics.
- Review every escaping closure that captures `self`, a controller, a view, an observation token, or a callback owner.
- Use `[weak self]` only when losing the operation after deallocation is correct. Use a strong capture when the operation must keep its owner alive. Justify `unowned` rather than applying it mechanically.
- Preserve weak/unsafe semantics deliberately. Objective-C `assign` or `unsafe_unretained` is not equivalent to Swift `weak`.

### Lifetime and teardown

- Do not rely on incidental lexical lifetime for locks, observers, C callback contexts, or teardown side effects. Restructure ownership or use `withExtendedLifetime` where the lifetime itself is contractual.
- Confirm `deinit` performs the same cleanup as `dealloc`, including observer removal, callback invalidation, and resource release.
- Exercise the lifecycle and prove converted instances deallocate when expected.
- Use autorelease pools around tight loops that still call autorelease-heavy Objective-C APIs when peak memory behavior matters.

### Core Foundation and C callbacks

- Map Create/Copy ownership to retained values and Get ownership to unretained values. Inspect the imported signature because audited APIs may already be memory-managed.
- Review every `Unmanaged`, `takeRetainedValue`, `takeUnretainedValue`, `passRetained`, `passUnretained`, and opaque context pointer.
- Test callback cancellation and owner deallocation, not only the successful callback path.

## Bridging and identity

### Strings

- Preserve UTF-16 semantics when Objective-C code uses `NSString.length`, `NSRange`, or index arithmetic. Swift `String` counts grapheme clusters and uses different indices.
- Test ASCII, emoji, combining marks, composed characters, empty strings, and ranges at string boundaries.
- Never reuse a `String.Index` across a conversion or reconstruction of the string.
- Consider performance when replacing constant-time UTF-16 operations with repeated Swift grapheme traversal.

### Collections

- Audit heterogeneous Objective-C collections before casting to typed Swift collections.
- Preserve mutation and aliasing behavior when an `NSMutableArray`, `NSMutableDictionary`, or `NSMutableSet` is shared across owners.
- Treat bridging and copy-on-write as potential changes to identity, mutation visibility, and timing.
- Preserve ordering only when the original collection contract provides it.

### Numbers and `Any`

- Do not use successful `NSNumber` casts as evidence of the original declared numeric type; representability and bridge origin can affect casting.
- Preserve Boolean versus numeric intent when values travel through `NSNumber`, property lists, user defaults, or `Any`.
- Audit Objective-C consumers of Swift values boxed as `Any`.
- Test signed, unsigned, zero, maximum, minimum, and out-of-range values.

## Runtime dynamism and Cocoa integration

### Selectors and Objective-C exposure

- Preserve Objective-C runtime class names with `@objc(ClassName)` when nibs, archives, lookup, scripting, or callers depend on them.
- Preserve selectors required by callers, delegates, actions, notifications, responder-chain dispatch, or runtime lookup.
- Use `NSObject` inheritance and `@objc` only where required. Use `dynamic` where dispatch must remain runtime-based.
- Inspect the generated Objective-C interface rather than assuming a Swift declaration is visible to Objective-C.
- Treat `NSInvocation`, forwarding, and exception-based dispatch as high-risk exclusions for automatic conversion.

### KVC, KVO, bindings, outlets, and actions

- Preserve KVC-compliant names and KVO behavior with `@objc dynamic` when necessary.
- Retain observation tokens for closure-based KVO and test teardown.
- Search XIBs for custom class names, bindings, key paths, outlets, and actions before changing a type or property.
- Keep view and controller wiring, responder-chain behavior, accessibility, bindings, and rendering in their Cocoa-facing layer when extracting logic.
- Launch and exercise the affected UI; unit tests alone do not prove bindings or responder-chain behavior.

### Atomic properties and associated objects

- A Swift stored property does not preserve an Objective-C atomic property's accessor guarantee. Add explicit synchronization if callers rely on it, then run TSan on representative paths.
- Do not mistake Objective-C atomic accessors for compound-operation thread safety.
- Preserve associated-object policy and key identity. An assign association is unsafe, not zeroing weak.
- Never clear all associated objects when only the converted association belongs to gitx.

## Numbers, enums, and pointers

- Swift arithmetic traps on overflow unless a wrapping operator is used. Preserve wrapping only when the Objective-C behavior is intentional.
- Review signedness and every `NSInteger`, `NSUInteger`, `NSNotFound`, narrowing conversion, and collection index.
- Prefer `Int` for Swift collection indices, but preserve external selector types where Objective-C callers require them.
- Review `CGFloat`, `BOOL`, `Bool`, `ObjCBool`, and pointer-based stop flags at C or Objective-C boundaries.
- Preserve `NS_OPTIONS` semantics with `OptionSet`; test empty, known combinations, and unknown bits when they can arrive externally.
- Use `@unknown default` for non-frozen imported enums so new SDK cases produce a warning. Do not silently swallow an unknown case unless that is the intended fallback.
- Run ASan/UBSan when pointer arithmetic, C buffers, or unsafe conversions remain.

## Errors, exceptions, and initialization

### Errors and exceptions

- Inspect how an `NSError **` API imports. Do not assume it maps cleanly to `throws`, especially when a successful value and warning error can coexist.
- Preserve the distinction between returning `nil` or `false`, producing an error, and returning a usable value plus diagnostic information.
- Swift `do/catch` does not replace Objective-C exception handling. Keep Objective-C exception boundaries in excluded code or an explicit shim.
- Characterize failure outputs and side effects, not only error descriptions.

### Initializers

- Audit designated, convenience, required, unavailable, and failable initializers across the bridge.
- Preserve Objective-C selector availability for existing callers.
- Test subclass initialization and failure paths; do not assume inherited initializers remain available after conversion.
- Preserve initialization order and side effects that callers observe.

## Protocols, extensions, equality, and serialization

### Protocols and extensions

- Preserve `@objc optional` protocol requirements when Objective-C optional dispatch remains part of the contract.
- Do not replace an Objective-C optional protocol with a pure-Swift default implementation unless the user approves the API redesign.
- Remember that Swift extensions cannot add stored properties and do not reproduce every Objective-C category override or dispatch behavior.
- Use associated objects only when the per-instance storage and lifetime semantics are intentional.

### Equality and hashing

- For an `NSObject` subclass, override `isEqual(_:)` and `hash` when Objective-C collections, `AnyHashable`, or Cocoa APIs observe equality.
- Do not rely only on a Swift `==` overload or `hash(into:)` to reproduce Objective-C `isEqual:` behavior.
- Test equality through the actual containers and APIs used by gitx.

### Serialization

- Preserve `NSCoding` and `NSSecureCoding` class names, keys, allowed classes, optional values, and historical data compatibility.
- Do not migrate to `Codable` as part of a conversion unless the user explicitly approves the format/API redesign.
- Freeze a representative archive or serialized fixture before converting an archive-sensitive implementation.
- Test decode of historical data and round-trip behavior. Do not generate the only expected fixture from the new implementation.

## Value semantics and concurrency

### Value versus reference semantics

- Determine whether mutable Objective-C objects are shared. Replacing them with Swift structs or copy-on-write collections can stop mutations from propagating to other holders.
- Choose a class, actor, explicit shared storage, or carefully bounded value copy according to the existing contract.
- Characterize aliasing with two holders when shared mutation is plausible.

### Concurrency

- Preserve queue selection, callback order, reentrancy, cancellation, and synchronization before considering async/await or actors.
- Treat an async/await, actor, `Sendable`, or queue-ownership redesign as a separate user-confirmed migration.
- Use TSan for atomic, queue, callback, watcher, or shared-state conversions.
- Avoid hiding uncertainty with `@unchecked Sendable` or `@preconcurrency`; require an ownership argument and focused tests.

## Risk-directed verification

| Risk | Minimum additional evidence |
| --- | --- |
| Nullability or bridging | Edge-case characterization tests and generated-interface inspection |
| Closure ownership or lifecycle | Lifecycle test plus `deinit`, Memory Graph, Instruments, or equivalent observation |
| C, pointer, or Core Foundation ownership | ASan/UBSan and success/failure/cancellation paths |
| Atomic or shared concurrent state | TSan and ordering/reentrancy tests |
| Controller, view, nib, binding, or responder chain | Launch and exercise the affected UI flow |
| Serialization | Historical fixture decode and round trip |
| Numeric conversion | Boundary, signedness, overflow, and unknown-value tests |
| Objective-C runtime exposure | Generated Objective-C interface plus real caller or runtime lookup test |

Do not run zombies during leak measurement because zombie retention invalidates leak results. Corroborate tool output with direct lifecycle observation when lifetime correctness matters.

## Manual equivalence checklist

- [ ] Existing behavior is characterized before conversion.
- [ ] New tests are Swift; existing Objective-C tests were not converted.
- [ ] The header has audited nullability and known collection generics.
- [ ] `scripts/header-interop-baseline.json` is checked in and ratcheted.
- [ ] Every imported Objective-C API used by Swift was inspected for its actual generated signature.
- [ ] Objective-C callers and generated Objective-C exposure still compile.
- [ ] Runtime class names and selectors remain compatible.
- [ ] Nib classes, outlets, actions, bindings, KVC, and KVO remain functional.
- [ ] Closure captures and lifetimes have an explicit ownership rationale.
- [ ] Core Foundation and callback ownership follow the imported contract.
- [ ] String, collection, number, and `Any` bridges preserve required behavior.
- [ ] Shared mutable reference semantics were not accidentally replaced with isolated values.
- [ ] Numeric operations and enum switches handle boundaries and evolution intentionally.
- [ ] `NSObject` equality and hashing work through Cocoa collections.
- [ ] Error, initializer, and failure behavior matches the Objective-C implementation.
- [ ] Atomic and concurrency assumptions are preserved or explicitly redesigned with approval.
- [ ] Frozen archive fixtures still decode and round-trip when serialization is involved.
- [ ] Xcode source membership has no missing or duplicate implementation.
- [ ] Focused tests, full tests, static checks, coverage, and final build pass.
- [ ] Risk-selected sanitizer, lifecycle, serialization, and UI checks pass.
- [ ] The verified app exists at `/Volumes/ExtStor/gitx/build/GitX.app`.
