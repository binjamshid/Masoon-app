# Data contracts

The [JSON Schemas](json-schema/) describe Masoon's versioned data formats. They use JSON Schema Draft 2020-12. To validate an export record with an embedded curriculum, register the curriculum schema under its declared identifier, `masoon.curriculum.v1`, before validating the record.

| Format | Schemas |
| --- | --- |
| Planner curriculum and corpus reference | [Curriculum](json-schema/curriculum-v1.schema.json), [corpus reference](json-schema/corpus-ref-v1.schema.json) |
| Evidence and assessment | [Evidence requirement](json-schema/evidence-spec-v1.schema.json), [evidence payload](json-schema/evidence-payload-v1.schema.json), [assessment form](json-schema/assessment-form-v1.schema.json) |
| Streaming backup | [Manifest](json-schema/export-manifest-v1.schema.json), [record](json-schema/export-record-v1.schema.json) |
| Adhkar | [Categorized entries](json-schema/adhkar-v1.schema.json), [ordered reading packs](json-schema/adhkar-packs-v1.schema.json) |
| Playback | [Audio catalog, manifests and packages](audio/) |

Validate document shape with the schemas. Applications also check rules that depend on multiple records or on the selected edition, such as canonical bounds, package counts, checksums, and which curriculum selectors can run against a given corpus. A schema can describe source attribution fields. Permission to redistribute data or media comes from the rights holders.

See [engine parity](../docs/architecture/ENGINE_PARITY.md) for the fixture interface and [offline and sync design](../docs/architecture/SYNC.md) for the event exchange protocol.
