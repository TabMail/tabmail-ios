
## Migration Splash / iOS Indeterminate Linear ProgressView Pitfall (2026-07-01)

- **`ProgressView().progressViewStyle(.linear)` with no value renders a STATIC empty track on iOS** — UIKit has no indeterminate `UIProgressView`, so only the circular style animates when value-less. A value-less linear bar looks frozen (exactly the "frozen launch" impression the migration splash exists to avoid). `SplashView.IndeterminateActivityBar` (a `withAnimation(.repeatForever)` sweeping capsule) is the in-repo replacement — reuse it if another indeterminate linear bar is ever needed.
- **No hard `\n` inside wrapping `Text`** — a forced break combined with natural wrapping (narrow devices / large Dynamic Type) produces unbalanced orphan lines. Let sentences flow in one string with `.multilineTextAlignment(.center)` + `.fixedSize(horizontal: false, vertical: true)`.

---
