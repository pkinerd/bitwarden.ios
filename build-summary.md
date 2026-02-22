# Build Log

| Field | Value |
|-------|-------|
| **Run** | #169 (attempt 1) |
| **Run ID** | 22268235402 |
| **Result** | pass |
| **Commit** | 7f1728486dcc7542c435ce2554d0884b5ce9e275 |
| **Ref** | refs/pull/76/merge |
| **Event** | pull_request |
| **Actor** | pkinerd |
| **PR** | #76: Remove _OfflineSyncDocs after migration to claude/issues branch |
| **Branch** | claude/migrate-offlinesyncdocs-issues-0Bju5 |

## Artifacts
```
test-reports/coverage.xml
test-reports/bwpm-tests.xcresult/Data/ (13088 files)
test-reports/bwpm-build.xcresult/ (1 files)
test-reports/bwpm-tests.xcresult/ (1 files)
test-reports/bwpm-build.xcresult/Data/ (6 files)
```

## Coverage
```xml
<?xml version="1.0"?>
<!DOCTYPE coverage SYSTEM "https://github.com/cobertura/cobertura/blob/master/cobertura/src/site/htdocs/xml/coverage-04.dtd" [
    <!ELEMENT coverage (sources?, packages)>
    <!ATTLIST coverage line-rate CDATA #REQUIRED>
    <!ATTLIST coverage branch-rate CDATA #REQUIRED>
    <!ATTLIST coverage lines-covered CDATA #REQUIRED>
    <!ATTLIST coverage lines-valid CDATA #REQUIRED>
    <!ATTLIST coverage branches-covered CDATA #REQUIRED>
    <!ATTLIST coverage branches-valid CDATA #REQUIRED>
    <!ATTLIST coverage complexity CDATA #REQUIRED>
    <!ATTLIST coverage version CDATA #REQUIRED>
    <!ATTLIST coverage timestamp CDATA #REQUIRED>
    <!ELEMENT sources (source)*>
    <!ELEMENT source (#PCDATA)>
    <!ELEMENT packages (package)*>
    <!ELEMENT package (classes)>
    <!ATTLIST package name CDATA #REQUIRED>
    <!ATTLIST package line-rate CDATA #REQUIRED>
    <!ATTLIST package branch-rate CDATA #REQUIRED>
    <!ATTLIST package complexity CDATA #REQUIRED>
    <!ELEMENT classes (class)*>
    <!ELEMENT class (methods, lines)>
    <!ATTLIST class name CDATA #REQUIRED>
    <!ATTLIST class filename CDATA #REQUIRED>
    <!ATTLIST class line-rate CDATA #REQUIRED>
    <!ATTLIST class branch-rate CDATA #REQUIRED>
    <!ATTLIST class complexity CDATA #REQUIRED>
    <!ELEMENT methods (method)*>
    <!ELEMENT method (lines)>
    <!ATTLIST method name CDATA #REQUIRED>
    <!ATTLIST method signature CDATA #REQUIRED>
    <!ATTLIST method line-rate CDATA #REQUIRED>
    <!ATTLIST method branch-rate CDATA #REQUIRED>
    <!ATTLIST method complexity CDATA #REQUIRED>
    <!ELEMENT lines (line)*>
    <!ELEMENT line (conditions)*>
    <!ATTLIST line number CDATA #REQUIRED>
    <!ATTLIST line hits CDATA #REQUIRED>
    <!ATTLIST line branch CDATA "false">
    <!ATTLIST line condition-coverage CDATA "100%">
    <!ELEMENT conditions (condition)*>
    <!ELEMENT condition EMPTY>
    <!ATTLIST condition number CDATA #REQUIRED>
    <!ATTLIST condition type CDATA #REQUIRED>
    <!ATTLIST condition coverage CDATA #REQUIRED>
]>

<coverage line-rate="0.8168534827862289" branch-rate="1.0" lines-covered="199969" lines-valid="244804" timestamp="1771725349.536" version="diff_coverage 0.1" complexity="0.0" branches-valid="1.0" branches-covered="1.0">
    <sources>
        <source>.</source>
```
