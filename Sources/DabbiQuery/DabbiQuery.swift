// DabbiQuery — predicates (`PredicateAST`), fetch templates, quick filter, global search, code generation.
//
// M2-01 lands the core: the AST and its round trip with text and `NSPredicate` (`PredicateAST`,
// `PredicateConversion`), key-path resolution against the model (`KeyPathResolution`), validation with
// diagnostics (`PredicateValidator`) and the builder-representability check (`PredicateBuilderSupport`).
//
// M2-02 adds what a field needs to complete what is being typed (`PredicateCompleter`), which the app's
// predicate bar drives.
//
// Still to come: the `NSPredicateEditor` templates (M2-03), saved predicates (M2-04), fetch-request templates
// (M2-05), the quick filter (M2-13), code generation (M4-08) and global search (M5-05).
// See docs/ARCHITECTURE.md §6.5.
