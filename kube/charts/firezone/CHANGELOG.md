# Changelog

## [1.2.0](https://github.com/garuda-tunnel/firezone-internal/compare/v1.1.0...v1.2.0) (2026-06-24)


### Features

* **firezone:** vanilla guest chart — podLabels/podAnnotations, drop frr-sidecar dep + networks helper ([810d180](https://github.com/garuda-tunnel/firezone-internal/commit/810d1800bab4281868c57745faf30766e1d25f29))
* vanilla-guest passthrough + drop frr-sidecar (Phase 4+5) ([5bbe2fa](https://github.com/garuda-tunnel/firezone-internal/commit/5bbe2faa6a341bcd5620f696237ad114aff7feda))

## [1.1.0](https://github.com/garuda-tunnel/firezone-internal/compare/v1.0.0...v1.1.0) (2026-06-19)


### Features

* **chart:** bump frr-sidecar dependency 0.1.0 -&gt; 0.2.0 ([8176064](https://github.com/garuda-tunnel/firezone-internal/commit/817606445ad6ee2dd1d81aa399cc53edbce682e0))
* **chart:** bump frr-sidecar dependency 0.1.0 → 0.2.0 ([1b4fd92](https://github.com/garuda-tunnel/firezone-internal/commit/1b4fd925fb3571f9600a0ab731cf77014f991127))
* firezone tag-model publish (sub-project A) ([f240e1e](https://github.com/garuda-tunnel/firezone-internal/commit/f240e1eff956626e2b742044f568c145e7657019))
* firezone tag-model publish; first-party firezone fallback, postgres/oidc kept literal ([4eaefa1](https://github.com/garuda-tunnel/firezone-internal/commit/4eaefa17575be082851f9170be133c229124e1eb))
* **firezone:** add MSS clamp sidecar (bidirectional, separate nft table) ([a39554e](https://github.com/garuda-tunnel/firezone-internal/commit/a39554e4abf6374682fd6146ee13ee3cc585e91a))
* **firezone:** consume frr-sidecar via OCI; drop local template checksum ([6ea128d](https://github.com/garuda-tunnel/firezone-internal/commit/6ea128d3ae5838d9893a157d8e47cc8b94fc8717))
* **firezone:** emit app.kubernetes.io/part-of=garuda pod label ([8428bab](https://github.com/garuda-tunnel/firezone-internal/commit/8428bab05ae429a6a1b9a1b5465850a9ab3bcf73))
* **firezone:** emit app.kubernetes.io/part-of=garuda pod label ([e792198](https://github.com/garuda-tunnel/firezone-internal/commit/e792198932b61e4aa08ba6c837269a5d9a918401))
* **firezone:** in-pod OIDC reconcile sidecar; decommission firezone_oidc ansible role ([#62](https://github.com/garuda-tunnel/firezone-internal/issues/62)) ([604963f](https://github.com/garuda-tunnel/firezone-internal/commit/604963fb0bef50fd95a1d352885ddfbceec6739b))
* **firezone:** MSS clamp sidecar (MTU/MSS defense-in-depth Task 3, closes GAP-1) ([6432d3e](https://github.com/garuda-tunnel/firezone-internal/commit/6432d3ee1913199a4b4552ad7cc4c205698cf077))
* **firezone:** remove conntrack-log sidecar (audit split precondition) ([738f1c3](https://github.com/garuda-tunnel/firezone-internal/commit/738f1c3ab7ccc1e337030139bd3d9428a1ba24f2))
* normalize firezone mss policy ([4f734ed](https://github.com/garuda-tunnel/firezone-internal/commit/4f734edf764771296836adc7db57b8094394c4fb))
* pin firezone image digest in chart (Phase 1) ([3dbc97f](https://github.com/garuda-tunnel/firezone-internal/commit/3dbc97f210fe64994cd090a792607a8d3aa3d942))
* pin firezone image digest in chart; TF conditional override (firezone+frr); caller main-trigger + inputs; regression tests ([34ff2db](https://github.com/garuda-tunnel/firezone-internal/commit/34ff2dbac463511ddb28a74f59a91e7eb849a40e))
* unify MTU/MSS policy — firezone mss-clamp + chart 1.0.0 ([975043b](https://github.com/garuda-tunnel/firezone-internal/commit/975043b07ea0c688ce99300ccea6f1ec1282507a))


### Bug Fixes

* **firezone:** add frr-sidecar template-checksum sentinel ([#51](https://github.com/garuda-tunnel/firezone-internal/issues/51)) ([#59](https://github.com/garuda-tunnel/firezone-internal/issues/59)) ([19e0df6](https://github.com/garuda-tunnel/firezone-internal/commit/19e0df646a2820c85b16e45ab71c9fa1e0899bbd))
* **firezone:** telemetry off + Google OIDC configured on vpn2 ([#44](https://github.com/garuda-tunnel/firezone-internal/issues/44)) ([91fd518](https://github.com/garuda-tunnel/firezone-internal/commit/91fd518683615877dce3fcde437de8275d8cd72b))
* **hub-k3s-cutover:** tag-correct transit provider + watcher fallback + smoke green ([#47](https://github.com/garuda-tunnel/firezone-internal/issues/47)) ([99f83bb](https://github.com/garuda-tunnel/firezone-internal/commit/99f83bb0463a17074cb1c1b78e04f94d5aefde03))
* **hub-k3s-cutover:** tag-correct transit provider + watcher fallback + smoke green ([#47](https://github.com/garuda-tunnel/firezone-internal/issues/47)) ([99f83bb](https://github.com/garuda-tunnel/firezone-internal/commit/99f83bb0463a17074cb1c1b78e04f94d5aefde03))
* keep firezone route pmtu clamp enabled ([2f08f59](https://github.com/garuda-tunnel/firezone-internal/commit/2f08f5915ed1ab9a9df07c8bb3cd8c445e428d61))
* **tls:** Gateway API platform + firezone HTTPRoute migration ([#44](https://github.com/garuda-tunnel/firezone-internal/issues/44) follow-up) ([#56](https://github.com/garuda-tunnel/firezone-internal/issues/56)) ([ada443c](https://github.com/garuda-tunnel/firezone-internal/commit/ada443cc2cfac4d6d5cf969d715d01d91ebd34f8))

## [0.6.0](https://github.com/garuda-tunnel/firezone-internal/compare/v0.5.0...v0.6.0) (2026-06-18)


### Features

* **firezone:** add MSS clamp sidecar (bidirectional, separate nft table) ([a39554e](https://github.com/garuda-tunnel/firezone-internal/commit/a39554e4abf6374682fd6146ee13ee3cc585e91a))
* **firezone:** MSS clamp sidecar (MTU/MSS defense-in-depth Task 3, closes GAP-1) ([6432d3e](https://github.com/garuda-tunnel/firezone-internal/commit/6432d3ee1913199a4b4552ad7cc4c205698cf077))

## [0.5.0](https://github.com/garuda-tunnel/firezone-internal/compare/v0.4.0...v0.5.0) (2026-06-17)


### Features

* **firezone:** emit app.kubernetes.io/part-of=garuda pod label ([8428bab](https://github.com/garuda-tunnel/firezone-internal/commit/8428bab05ae429a6a1b9a1b5465850a9ab3bcf73))
* **firezone:** emit app.kubernetes.io/part-of=garuda pod label ([e792198](https://github.com/garuda-tunnel/firezone-internal/commit/e792198932b61e4aa08ba6c837269a5d9a918401))

## [0.4.0](https://github.com/garuda-tunnel/firezone-internal/compare/v0.3.0...v0.4.0) (2026-06-16)


### Features

* **chart:** bump frr-sidecar dependency 0.1.0 -&gt; 0.2.0 ([8176064](https://github.com/garuda-tunnel/firezone-internal/commit/817606445ad6ee2dd1d81aa399cc53edbce682e0))
* **chart:** bump frr-sidecar dependency 0.1.0 → 0.2.0 ([1b4fd92](https://github.com/garuda-tunnel/firezone-internal/commit/1b4fd925fb3571f9600a0ab731cf77014f991127))

## [0.3.0](https://github.com/garuda-tunnel/firezone-internal/compare/v0.2.0...v0.3.0) (2026-06-16)


### Features

* firezone tag-model publish (sub-project A) ([f240e1e](https://github.com/garuda-tunnel/firezone-internal/commit/f240e1eff956626e2b742044f568c145e7657019))
* firezone tag-model publish; first-party firezone fallback, postgres/oidc kept literal ([4eaefa1](https://github.com/garuda-tunnel/firezone-internal/commit/4eaefa17575be082851f9170be133c229124e1eb))
* pin firezone image digest in chart (Phase 1) ([3dbc97f](https://github.com/garuda-tunnel/firezone-internal/commit/3dbc97f210fe64994cd090a792607a8d3aa3d942))
* pin firezone image digest in chart; TF conditional override (firezone+frr); caller main-trigger + inputs; regression tests ([34ff2db](https://github.com/garuda-tunnel/firezone-internal/commit/34ff2dbac463511ddb28a74f59a91e7eb849a40e))
