# Run required semantic analysis outside feedback

The two semantic SwiftLint rules need the complete compiler log and take far longer than file-local lint. Keep them required for integration and run analysis alongside native verification when resources permit. Local feedback uses pinned formatting and a small set of correctness lint rules.
