// Additive in-process libFuzzer harness for full-moon (a lossless Lua parser).
//
// Feed the fuzzer bytes as UTF-8 Lua source into full_moon::parse, and on a
// successful parse assert the crate's lossless round-trip invariant
// (ast.to_string() == code). Any input that parses but does not print back
// identically is a real full-moon defect (the product), so we do NOT guard it.
// No disk I/O; upstream source is untouched — this crate only CALLS full_moon.
//
// NOTE on the print API: full_moon 2.x REMOVED the old top-level `full_moon::print(&ast)`
// helper (CHANGELOG: "[BREAKING CHANGE] The `print()` function has been removed, use
// `ast.to_string()` instead."). The lossless render is the `Ast` Display impl, which writes
// the node tree plus the trailing EOF token — so `ast.to_string()` reproduces the source
// byte-for-byte for a fully-successful parse. That is the invariant we assert here.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|code: &str| {
    if let Ok(ast) = full_moon::parse(code) {
        let printed = ast.to_string();
        assert_eq!(code, printed);
    }
});
