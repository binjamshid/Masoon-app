# Audio data formats

These contracts describe data for listening and offline playback.

| Schema | Document |
| --- | --- |
| [Catalog](../json-schema/audio-catalog-v1.schema.json) | A list of reciters, their corpus kinds, and their playback sources. Qur’an entries use the configured index for unit counts. Poem entries supply per-work unit counts. |
| [Manifest](../json-schema/audio-manifest-v1.schema.json) | One reciter and audio source, with an HTTPS base URL and a per-unit path template. |
| [Mirror manifest](../json-schema/audio-mirror-manifest-v1.schema.json) | The base playback fields plus an index of the surah packages available from a static mirror. |
| [Surah package v1](../json-schema/audio-surah-package-v1.schema.json) | A package descriptor whose six-digit MP3 keys encode the surah and ayah. Verify the decoded surah against the package surah. |
| [Surah package v2](../json-schema/audio-surah-package-v2.schema.json) | A package descriptor with explicit canonical coordinates on each file entry. |

Expand `{work}` and `{unit}` with the corresponding integer coordinates. The `:03` forms pad the number to three digits with leading zeroes. Append the resulting path to the configured base URL. For Qur’an audio, the work is the surah and the unit is the ayah.

Verify each downloaded file's byte count and SHA-256 digest against its descriptor before making it available for playback. A mirror package index also carries a package checksum. It is computed over the lowercase per-ayah digests, joined with newline separators in ascending ayah order. Timing segments, when available, describe the exact audio files they were validated against.

Bring source attribution and distribution permissions for the exact recordings, timing data, and hosting arrangement used by your app. The public contracts supply format definitions. Media, reciter catalogs, mirror configuration, and recordings are separate distribution inputs.
