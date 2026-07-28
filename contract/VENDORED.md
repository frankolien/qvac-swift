# Vendored contract

Copied from `tetherto/qvac` — `packages/sdk/contract/` at commit
`fadfaedcb2434f16d995d61c79cbe631360f1610` (2026-07-28).

These three artifacts are the language-neutral wire contract the generated
client is built from, per the contract README upstream: `schema.json` (JSON
Schema 2020-12, 85 `$defs`), `manifest.json` (37 methods with call shapes and
progress-promotion conditions), and `error-codes.json` (server/client/registry
code tables).

`models.json` and `model-type-maps.json` are deliberately not vendored — they
are runtime registry data, not type information.

To refresh:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/tetherto/qvac.git
cd qvac && git sparse-checkout set packages/sdk/contract
cp packages/sdk/contract/{schema,manifest,error-codes}.json <this directory>/
# update the commit hash above, then:
swift run qvac-codegen && swift test
```
