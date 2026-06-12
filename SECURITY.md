# Security Policy

## サポート範囲 / Supported

最新の `main` のみ。/ Only the latest `main`.

## セキュリティ上の前提 / Security model

jig は次の動作特性を持ちます。利用者はこれを理解した上で使用してください。

jig has the following operational characteristics. Users should understand
them:

- **読み取り専用の filter である**。jig は stdin と argv で渡されたファイル
  を読み、stdout / stderr に書く以外の I/O を行わない（`JIG_DEBUG=1` 時のみ
  `/tmp/jig.log` に trace を追記する）。ネットワークアクセスも、入力
  ファイル以外のファイルアクセスも、外部コマンド実行も無い。
  jig is a read-only filter: it reads stdin / argv-named files and writes
  stdout / stderr, nothing else (with `JIG_DEBUG=1` it also appends a trace
  to `/tmp/jig.log`). No network access, no file access beyond the named
  inputs, no subprocess execution.

- **信頼できない JSON 入力に対して頑健であることを目標とする**。パーサは
  任意のバイト列に対し「値」か「位置付きエラー」のみを返し、ネストの深さを
  制限し、assert/crash を許さない（fuzzing の常時実行は roadmap）。
  Untrusted JSON input is in scope: the parser must return a value or a
  positioned error for any byte sequence, bounds nesting depth, and treats
  any crash/assert as a release-blocking bug (continuous fuzzing is on the
  roadmap).

- **信頼できない filter（プログラム）はコードである**。jq 言語が拡張される
  につれ、悪意ある filter は CPU / メモリを浪費し得る（無限ループ等）。
  リソース制限は未実装。信頼できない filter を実行する場合は OS 側で
  制限すること（timeout, ulimit 等）。
  An untrusted FILTER is code. As the language grows, a hostile filter can
  burn CPU/memory (infinite loops etc.); resource limits are not implemented
  yet. If you must run untrusted filters, sandbox at the OS level (timeout,
  ulimit, …).

## 脆弱性の報告 / Reporting a vulnerability

GitHub の **Security Advisories** (Private vulnerability reporting) から
報告してください。公開 issue には記載しないでください。
Please report via GitHub Security Advisories (private vulnerability
reporting). Do not file public issues for vulnerabilities.
